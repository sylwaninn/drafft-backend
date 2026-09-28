// POST /db-events { id, event, payload }, from the database outbox (pg_net), never from the app.
//
// Each handler is idempotent: the outbox retries until this function acks, so an event can arrive
// twice (a lost ack) or out of order (a session event before its match channel exists).
import { env, optionalEnv } from "../_shared/env.ts";
import { pushToUser } from "../_shared/apns.ts";
import { deviceCheckConfigured, type DeviceEnvironment, updateBits } from "../_shared/devicecheck.ts";
import { isReservedAddress, sendEmail } from "../_shared/mailer.ts";
import { renderNotice, renderSupportReply, renderTeamEmail } from "../_shared/notices.ts";
import { HttpError, json, readJson, safeEqual, serve } from "../_shared/http.ts";
import { deleteObject, getObject, headObject } from "../_shared/r2.ts";
import { moderateImage, moderationConfigured } from "../_shared/moderation.ts";
import { ensureChannel, ensureUsers, sendOnce, setChatHeld, stream } from "../_shared/stream.ts";
import { admin, check, must } from "../_shared/supabase.ts";
import {
  type Language,
  language,
  likeReceived,
  matchCreated,
  photoRefused,
  pushTitle,
  sessionAutoCancelled,
  sessionChanged,
  sessionName,
  someone,
  superLikeReceived,
  weeklyBoost,
} from "../_shared/texts.ts";

interface Event {
  id: number;
  event: string;
  payload: Record<string, unknown>;
}

// Each handler declares its own payload shape; the outbox writes them in migrations/..._events.sql.
// deno-lint-ignore no-explicit-any
type Handler = (payload: any) => Promise<void>;

/** The first name shown to others, or null (no name yet, or the account is gone). */
async function firstName(userId: string): Promise<string | null> {
  const { data, error } = await admin.from("profiles").select("name").eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  return data?.name || null;
}

type Setting = "notify_matches" | "notify_likes" | "notify_messages";

/**
 * Who gets a push and in which language: the person's app language (`profiles.language`) when their own
 * notification setting (You › Notifications in the app) is on. Null: the setting is off, or the account
 * is gone.
 */
async function recipient(userId: string, setting: Setting): Promise<Language | null> {
  const { data, error } = await admin.from("profiles").select(`language, ${setting}`).eq("id", userId)
    .maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  const row = data as Record<string, unknown> | null;
  if (!row || row[setting] === false) return null;
  return language(row.language);
}

/** The account's email, from Auth. Null when the account is gone. */
async function accountEmail(userId: string): Promise<string | null> {
  const { data, error } = await admin.auth.admin.getUserById(userId);
  if (error) {
    if (error.status === 404) return null;
    throw new Error(`auth user ${userId}: ${error.message}`);
  }
  return data.user?.email || null;
}

/** The team's copy, to SUPPORT_INBOX. Unset (locally): logged only. `from`: the address of whoever it is
 * about; a reserved one (a test or demo account) gets no team copy, like it gets no email itself. */
async function toTeam(
  subject: string,
  lines: [string, string][],
  key: string,
  from: string | null,
  replyTo?: string,
) {
  if (from && isReservedAddress(from)) {
    console.log(`db-events: test account, team email skipped: ${subject}`);
    return;
  }
  const inbox = optionalEnv("SUPPORT_INBOX");
  if (!inbox) {
    console.warn(`db-events: SUPPORT_INBOX not set, team email skipped: ${subject}`);
    return;
  }
  await sendEmail(inbox, renderTeamEmail(subject, lines), key, replyTo);
}

/** Stream ban on or off from the account's current hold. Deleted since: the account and its chats are gone. */
async function syncChatHold(userId: string) {
  const { data, error } = await admin.from("profiles").select("moderation").eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  if (!data) return;
  await setChatHeld(userId, data.moderation !== null);
}

