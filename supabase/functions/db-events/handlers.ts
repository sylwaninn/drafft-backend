// The db-events handlers, one per outbox event, and how an event is run (index.ts only checks the caller).
//
// Each handler is idempotent: the outbox retries until this function acks, so an event can arrive
// twice (a lost ack), out of order (a session event before its match channel exists), or replayed by an
// admin from sophros once it failed. Two layers make that safe:
// - each side effect is idempotent on its own where the provider allows it (Stream message ids, Resend
//   idempotency keys, APNs collapse ids, SQL guarded by the current state);
// - `ctx.once(step, …)` records each side effect done in the outbox row (`steps`), so a retry or a replay
//   runs only the steps still missing: an event that failed after its first push never pushes twice.
// Pushes carry the event's freshness (`pushUntil`, from the outbox policy): a stale one is skipped, never
// sent hours late after an outage.
import { optionalEnv } from "../_shared/env.ts";
import { type Push, pushToUser } from "../_shared/apns.ts";
import { deviceCheckConfigured, type DeviceEnvironment, updateBits } from "../_shared/devicecheck.ts";
import { deleteAuthUser, eraseChat, eraseChatUser, eraseMedia, eraseSelfies, freezeChat } from "../_shared/erase.ts";
import { isReservedAddress, sendEmail } from "../_shared/mailer.ts";
import { buildExport, exportLink, partPath, removeExtraParts, removeParts, storeExport } from "../_shared/export.ts";
import {
  type Decision,
  decisionCopy,
  renderDecision,
  renderExportReady,
  renderNotice,
  renderSupportReply,
  renderTeamEmail,
} from "../_shared/notices.ts";
import { deleteObject, getObject, headObject } from "../_shared/r2.ts";
import { moderateImage, moderationConfigured } from "../_shared/moderation.ts";
import { isGone, type Provider, ProviderError, trackProviders, viaProvider } from "../_shared/providers.ts";
import { ensureChannel, ensureUsers, sendOnce, setChatHeld, stream } from "../_shared/stream.ts";
import { admin, check, must } from "../_shared/supabase.ts";
import {
  decisionPush,
  decisionPushAlone,
  type Language,
  language,
  likeReceived,
  matchCreated,
  type ModerationPush,
  moderationPush,
  photoRefused,
  sessionAutoCancelled,
  sessionCard,
  sessionChanged,
  sessionName,
  sessionReminderEvening,
  sessionReminderHour,
  superLikeReceived,
  weeklyBoost,
} from "../_shared/texts.ts";

/** What private.deliver posts. */
export interface Event {
  id: number;
  event: string;
  payload: Record<string, unknown>;
  createdAt?: string;
  /** Steps already done by an earlier attempt. */
  steps?: string[];
  /** Pushes after this are stale and skipped. Null: no limit. */
  pushUntil?: string | null;
}

/** One delivery of an event: its steps, and whether its pushes are still fresh. */
export class EventContext {
  readonly steps: Set<string>;
  private readonly pushUntil: number | null;

  constructor(
    readonly id: number,
    steps: string[] = [],
    pushUntil: string | null = null,
    private readonly now = Date.now,
  ) {
    this.steps = new Set(steps);
    this.pushUntil = pushUntil ? Date.parse(pushUntil) : null;
  }

  done(step: string): boolean {
    return this.steps.has(step);
  }

  /** The value of a step recorded as `name=value` (a decision taken by an earlier attempt). */
  value(name: string): string | undefined {
    for (const step of this.steps) if (step.startsWith(`${name}=`)) return step.slice(name.length + 1);
    return undefined;
  }

  /** Runs a side effect unless an earlier attempt did, then records it. */
  async once(step: string, effect: () => Promise<unknown>): Promise<void> {
    if (this.steps.has(step)) return;
    await effect();
    await this.record(step);
  }

  async record(step: string): Promise<void> {
    this.steps.add(step);
    // Not recorded (rare): a retry may repeat this effect, which the provider's own idempotency absorbs.
    const { error } = await admin.rpc("outbox_step_done", { p_id: this.id, p_step: step });
    if (error) console.warn(`db-events: step ${step} of ${this.id} not recorded: ${error.message}`);
  }

  get pushFresh(): boolean {
    return this.pushUntil === null || this.now() <= this.pushUntil;
  }

  /** A push, once, while fresh. */
  async push(step: string, userId: string, push: Push): Promise<void> {
    if (this.steps.has(step)) return;
    if (!this.pushFresh) {
      console.log(`db-events: ${this.id} ${step} stale, not pushed`);
      return;
    }
    await pushToUser(userId, push);
    await this.record(step);
  }
}

// Each handler declares its own payload shape; the outbox writes them in migrations/..._events.sql.
// deno-lint-ignore no-explicit-any
type Handler = (payload: any, ctx: EventContext) => Promise<void>;

/** The first name shown to others, or null (no name yet, or the account is gone). */
async function firstName(userId: string): Promise<string | null> {
  const { data, error } = await admin.from("profiles").select("name").eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  return data?.name || null;
}

type Setting =
  | "notify_matches"
  | "notify_likes"
  | "notify_messages"
  | "notify_session_evening"
  | "notify_session_hour_before";

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
  ctx: EventContext,
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
  await ctx.once("team-email", () => sendEmail(inbox, renderTeamEmail(subject, lines), key, replyTo));
}