const handlers: Record<string, Handler> = {
  // Push for a like, unless it made a match (match.created pushes instead). No name: the Likes tab
  // is where people see who it was.
  async "like.received"(p: { from: string; to: string; superLike: boolean }) {
    const [a, b] = [p.from, p.to].sort();
    const { data: match, error } = await admin.from("matches").select("id").eq("user_a", a).eq("user_b", b)
      .maybeSingle();
    if (error) throw new Error(`match lookup: ${error.message}`);
    if (match) return;
    const lang = await recipient(p.to, "notify_likes");
    if (!lang) return;
    await pushToUser(p.to, {
      title: pushTitle,
      body: (p.superLike ? superLikeReceived : likeReceived)[lang],
      data: { tab: "likes" },
      collapseId: "likes",
    });
  },

  // Chat channel, then the openers each person attached to their like, then a push to both. Ended or gone
  // by the time it's delivered: nothing (no channel, no opener, no "It's a match").
  async "match.created"(p: { matchId: string; userA: string; userB: string }) {
    const opened = await ensureChannel(p.matchId);
    if (!opened) return;
    const { channel } = opened;
    const swipes = must(
      await admin.from("swipes").select("swiper, action, opener, note, created_at")
        .or(`and(swiper.eq.${p.userA},target.eq.${p.userB}),and(swiper.eq.${p.userB},target.eq.${p.userA})`)
        .order("created_at"),
      "swipes",
    );
    for (const s of swipes) {
      if (s.note) {
        await sendOnce(channel, {
          id: `note-${p.matchId}-${s.swiper}`,
          user_id: s.swiper,
          text: s.note,
          drafft: { type: "superLikeNote" },
        });
      }
      const opener = s.opener as Record<string, string> | null;
      // Session openers became real sessions in the database; session.proposed posts them.
      if (!opener || opener.kind === "session") continue;
      await sendOnce(channel, {
        id: `opener-${p.matchId}-${s.swiper}`,
        user_id: s.swiper,
        text: opener.reply ?? opener.text ?? "",
        drafft: { type: opener.kind, ...opener },
      });
    }
    const [nameA, nameB, langA, langB] = await Promise.all([
      firstName(p.userA),
      firstName(p.userB),
      recipient(p.userA, "notify_matches"),
      recipient(p.userB, "notify_matches"),
    ]);
    await Promise.all([
      langA && pushToUser(p.userA, {
        title: pushTitle,
        body: matchCreated(langA, nameB ?? someone[langA]),
        data: { match: p.matchId },
        collapseId: `match-${p.matchId}`,
      }),
      langB && pushToUser(p.userB, {
        title: pushTitle,
        body: matchCreated(langB, nameA ?? someone[langB]),
        data: { match: p.matchId },
        collapseId: `match-${p.matchId}`,
      }),
    ]);
  },

  // Unmatch or block: the channel disappears for both.
  async "match.ended"(p: { matchId: string }) {
    try {
      await stream().channel("messaging", p.matchId).delete();
    } catch (error) {
      if (!String(error).includes("does not exist")) throw error;
    }
  },

  "session.proposed": (p) => sessionEvent(p, "proposed"),
  "session.accepted": (p) => sessionEvent(p, "accepted"),
  "session.declined": (p) => sessionEvent(p, "declined"),
  "session.cancelled": (p) => sessionEvent(p, "cancelled"),

  // An upcoming session cancelled with its match or an account (unmatch, block, report, ban, deletion).
  // Everything comes in the payload: a deleted account can't be read any more. Same neutral push in
  // every case; the chat card only while the chat exists (a ban).
  async "session.auto_cancelled"(p: {
    sessionId: string;
    matchId: string;
    to: string;
    at: string | null;
    language: string;
    timezone: string;
    notify: boolean;
    chatFrom: string | null;
  }) {
    // An ended match has no chat to write in (ensureChannel never reopens it): the push alone.
    const opened = p.chatFrom ? await ensureChannel(p.matchId) : null;
    if (p.chatFrom && opened) {
      await sendOnce(opened.channel, {
        id: `session-${p.sessionId}-cancelled`,
        user_id: p.chatFrom,
        text: "Cancelled the session",
        drafft: { type: "session", sessionId: p.sessionId, status: "cancelled" },
      });
    }
    // Session updates follow the Messages setting, like the other session pushes.
    if (!p.notify) return;
    await pushToUser(p.to, {
      title: pushTitle,
      body: sessionAutoCancelled(language(p.language), p.at ? new Date(p.at) : null, p.timezone),
      data: { kind: "session_cancelled", session: p.sessionId },
      // A retried event replaces the push instead of adding a second one.
      collapseId: `session-cancelled-${p.sessionId}`,
    });
  },

  // Moderation gate. Nothing is visible to others until approved.
  async "media.created"(p: { mediaId: string; userId: string; key: string; posterKey?: string }) {
    const { data: media, error } = await admin.from("profile_media").select("status").eq("id", p.mediaId)
      .maybeSingle();
    // An error must not be acked as "nothing to do": throw, and the outbox retries.
    if (error) throw new Error(`media ${p.mediaId}: ${error.message}`);
    // Deleted since, or already decided.
    if (!media || media.status !== "pending") return;

    const size = await headObject(p.key);
    const posterOk = !p.posterKey || (await headObject(p.posterKey)) !== null;
    if (size === null || !posterOk) {
      await setStatus(p.mediaId, "rejected");
      return;
    }
    // Rekognition when configured. Videos are judged on their poster frame. `review` (borderline
    // labels, or an image over Rekognition's 5 MB) leaves the media pending for a human.
    if (moderationConfigured()) {
      const bytes = await getObject(p.posterKey ?? p.key);
      if (!bytes) {
        await setStatus(p.mediaId, "rejected");
        return;
      }
      if (bytes.length > 5 * 1024 * 1024) {
        console.warn(`moderation: ${p.mediaId} over 5 MB, left for review`);
        return;
      }
      const { verdict, labels } = await moderateImage(bytes);
      console.log(`moderation: ${p.mediaId} ${verdict} ${labels.join(", ")}`);
      if (verdict !== "review") await setStatus(p.mediaId, verdict);
      if (verdict !== "approved") {
        check(
          await admin.from("media_flags").insert({
            user_id: p.userId,
            context: "profile",
            key: p.key,
            verdict,
            labels,
          }),
          "media flag",
        );
      }
      if (verdict === "rejected") await pushPhotoRefused(p.userId, p.mediaId);
      return;
    }
    // MODERATION_MODE: "auto_approve" for local development only. Otherwise media stays pending.
    if (optionalEnv("MODERATION_MODE") === "auto_approve") {
      await setStatus(p.mediaId, "approved");
    }
  },

  async "media.deleted"(p: { keys: string[] }) {
    await Promise.all(p.keys.map(deleteObject));
  },

  // Messages on or off in the app: Stream sends chat pushes, so it gets the same setting.
  async "push.preferences"(p: { userId: string; messages: boolean }) {
    await ensureUsers([p.userId]);
    await stream().setPushPreferences([{ user_id: p.userId, chat_level: p.messages ? "all" : "none" }]);
  },

  // Paused or resumed. A voluntary pause keeps chats writable; only a hold makes them read-only. The
  // current hold decides, not the payload, so this also lifts a ban left by an older pause (which used to
  // ban) and events arriving out of order still end right.
  async "profile.paused"(p: { userId: string }) {
    await syncChatHold(p.userId);
  },

  // A hold changed. The iPhone's DeviceCheck bits follow (bit0 closed, bit1 on hold), and when the hold is
  // lifted the person is emailed that they're back. The current state decides, the payload says where it
  // came from. No token yet (Simulator, an old app): device-check sets the bits at the next launch.
  async "account.moderation"(p: { userId: string; previous: string | null }) {
    const { data: profile, error } = await admin.from("profiles").select("moderation, language").eq("id", p.userId)
      .maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    // Deleted since: the bits set earlier stay, which is the point.
    if (!profile) return;
    const state = profile.moderation as string | null;

    // Chats read-only while held, writable again once lifted (a hold on an already paused profile
    // doesn't change `paused`, so profile.paused alone would miss it).
    await setChatHeld(p.userId, state !== null);

    if (deviceCheckConfigured()) {
      const held = (s: string | null) => s === "review" || s === "selfie";
      const change: { bit0?: boolean; bit1?: boolean } = {};
      if (state === "banned") change.bit0 = true;
      else if (p.previous === "banned") change.bit0 = false;
      if (held(state)) change.bit1 = true;
      else if (held(p.previous)) change.bit1 = false;
      const rows = must(await admin.rpc("device_check_token", { p_user: p.userId }), "device token") as {
        token: string;
        environment: DeviceEnvironment;
      }[];
      try {
        for (const row of rows) await updateBits(row.token, row.environment, change);
      } catch (error) {
        // Never hold the email back for Apple: the bits are set again at the next launch.
        console.error("account.moderation: devicecheck", error);
      }
    }

    if (state === null && p.previous) {
      const email = await accountEmail(p.userId);
      if (!email) return;
      const kind = p.previous === "banned" ? "accountReopened" : "accountRestored";
      await sendEmail(email, renderNotice(kind, language(profile.language)), `hold-lifted-${p.userId}-${p.previous}`);
    }
  },

  // A refused photo, approved on the second look the person asked for: they're told by email.
  async "media.approved_on_review"(p: { mediaId: string; userId: string }) {
    const { data: media } = await admin.from("profile_media").select("status").eq("id", p.mediaId).maybeSingle();
    // Deleted or refused again since: nothing to celebrate.
    if (media?.status !== "approved") return;
    const email = await accountEmail(p.userId);
    if (!email) return;
    const { data: profile } = await admin.from("profiles").select("language").eq("id", p.userId).maybeSingle();
    await sendEmail(email, renderNotice("photoApproved", language(profile?.language)), `photo-approved-${p.mediaId}`);
  },

  // A person decided (review_media, from the dashboard). A refusal reaches the owner like Rekognition's:
  // the same push, and an email too when they had asked for that second look (as an approval is, see
  // media.approved_on_review). An approval needs nothing more: the open app hears `media` on Realtime.
  // Moderation news, not an optional notification: no notify_* setting applies (same as media.created).
  async "media.reviewed"(p: {
    mediaId: string;
    userId: string;
    status: "approved" | "rejected";
    secondLook: boolean;
    at: string;
  }) {
    if (p.status !== "rejected") return;
    const { data: media, error } = await admin.from("profile_media").select("status").eq("id", p.mediaId)
      .maybeSingle();
    if (error) throw new Error(`media ${p.mediaId}: ${error.message}`);
    // Deleted, or sent for another look since: that decision will speak for itself.
    if (media?.status !== "rejected") return;
    const lang = await pushPhotoRefused(p.userId, p.mediaId);
    if (!p.secondLook || !lang) return;
    const email = await accountEmail(p.userId);
    if (!email) return;
    // One email per decision: a photo can be refused, sent back, and refused again.
    await sendEmail(email, renderNotice("photoRefused", lang), `photo-refused-${p.mediaId}-${p.at}`);
  },

  // A support request: the person gets their reference, the team a copy they can reply to.
  async "support.created"(p: { id: number }) {
    const [request] = must(await admin.rpc("support_request", { p_id: p.id }), "support request") as {
      reference: string;
      user_id: string | null;
      email: string;
      language: string;
      topic: string;
      message: string;
      context: Record<string, unknown>;
    }[];
    if (!request) return;
    await sendEmail(
      request.email,
      renderNotice("supportReceived", language(request.language), { reference: request.reference }),
      `support-ack-${request.reference}`,
    );
    await toTeam(
      `[support] ${request.reference} ${request.topic}`,
      [
        ["From", `${request.email}${request.user_id ? ` (account ${request.user_id})` : " (signed out)"}`],
        ["Language", request.language],
        ["Message", request.message],
        ["Context", JSON.stringify(request.context)],
      ],
      `support-team-${request.reference}`,
      request.email,
      request.email,
    );
  },

  // A reply written in sophros: emailed to the person, framed in their language; their answer goes to
  // SUPPORT_INBOX. A failed send is recorded on the message (the dashboard shows it) and retried.
  async "support.reply"(p: { id: number }) {
    const [reply] = must(await admin.rpc("support_reply", { p_id: p.id }), "support reply") as {
      reference: string;
      email: string;
      language: string;
      topic: string;
      message: string;
      body: string;
      sent_at: string | null;
    }[];
    if (!reply || reply.sent_at) return;
    try {
      await sendEmail(
        reply.email,
        renderSupportReply(language(reply.language), reply),
        `support-reply-${p.id}`,
        optionalEnv("SUPPORT_INBOX"),
      );
    } catch (error) {
      check(
        await admin.rpc("support_reply_sent", { p_id: p.id, p_error: String(error).slice(0, 500) }),
        "support reply failed",
      );
      throw error;
    }
    check(await admin.rpc("support_reply_sent", { p_id: p.id }), "support reply sent");
  },

  // A report: the team is told (the account may already be held, see reports_events).
  async "report.created"(p: { id: string }) {
    const [report] = must(await admin.rpc("report_details", { p_id: p.id }), "report") as {
      reporter: string | null;
      reported: string;
      reason: string;
      details: string;
      reported_hold: string | null;
    }[];
    if (!report) return;
    const reporterEmail = report.reporter ? await accountEmail(report.reporter) : null;
    await toTeam(
      `[report] ${report.reason}`,
      [
        ["Reported account", report.reported],
        ["Reported by", report.reporter ?? "(deleted account)"],
        ["Details", report.details || "(none)"],
        ["Account now", report.reported_hold ?? "not on hold"],
      ],
      `report-${p.id}`,
      reporterEmail,
    );
  },

  // You > Your data > Email me my export: the team prepares it (no automatic export yet).
  async "export.requested"(p: { id: number; userId: string }) {
    const email = await accountEmail(p.userId);
    await toTeam(
      "[data export] request",
      [
        ["Account", p.userId],
        ["Email", email ?? "(none)"],
        ["Promised", "a download link by email, usually within 24 hours (the app says so)"],
      ],
      `export-${p.id}`,
      email,
    );
  },

  // A hold was lifted after a selfie check: the selfies go (bucket verification-selfies). Held again
  // since (a new request): kept for now, the next lift deletes them all.
  async "selfie.delete"(p: { userId: string }) {
    const { data: profile, error } = await admin.from("profiles").select("moderation").eq("id", p.userId)
      .maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    if (profile?.moderation) return;
    const paths = must(await admin.rpc("selfie_paths", { p_user: p.userId }), "selfie paths") as string[];
    if (paths.length > 0) {
      const removed = await admin.storage.from("verification-selfies").remove(paths);
      if (removed.error) throw new Error(`selfies of ${p.userId}: ${removed.error.message}`);
    }
    check(await admin.rpc("forget_selfies", { p_user: p.userId }), "forget selfies");
  },

  // drafft tempo's free boost of the week was credited (private.credit_weekly_boosts). Tapping it
  // opens Discover, where the boost is used.
  async "boost.weekly"(p: { userId: string }) {
    const { data, error } = await admin.from("profiles").select("language, notify_weekly_boost").eq("id", p.userId)
      .maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    if (!data?.notify_weekly_boost) return;
    await pushToUser(p.userId, {
      title: pushTitle,
      body: weeklyBoost[language(data.language)],
      data: { kind: "weekly_boost" },
      collapseId: "weekly-boost",
    });
  },
};