/** Where a member's reply to any email about their account goes: the support address, whose mail comes back into
 * sophros (support-inbound, README "Support by email"); until it is set, the team's mailbox (unset locally: the
 * sender, as before). */
function supportReplyTo(): string | undefined {
  return optionalEnv("SUPPORT_ADDRESS") ?? optionalEnv("SUPPORT_INBOX");
}

/** Stream ban on or off from the account's current hold. Deleted since: the account and its chats are gone. */
async function syncChatHold(userId: string) {
  const { data, error } = await admin.from("profiles").select("moderation, deleted_at").eq("id", userId)
    .maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  if (!data) return;
  await setChatHeld(userId, data.moderation !== null || data.deleted_at !== null);
}

export const handlers: Record<string, Handler> = {
  // Push for a like, unless it made a match (match.created pushes instead). No name: the Likes tab
  // is where people see who it was.
  async "like.received"(p: { from: string; to: string; superLike: boolean }, ctx) {
    const [a, b] = [p.from, p.to].sort();
    const { data: match, error } = await admin.from("matches").select("id").eq("user_a", a).eq("user_b", b)
      .maybeSingle();
    if (error) throw new Error(`match lookup: ${error.message}`);
    if (match) return;
    const lang = await recipient(p.to, "notify_likes");
    if (!lang) return;
    await ctx.push("push", p.to, {
      ...(p.superLike ? superLikeReceived : likeReceived)[lang],
      data: { tab: "likes" },
      collapseId: "likes",
    });
  },

  // Chat channel, then the openers each person attached to their like, then a push to both. Ended or gone
  // by the time it's delivered: nothing (no channel, no opener, no "It's mutual").
  async "match.created"(p: { matchId: string; userA: string; userB: string }, ctx) {
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
        await ctx.once(`note-${s.swiper}`, () =>
          sendOnce(channel, {
            id: `note-${p.matchId}-${s.swiper}`,
            user_id: s.swiper,
            text: s.note,
            drafft: { type: "superLikeNote" },
          }));
      }
      const opener = s.opener as Record<string, string> | null;
      // Session openers became real sessions in the database; session.proposed posts them.
      if (!opener || opener.kind === "session") continue;
      await ctx.once(`opener-${s.swiper}`, () =>
        sendOnce(channel, {
          id: `opener-${p.matchId}-${s.swiper}`,
          user_id: s.swiper,
          text: opener.reply ?? opener.text ?? "",
          drafft: { type: opener.kind, ...opener },
        }));
    }
    if (!ctx.pushFresh) return;
    const [nameA, nameB, langA, langB] = await Promise.all([
      firstName(p.userA),
      firstName(p.userB),
      recipient(p.userA, "notify_matches"),
      recipient(p.userB, "notify_matches"),
    ]);
    // One after the other, each recorded: a retry never tells the first person twice.
    if (langA) {
      await ctx.push("push-a", p.userA, {
        ...matchCreated(langA, nameB),
        data: { match: p.matchId },
        collapseId: `match-${p.matchId}`,
      });
    }
    if (langB) {
      await ctx.push("push-b", p.userB, {
        ...matchCreated(langB, nameA),
        data: { match: p.matchId },
        collapseId: `match-${p.matchId}`,
      });
    }
  },

  // Unmatch, block, report, or a deleted account kept for safety: the chat disappears for both and nobody
  // can write in it, but it is kept a year (then `chat.erase`), so the team can still read it in sophros (server
  // side, with the secret). Both members leave the channel (it leaves their channel lists, and members only can
  // read a messaging channel), then it is frozen (no message or reaction from anyone). Both calls are
  // idempotent. No channel yet (nobody wrote) or an erased account (the channel went with it): nothing to do.
  async "match.ended"(p: { matchId: string }) {
    const { data: match, error } = await admin.from("matches").select("user_a, user_b").eq("id", p.matchId)
      .maybeSingle();
    if (error) throw new Error(`match ${p.matchId}: ${error.message}`);
    if (!match) return;
    await freezeChat(p.matchId, [match.user_a, match.user_b]);
  },

  // An account kept after its owner deleted it (retain_deleted_account): banned from chat for good, and every
  // Stream token issued so far revoked, so the app still holding one can't connect. Its channels were frozen
  // by match.ended. Never in Stream (never opened the chat): the ban creates the user, the revoke then holds.
  async "account.soft_deleted"(p: { userId: string }, ctx) {
    await ctx.once("ban", () => setChatHeld(p.userId, true));
    await ctx.once("revoke", () => viaProvider("stream", () => stream().revokeUserToken(p.userId, new Date())));
  },

  "session.proposed": (p, ctx) => sessionEvent(p, "proposed", ctx),
  "session.accepted": (p, ctx) => sessionEvent(p, "accepted", ctx),
  "session.declined": (p, ctx) => sessionEvent(p, "declined", ctx),
  "session.cancelled": (p, ctx) => sessionEvent(p, "cancelled", ctx),

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
  }, ctx) {
    // An ended match has no chat to write in (ensureChannel never reopens it): the push alone.
    const opened = p.chatFrom ? await ensureChannel(p.matchId) : null;
    if (p.chatFrom && opened) {
      await ctx.once("message", () =>
        sendOnce(opened.channel, {
          id: `session-${p.sessionId}-cancelled`,
          user_id: p.chatFrom as string,
          text: sessionCard.cancelled,
          drafft: { type: "session", sessionId: p.sessionId, status: "cancelled" },
        }));
    }
    // Session updates follow the Messages setting, like the other session pushes. A session already past:
    // nothing to warn about any more.
    if (!p.notify || (p.at && Date.parse(p.at) < Date.now())) return;
    await ctx.push("push", p.to, {
      ...sessionAutoCancelled(language(p.language), p.at ? new Date(p.at) : null, p.timezone),
      data: { kind: "session_cancelled", session: p.sessionId },
      // A retried event replaces the push instead of adding a second one.
      collapseId: `session-cancelled-${p.sessionId}`,
    });
  },

  // A reminder queued by private.queue_session_reminders (the evening before at 20:00, or an hour before, in
  // the person's time zone). The state is checked again at send time: a session cancelled, moved or whose
  // match ended since sends nothing, and a setting turned off since is respected.
  async "session.reminder"(p: {
    sessionId: string;
    matchId: string;
    to: string;
    kind: "evening" | "hour";
    at: string;
    timezone: string;
  }, ctx) {
    if (!ctx.pushFresh) return;
    const { data: session, error } = await admin.from("sessions")
      .select("status, chosen_at, sport_id, title, match_id").eq("id", p.sessionId).maybeSingle();
    if (error) throw new Error(`session ${p.sessionId}: ${error.message}`);
    if (!session || session.status !== "accepted" || !session.chosen_at) return;
    if (Date.parse(session.chosen_at as string) !== Date.parse(p.at) || Date.parse(p.at) < Date.now()) return;
    const { data: match, error: matchError } = await admin.from("matches").select("ended_at, user_a, user_b")
      .eq("id", session.match_id as string).maybeSingle();
    if (matchError) throw new Error(`match ${session.match_id}: ${matchError.message}`);
    if (!match || match.ended_at) return;
    const lang = await recipient(p.to, p.kind === "evening" ? "notify_session_evening" : "notify_session_hour_before");
    if (!lang) return;
    const name = sessionName(lang, session.title as string | null, session.sport_id as string);
    // Who it's with, by first name ("With Maya: Padel session"); no name: the session alone.
    const partner = await firstName((match.user_a === p.to ? match.user_b : match.user_a) as string);
    await ctx.push("push", p.to, {
      ...(p.kind === "evening"
        ? sessionReminderEvening(lang, name, new Date(p.at), p.timezone, partner)
        : sessionReminderHour(lang, name, partner)),
      data: { kind: "session_reminder", match: p.matchId, session: p.sessionId },
      collapseId: `session-reminder-${p.sessionId}-${p.kind}`,
    });
  },

  // Moderation gate. Nothing is visible to others until approved. The verdict and its flag are written
  // together (apply_media_verdict); a retry after that only sends what's missing (the refusal push).
  async "media.created"(p: { mediaId: string; userId: string; key: string; posterKey?: string }, ctx) {
    const { data: media, error } = await admin.from("profile_media").select("status").eq("id", p.mediaId)
      .maybeSingle();
    // An error must not be acked as "nothing to do": throw, and the outbox retries.
    if (error) throw new Error(`media ${p.mediaId}: ${error.message}`);
    // Deleted since.
    if (!media) return;
    let verdict = ctx.value("verdict");
    // Decided since, by someone else (a person in sophros): theirs stands.
    if (!verdict && media.status !== "pending") return;

    if (!verdict) {
      const size = await headObject(p.key);
      const posterOk = !p.posterKey || (await headObject(p.posterKey)) !== null;
      if (size === null || !posterOk) {
        // The upload never finished: nothing for anyone to look at, no flag.
        await setStatusIfPending(p.mediaId, "rejected");
        return;
      }
      // Rekognition when configured. Videos are judged on their poster frame. `review` (borderline
      // labels, or an image over Rekognition's 5 MB) leaves the media pending for a human.
      if (moderationConfigured()) {
        const bytes = await getObject(p.posterKey ?? p.key);
        if (!bytes) {
          await setStatusIfPending(p.mediaId, "rejected");
          return;
        }
        if (bytes.length > 5 * 1024 * 1024) {
          console.warn(`moderation: ${p.mediaId} over 5 MB, left for review`);
          return;
        }
        const judged = await moderateImage(bytes);
        console.log(`moderation: ${p.mediaId} ${judged.verdict} ${judged.labels.join(", ")}`);
        const applied = must(
          await admin.rpc("apply_media_verdict", {
            p_media: p.mediaId,
            p_verdict: judged.verdict,
            p_labels: judged.labels,
          }),
          "media verdict",
        ) as boolean;
        // Someone decided in the meantime.
        if (!applied) return;
        verdict = judged.verdict;
        await ctx.record(`verdict=${verdict}`);
      } else {
        // MODERATION_MODE: "auto_approve" for local development only. Otherwise media stays pending.
        if (optionalEnv("MODERATION_MODE") === "auto_approve") await setStatusIfPending(p.mediaId, "approved");
        return;
      }
    }
    if (verdict === "rejected") await pushPhotoRefused(ctx, p.userId, p.mediaId);
  },

  async "media.deleted"(p: { keys: string[] }) {
    await Promise.all(p.keys.map(deleteObject));
  },

  // Messages on or off in the app: Stream sends chat pushes, so it gets the same setting.
  async "push.preferences"(p: { userId: string; messages: boolean }) {
    await ensureUsers([p.userId]);
    await viaProvider(
      "stream",
      () => stream().setPushPreferences([{ user_id: p.userId, chat_level: p.messages ? "all" : "none" }]),
    );
  },

  // Name, app language or message previews changed: Stream's user carries them, so the message pushes Stream
  // sends are in the person's language and show the text only with previews on. Reads the profile now, so a
  // late or replayed event still writes the current values.
  async "stream.user"(p: { userId: string }) {
    await ensureUsers([p.userId]);
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
  async "account.moderation"(p: { userId: string; state?: string | null; previous: string | null }, ctx) {
    const { data: profile, error } = await admin.from("profiles").select("moderation, language, deleted_at")
      .eq("id", p.userId).maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    // Deleted since: the bits set earlier stay, which is the point.
    if (!profile) return;
    const state = profile.moderation as string | null;

    // Chats read-only while held, writable again once lifted (a hold on an already paused profile
    // doesn't change `paused`, so profile.paused alone would miss it).
    // An account kept after deletion stays banned (account.soft_deleted).
    await setChatHeld(p.userId, state !== null || profile.deleted_at !== null);

    if (deviceCheckConfigured() && !ctx.done("devicecheck")) {
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
      await ctx.record("devicecheck");
    }

    await pushModeration(ctx, p, state, profile.language);

    if (state === null && p.previous) {
      const email = await accountEmail(p.userId);
      if (!email) return;
      const kind = p.previous === "banned" ? "accountReopened" : "accountRestored";
      await ctx.once(
        "email",
        () =>
          sendEmail(
            email,
            renderNotice(kind, language(profile.language)),
            `hold-lifted-${p.userId}-${p.previous}`,
            supportReplyTo(),
          ),
      );
    }
  },

  // A refused photo, approved on the second look the person asked for: they're told by email.
  async "media.approved_on_review"(p: { mediaId: string; userId: string }, ctx) {
    const { data: media, error } = await admin.from("profile_media").select("status").eq("id", p.mediaId)
      .maybeSingle();
    // A failed read is not "nothing to do": throw, and the outbox retries.
    if (error) throw new Error(`media ${p.mediaId}: ${error.message}`);
    // Deleted or refused again since: nothing to celebrate.
    if (media?.status !== "approved") return;
    const email = await accountEmail(p.userId);
    if (!email) return;
    const { data: profile, error: profileError } = await admin.from("profiles").select("language")
      .eq("id", p.userId).maybeSingle();
    if (profileError) throw new Error(`profile ${p.userId}: ${profileError.message}`);
    await ctx.once(
      "email",
      () =>
        sendEmail(
          email,
          renderNotice("photoApproved", language(profile?.language)),
          `photo-approved-${p.mediaId}`,
          supportReplyTo(),
        ),
    );
  },

  // A person decided (review_media, from the dashboard). A refusal reaches the owner like Rekognition's: the same
  // push. The email is the statement of reasons (`moderation.decision`, recorded with the refusal), never a second
  // one. An approval needs nothing more: the open app hears `media` on Realtime.
  // Moderation news, not an optional notification: no notify_* setting applies (same as media.created).
  async "media.reviewed"(p: {
    mediaId: string;
    userId: string;
    status: "approved" | "rejected";
    secondLook: boolean;
    at: string;
  }, ctx) {
    if (p.status !== "rejected") return;
    const { data: media, error } = await admin.from("profile_media").select("status").eq("id", p.mediaId)
      .maybeSingle();
    if (error) throw new Error(`media ${p.mediaId}: ${error.message}`);
    // Deleted, or sent for another look since: that decision will speak for itself.
    if (media?.status !== "rejected") return;
    await pushPhotoRefused(ctx, p.userId, p.mediaId);
  },

  // A support request: the person gets their reference, the team a copy they can reply to.
  async "support.created"(p: { id: number }, ctx) {
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
    const byEmail = request.context?.source === "email";
    // An email whose sender Cloudflare didn't vouch for: no acknowledgement to an address that may not have written.
    const unverifiedEmail = byEmail && request.context?.verified !== true;
    if (!unverifiedEmail) {
      await ctx.once("email", () =>
        sendEmail(
          request.email,
          renderNotice("supportReceived", language(request.language), { reference: request.reference }),
          `support-ack-${request.reference}`,
          supportReplyTo(),
        ));
    }
    let from = request.email;
    if (request.user_id) from += ` (account ${request.user_id})`;
    else if (!byEmail) from += " (signed out)";
    if (byEmail) from += ` (by email, ${unverifiedEmail ? "sender NOT verified" : "sender verified"})`;
    await toTeam(
      ctx,
      `[support] ${request.reference} ${request.topic}`,
      [
        ["From", from],
        ["Language", request.language],
        ["Message", request.message],
        ["Context", JSON.stringify(request.context)],
      ],
      `support-team-${request.reference}`,
      request.email,
      request.email,
    );
  },

  // A reply written in sophros: emailed to the person, framed in their language; their answer goes to the
  // support address and back into the request (support-inbound; SUPPORT_INBOX until SUPPORT_ADDRESS is set). A
  // failed send is recorded on the message (the dashboard shows it) and retried. Only the team's messages.
  async "support.reply"(p: { id: number }) {
    const [reply] = must(await admin.rpc("support_reply", { p_id: p.id }), "support reply") as {
      reference: string;
      email: string;
      language: string;
      topic: string;
      message: string;
      body: string;
      sent_at: string | null;
      direction: "in" | "out";
    }[];
    if (!reply || reply.sent_at) return;
    // A member's own message (received by email) is never sent back to them.
    if (reply.direction !== "out") {
      console.warn(`db-events: support.reply ${p.id} is a received message, not sent`);
      return;
    }
    try {
      await sendEmail(
        reply.email,
        renderSupportReply(language(reply.language), reply),
        `support-reply-${p.id}`,
        supportReplyTo(),
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

  // A member's email, filed in its request and the request reopened (receive_support_email): the team's copy in
  // SUPPORT_INBOX, next to the thread in sophros. A reply to the copy goes to the member.
  async "support.received"(p: { id: number }, ctx) {
    const [message] = must(await admin.rpc("support_reply", { p_id: p.id }), "support message") as {
      reference: string;
      email: string;
      topic: string;
      body: string;
      author: string;
      direction: "in" | "out";
    }[];
    if (!message) return;
    if (message.direction !== "in") {
      console.warn(`db-events: support.received ${p.id} is a team message, no copy`);
      return;
    }
    await toTeam(
      ctx,
      `[support] ${message.reference} ${message.topic}: new message`,
      [
        ["From", message.author],
        ["Message", message.body],
        ["Status", "reopened, answer it in sophros"],
      ],
      `support-received-${p.id}`,
      message.author,
      message.author,
    );
  },

  // A report: the team is told (the account may already be held, see reports_events).
  async "report.created"(p: { id: string }, ctx) {
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
      ctx,
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

  // You › Privacy & data › Export my data: the export (export.ts), in as many parts as it takes, goes to the
  // private bucket data-exports and is recorded at once (export_stored: the parts expire 7 days on whatever happens
  // next); the person gets one email with a link per part, valid 7 days, in their language, and the request is
  // fulfilled. One build at a time (export_begin): a delivery arriving while another builds is retried later. A
  // retry skips what was done: the stored parts (`parts=<n>`), the email (also idempotent at Resend). No email
  // address on the account: nothing is built, the team is told and the request closed. The team also hears of
  // files left out.
  async "export.requested"(p: { id: number; userId: string }, ctx) {
    const id = requestId(p.id);
    const userId = uuid(p.userId, "userId");
    const state = must(await admin.rpc("export_begin", { p_id: id }), "export begin") as string;
    if (state === "gone" || state === "done") return;
    if (state === "busy") throw new Error(`export ${id}: another delivery is building it`);
    const email = await accountEmail(userId);
    if (!email) {
      await toTeam(
        ctx,
        "[data export] no email address",
        [
          ["Account", userId],
          ["Request", String(id)],
          ["What happened", "No export was built: the account has no email address to send it to. Request closed."],
          ["What to do", "Reach the person another way if needed; they can ask again once they add an email."],
        ],
        `export-team-${id}`,
        null,
      );
      check(await admin.rpc("export_closed", { p_id: id, p_reason: "no_email" }), "export closed");
      return;
    }
    let parts = Number(ctx.value("parts") ?? 0);
    if (!parts) {
      const built = await buildExport(userId, async (part, archive) => {
        const path = partPath(userId, id, part);
        await storeExport(path, archive);
        return path;
      });
      if (!built) return;
      await removeExtraParts(userId, id, built.paths.length);
      const kept = must(await admin.rpc("export_stored", { p_id: id, p_paths: built.paths }), "export stored");
      if (kept !== true) {
        // The request went with its account while the parts were built: nothing may outlive it.
        await removeParts(built.paths);
        return;
      }
      const left = built.tooLarge.length + built.missing.length;
      if (left > 0) await ctx.record(`omitted=${built.tooLarge.length},${built.missing.length}`);
      await ctx.record(`parts=${built.paths.length}`);
      parts = built.paths.length;
    }
    const { data: profile, error } = await admin.from("profiles").select("language").eq("id", userId).maybeSingle();
    if (error) throw new Error(`profile ${userId}: ${error.message}`);
    const links: string[] = [];
    for (let part = 1; part <= parts; part++) links.push(await exportLink(partPath(userId, id, part), part, parts));
    await ctx.once(
      "email",
      () =>
        sendEmail(
          email,
          renderExportReady(language(profile?.language), links),
          `export-${id}`,
          supportReplyTo(),
        ),
    );
    const omitted = ctx.value("omitted");
    if (omitted) {
      const [tooLarge, missing] = omitted.split(",").map(Number);
      await toTeam(
        ctx,
        "[data export] files left out",
        [
          ["Account", userId],
          ["Larger than one part (EXPORT_MAX_BYTES)", `${tooLarge}: listed in data.json, send them another way`],
          ["Listed in the database, missing in R2", `${missing}: listed in data.json`],
        ],
        `export-team-${id}`,
        email,
      );
    }
    if (must(await admin.rpc("export_ready", { p_id: id }), "export ready") !== true) {
      console.warn(`db-events: export ${id} emailed, but its request has no stored parts any more`);
    }
  },

  // An export past its 7 days (private.queue_export_expiries): its parts go, the request remembers it.
  async "export.expired"(p: { id: number }) {
    const id = requestId(p.id);
    const { data: paths, error } = await admin.rpc("export_files", { p_id: id });
    if (error) throw new Error(`export files ${id}: ${error.message}`);
    if (Array.isArray(paths) && paths.length > 0) await removeParts(paths as string[]);
    check(await admin.rpc("export_file_deleted", { p_id: id }), "export file deleted");
  },

  // Objects of the data-exports bucket no request refers to any more (private.queue_export_sweep): a build that
  // failed for good after storing some parts. Deleted, and logged.
  async "export.sweep"(p: { paths: string[] }) {
    const paths = (p.paths ?? []).filter((path) => /^[0-9a-f-]{36}\/[0-9]+-[0-9]+\.zip$/.test(path));
    if (paths.length === 0) return;
    console.warn(`db-events: ${paths.length} export parts no request refers to, deleted`);
    await removeParts(paths);
  },

  // A decision by a person on the team (private.record_decision): the statement of reasons, emailed in the
  // person's language with Reply-To the support address, and pushed when no other push says it (a removed
  // message, a review, a ban, a selfie asked again: `repeat`, the state didn't change so account.moderation pushed
  // nothing). A removed message is told once Stream shows it removed: sophros logs the removal just before making
  // it, so until then the event is retried, and one that never happened ends in the dead letters.
  async "moderation.decision"(p: { id: number; repeat?: boolean }, ctx) {
    const [decision] = must(await admin.rpc("moderation_decision", { p_id: p.id }), "decision") as {
      user_id: string;
      kind: Decision;
      category: string;
      terms_anchor: string | null;
      details: string | null;
      target: string | null;
      language: string | null;
    }[];
    // The account was erased since: nobody to tell.
    if (!decision) return;
    if (!(decision.kind in decisionCopy)) throw new Error(`decision ${p.id}: unknown kind ${decision.kind}`);
    if (decision.kind === "message_deleted" && !ctx.done("removed")) {
      await messageRemoved(decision.target?.split("/")[1] ?? "");
      await ctx.record("removed");
    }
    const lang = language(decision.language);
    const email = await accountEmail(decision.user_id);
    if (email) {
      await ctx.once("email", () =>
        sendEmail(
          email,
          renderDecision(lang, decision.kind, decision.category, decision.terms_anchor, decision.details),
          `decision-${p.id}`,
          supportReplyTo(),
        ));
    } else {
      console.warn(`db-events: decision ${p.id} not emailed, the account has no email address`);
    }
    if (decision.kind in decisionPush) {
      const kind = decision.kind as keyof typeof decisionPush;
      await ctx.push("push", decision.user_id, {
        // Without an email, the push can't point to one.
        ...(email ? decisionPush : decisionPushAlone)[kind][lang],
        data: { kind: "moderation" },
        // A hold replaces the moderation push before it on the lock screen; each removed message is its own.
        collapseId: kind === "message_deleted" ? `decision-${p.id}` : `moderation-${decision.user_id}`,
      });
    } else if (decision.kind === "account_selfie" && p.repeat) {
      // Only while the selfie is still due: lifted or changed since, that change speaks for itself.
      const { data: profile, error } = await admin.from("profiles").select("moderation").eq("id", decision.user_id)
        .maybeSingle();
      if (error) throw new Error(`profile ${decision.user_id}: ${error.message}`);
      if (profile?.moderation !== "selfie") return;
      await ctx.push("push", decision.user_id, {
        ...moderationPush.selfieRequested[lang],
        data: { kind: "moderation" },
        collapseId: `moderation-${decision.user_id}`,
      });
    }
  },

  // A hold was lifted after a selfie check: the selfies go (bucket verification-selfies). Held again
  // since (a new request): kept for now, the next lift deletes them all.
  async "selfie.delete"(p: { userId: string }) {
    const { data: profile, error } = await admin.from("profiles").select("moderation").eq("id", p.userId)
      .maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    if (profile?.moderation) return;
    await eraseSelfies(uuid(p.userId, "userId"));
  },

  // A banned account's selfies, kept 6 months for an appeal (private.queue_retention_purges). Reopened since,
  // or banned again more recently: not due, the database says.
  async "selfie.expired"(p: { userId: string }) {
    const userId = uuid(p.userId, "userId");
    if (!await due("banned_selfies_due", { p_user: userId })) return;
    await eraseSelfies(userId);
  },

  // An account kept for safety, its case closed over a year ago: erased like delete-account erases one. Its
  // chats were ended at its deletion, so most went a year after it (`chat.erase`); any left go here, with what
  // either member sent in them. Then its Stream user, its media and selfies, and last its Auth user, which takes
  // its rows with it (a banned account's moderation history stays, for its 3 years). A hold or a report
  // reopened since keeps it: the database says whether it is still due, until the Auth user is gone.
  async "account.purge"(p: { userId: string }, ctx) {
    const userId = uuid(p.userId, "userId");
    if (!ctx.done("auth") && !await due("retained_account_due", { p_user: userId })) return;
    // Its matches, read once and kept in the steps: they go with the Auth user.
    let ids = ctx.value("matches");
    if (ids === undefined) {
      const rows = must(
        await admin.from("matches").select("id").or(`user_a.eq.${userId},user_b.eq.${userId}`),
        "matches",
      ) as { id: string }[];
      ids = rows.map((m) => m.id).join(",");
      await ctx.record(`matches=${ids}`);
    }
    const matches = ids === "" ? [] : ids.split(",");
    for (const m of matches) await ctx.once(`chat-${m}`, () => eraseChat(m));
    await ctx.once("chat-user", () => eraseChatUser(userId));
    await ctx.once("media", () => eraseMedia(userId));
    await ctx.once("selfies", () => eraseSelfies(userId));
    await ctx.once("auth", () => deleteAuthUser(userId));
    // After the Auth user: erasing its matches tracked their chats again.
    for (const m of matches) check(await admin.rpc("chat_erased", { p_match: m }), "chat erased");
  },

  // A chat that ended over a year ago (an ended match, or one kept when an account was deleted): its media
  // and its channel go. Erased already with a kept account: nothing to do.
  async "chat.erase"(p: { matchId: string }, ctx) {
    const matchId = uuid(p.matchId, "matchId");
    if (!ctx.done("chat") && !await due("chat_erase_due", { p_match: matchId })) return;
    await ctx.once("chat", () => eraseChat(matchId));
    check(await admin.rpc("chat_erased", { p_match: matchId }), "chat erased");
  },

  // Once, after migration 20260930000201: the frozen channels Stream still has, oldest first, so those whose
  // match row went before chat_retention existed get tracked (public.track_frozen_chats) and erased a year
  // after their last update. Resumes from the last channel it recorded.
  async "chat.sweep"(_p: Record<string, never>, ctx) {
    const pageSize = 30;
    let after = ctx.value("after") ?? "1970-01-01T00:00:00Z";
    for (;;) {
      const page = await viaProvider("stream", () =>
        stream().queryChannelsRequest(
          { type: "messaging", frozen: true, created_at: { $gt: after } },
          [{ created_at: 1 }],
          { limit: pageSize, message_limit: 0, state: false, watch: false, presence: false },
        )) as { channel: { id: string; created_at?: string; updated_at?: string } }[];
      if (page.length === 0) return;
      const chats = page.map(({ channel }) => ({ id: channel.id, at: channel.updated_at ?? channel.created_at }));
      check(await admin.rpc("track_frozen_chats", { p_chats: chats }), "track frozen chats");
      after = page.at(-1)!.channel.created_at ?? after;
      await ctx.record(`after=${after}`);
      if (page.length < pageSize) return;
    }
  },

  // drafft tempo's free boost of the week was credited (private.credit_weekly_boosts). Tapping it
  // opens Discover, where the boost is used.
  async "boost.weekly"(p: { userId: string }, ctx) {
    const { data, error } = await admin.from("profiles").select("language, notify_weekly_boost").eq("id", p.userId)
      .maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    if (!data?.notify_weekly_boost) return;
    await ctx.push("push", p.userId, {
      ...weeklyBoost[language(data.language)],
      data: { kind: "weekly_boost" },
      collapseId: "weekly-boost",
    });
  },
};

/** Moderation news the person waits for, pushed: a hold lifted (reopened after a ban, a selfie approved,
 * or a review cleared), a selfie asked for, or asked again after one wasn't enough. Never a new
 * restriction (review, ban): the app's own screen says those, and a person's decision is pushed with its
 * statement (`moderation.decision`). Only while the state is still the one this event is about: a later change
 * speaks for itself. The open app hides it (its screen already changed). */
async function pushModeration(
  ctx: EventContext,
  p: { userId: string; state?: string | null; previous: string | null },
  state: string | null,
  lang: string | null,
) {
  if (p.state !== undefined && p.state !== state) return;
  let kind: ModerationPush | null = null;
  if (state === null && p.previous) {
    if (p.previous === "banned") kind = "reopened";
    else if (p.previous === "review" && await reviewWasSelfie(p.userId)) kind = "selfieApproved";
    else kind = "restored";
  } else if (state === "selfie") {
    kind = p.previous === "review" && await reviewWasSelfie(p.userId) ? "selfieRetry" : "selfieRequested";
  }
  if (!kind) return;
  await ctx.push("push", p.userId, {
    ...moderationPush[kind][language(lang)],
    data: { kind: "moderation" },
    // One moderation push at a time: a newer state replaces the older one on the lock screen.
    collapseId: `moderation-${p.userId}`,
  });
}

type DueRpc = "retained_account_due" | "chat_erase_due" | "banned_selfies_due";

/** Whether a purge is still due, asked of the database at delivery (the state may have changed since queued). */
async function due(rpc: DueRpc, args: Record<string, string>): Promise<boolean> {
  const result = await admin.rpc(rpc, args);
  check(result, rpc);
  return result.data === true;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** A request id from a payload. */
function requestId(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) throw new Error(`invalid request id`);
  return value;
}

/** An id from a payload, checked before it reaches a filter or an erasure. */
function uuid(value: unknown, name: string): string {
  if (typeof value !== "string" || !UUID.test(value)) throw new Error(`invalid ${name}: ${String(value).slice(0, 60)}`);
  return value;
}

/** Throws until Stream shows the message removed (soft-deleted, or gone altogether: HTTP 404 or code 16). */
async function messageRemoved(messageId: string) {
  if (!messageId) throw new Error("decision: no message id");
  try {
    const { message } = await viaProvider("stream", () => stream().getMessage(messageId));
    if (message.type === "deleted" || message.deleted_at) return;
  } catch (error) {
    if (isGone(error)) return;
    throw error;
  }
  throw new Error(`decision: message ${messageId} not removed yet`);
}

async function reviewWasSelfie(userId: string): Promise<boolean> {
  const result = await admin.rpc("review_was_selfie", { p_user: userId });
  check(result, "review was selfie");
  return result.data === true;
}

/** The refusal push, in the person's language. The app shows its own banner when it's open (and hides this
 * push there). Returns the language, or null when the account is gone. */
async function pushPhotoRefused(ctx: EventContext, userId: string, mediaId: string): Promise<Language | null> {
  const { data, error } = await admin.from("profiles").select("language").eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  if (!data) return null;
  const lang = language(data.language);
  await ctx.push("push", userId, {
    ...photoRefused[lang],
    data: { kind: "photo_refused", media: mediaId },
    collapseId: `photo-${mediaId}`,
  });
  return lang;
}

/** Only while still pending: a person's decision taken meanwhile stands. */
async function setStatusIfPending(mediaId: string, status: "approved" | "rejected") {
  check(await admin.from("profile_media").update({ status }).eq("id", mediaId).eq("status", "pending"), "media status");
}

// The session lives in Postgres; the chat gets a custom message pointing to it, from whoever acted.
async function sessionEvent(
  p: { sessionId: string; matchId: string; proposerId: string; actorId: string },
  status: "proposed" | "accepted" | "declined" | "cancelled",
  ctx: EventContext,
) {
  const actor = status === "proposed" ? p.proposerId : p.actorId;
  // The match ended since (unmatch, block) or is gone: no channel to write in, and no push about it.
  const opened = await ensureChannel(p.matchId);
  if (!opened) return;
  const { channel, members } = opened;
  const session = must(
    await admin.from("sessions").select("sport_id, title, options, chosen_at").eq("id", p.sessionId).single(),
    "session",
  );
  // English on purpose (see sessionCard): the app draws the card from `drafft`, never from this text.
  const text = sessionCard[status];
  await ctx.once("message", () =>
    sendOnce(channel, {
      id: `session-${p.sessionId}-${status}`,
      user_id: actor,
      text,
      drafft: { type: "session", sessionId: p.sessionId, status },
    }));

  const other = members.find((m) => m !== actor);
  if (!other) return;
  // Session updates are chat activity: they follow the Messages setting, like in the app.
  if (!ctx.pushFresh) return;
  // Every time it was about has passed: the push would only be noise.
  const times = session.chosen_at ? [session.chosen_at as string] : (session.options as string[] | null) ?? [];
  if (times.length > 0 && times.every((t) => Date.parse(t) < Date.now())) return;
  const lang = await recipient(other, "notify_messages");
  if (!lang) return;
  await ctx.push("push", other, {
    ...sessionChanged(lang, status, await firstName(actor), sessionName(lang, session.title, session.sport_id)),
    // A cancel reads like the automatic one (`session.auto_cancelled`) to the app: same kind.
    data: status === "cancelled"
      ? { kind: "session_cancelled", match: p.matchId, session: p.sessionId }
      : { match: p.matchId, session: p.sessionId },
    // A retried event replaces the push instead of adding a second one.
    collapseId: `session-${p.sessionId}-${status}`,
  });
}

/**
 * Runs one event and answers the outbox: acked when handled (with the providers reached, which closes
 * their half-open circuits), or reported failed with the provider that failed and whether it was down,
 * then rethrown (the outbox retries, or waits for the provider).
 */
export async function runEvent(body: Event): Promise<void> {
  const { id, event, payload } = body;
  const handler = handlers[event];
  const ctx = new EventContext(id, body.steps ?? [], body.pushUntil ?? null);
  const reached = new Set<Provider>();
  try {
    if (handler) {
      await trackProviders(reached, () => handler(payload, ctx));
    } else {
      console.warn(`db-events: no handler for ${event}, acked`);
    }
  } catch (error) {
    const failed = error instanceof ProviderError ? error : null;
    const { error: reportError } = await admin.rpc("outbox_failed", {
      p_id: id,
      p_error: String(error instanceof Error ? error.message : error).slice(0, 1000),
      p_provider: failed?.provider ?? null,
      p_transient: failed?.transient ?? false,
      p_providers: [...reached],
    });
    if (reportError) console.error(`db-events: failure of ${id} not recorded: ${reportError.message}`);
    throw error;
  }
  check(await admin.rpc("ack_event", { p_id: id, p_providers: [...reached] }), "ack");
}