/** The refusal push, in the person's language. The app shows its own banner when it's open (and hides this
 * push there). Returns the language, or null when the account is gone. */
async function pushPhotoRefused(userId: string, mediaId: string): Promise<Language | null> {
  const { data, error } = await admin.from("profiles").select("language").eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  if (!data) return null;
  const lang = language(data.language);
  await pushToUser(userId, {
    title: pushTitle,
    body: photoRefused[lang],
    data: { kind: "photo_refused", media: mediaId },
    collapseId: `photo-${mediaId}`,
  });
  return lang;
}

async function setStatus(mediaId: string, status: "approved" | "rejected") {
  check(await admin.from("profile_media").update({ status }).eq("id", mediaId), "media status");
}

// The session lives in Postgres; the chat gets a custom message pointing to it, from whoever acted.
async function sessionEvent(
  p: { sessionId: string; matchId: string; proposerId: string; actorId: string },
  status: "proposed" | "accepted" | "declined" | "cancelled",
) {
  const actor = status === "proposed" ? p.proposerId : p.actorId;
  // The match ended since (unmatch, block) or is gone: no channel to write in, and no push about it.
  const opened = await ensureChannel(p.matchId);
  if (!opened) return;
  const { channel, members } = opened;
  const session = must(
    await admin.from("sessions").select("sport_id, title").eq("id", p.sessionId).single(),
    "session",
  );
  const text = {
    proposed: "Proposed a session",
    accepted: "Accepted the session",
    declined: "Declined the session",
    cancelled: "Cancelled the session",
  }[status];
  await sendOnce(channel, {
    id: `session-${p.sessionId}-${status}`,
    user_id: actor,
    text,
    drafft: { type: "session", sessionId: p.sessionId, status },
  });

  const other = members.find((m) => m !== actor);
  if (!other) return;
  // Session updates are chat activity: they follow the Messages setting, like in the app.
  const lang = await recipient(other, "notify_messages");
  if (!lang) return;
  const name = (await firstName(actor)) ?? someone[lang];
  await pushToUser(other, {
    title: pushTitle,
    body: sessionChanged(lang, status, name, sessionName(lang, session.title, session.sport_id)),
    data: { match: p.matchId, session: p.sessionId },
    // A retried event replaces the push instead of adding a second one.
    collapseId: `session-${p.sessionId}-${status}`,
  });
}

serve(async (req) => {
  if (!safeEqual(req.headers.get("x-webhook-secret") ?? "", env("DB_EVENTS_SECRET"))) {
    throw new HttpError(401, "unauthorized");
  }
  const { id, event, payload } = await readJson<Event>(req);
  const handler = handlers[event];
  if (handler) {
    await handler(payload);
  } else {
    console.warn(`db-events: no handler for ${event}, acked`);
  }
  check(await admin.rpc("ack_event", { p_id: id }), "ack");
  return json({ ok: true });
});
