// POST /db-events { id, event, payload }, from the database outbox (pg_net), never from the app.
//
// Each handler is idempotent: the outbox retries until this function acks, so an event can arrive
// twice (a lost ack) or out of order (a session event before its match channel exists).
import { env, optionalEnv } from "../_shared/env.ts";
import { pushToUser } from "../_shared/apns.ts";
import { HttpError, json, readJson, safeEqual, serve } from "../_shared/http.ts";
import { deleteObject, getObject, headObject } from "../_shared/r2.ts";
import { moderateImage, moderationConfigured } from "../_shared/moderation.ts";
import { ensureChannel, ensureUsers, sendOnce, setChatPaused, stream } from "../_shared/stream.ts";
import { admin, check, must } from "../_shared/supabase.ts";
import { language, weeklyBoost } from "../_shared/texts.ts";

interface Event {
  id: number;
  event: string;
  payload: Record<string, unknown>;
}

// Each handler declares its own payload shape; the outbox writes them in migrations/..._events.sql.
// deno-lint-ignore no-explicit-any
type Handler = (payload: any) => Promise<void>;

async function firstName(userId: string): Promise<string> {
  const { data, error } = await admin.from("profiles").select("name").eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  return data?.name || "Someone";
}

type Setting = "notify_matches" | "notify_likes" | "notify_messages";

/** The person's own notification setting (You › Notifications in the app). On when unknown. */
async function wants(userId: string, setting: Setting): Promise<boolean> {
  const { data, error } = await admin.from("profiles").select(setting).eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile ${userId}: ${error.message}`);
  return (data as Record<Setting, boolean> | null)?.[setting] ?? true;
}

const handlers: Record<string, Handler> = {
  // Push for a like, unless it made a match (match.created pushes instead). No name: the Likes tab
  // is where people see who it was.
  async "like.received"(p: { from: string; to: string; superLike: boolean }) {
    const [a, b] = [p.from, p.to].sort();
    const { data: match, error } = await admin.from("matches").select("id").eq("user_a", a).eq("user_b", b)
      .maybeSingle();
    if (error) throw new Error(`match lookup: ${error.message}`);
    if (match || !(await wants(p.to, "notify_likes"))) return;
    await pushToUser(p.to, {
      title: p.superLike ? "New super like" : "New like",
      body: p.superLike ? "Someone super liked you. See who." : "Someone likes you. See who.",
      data: { tab: "likes" },
      collapseId: "likes",
    });
  },

  // Chat channel, then the openers each person attached to their like, then a push to both.
  async "match.created"(p: { matchId: string; userA: string; userB: string }) {
    const { channel } = await ensureChannel(p.matchId);
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
    const [nameA, nameB, wantsA, wantsB] = await Promise.all([
      firstName(p.userA),
      firstName(p.userB),
      wants(p.userA, "notify_matches"),
      wants(p.userB, "notify_matches"),
    ]);
    await Promise.all([
      wantsA && pushToUser(p.userA, {
        title: "It's a match",
        body: `You and ${nameB} want to train together.`,
        data: { match: p.matchId },
      }),
      wantsB && pushToUser(p.userB, {
        title: "It's a match",
        body: `You and ${nameA} want to train together.`,
        data: { match: p.matchId },
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
      if (verdict === "rejected") {
        // The app shows its own banner when it's open (and hides this push there).
        await pushToUser(p.userId, {
          title: "drafft",
          body: "One of your photos wasn't approved. Tap to see why.",
          data: { kind: "photo_refused", media: p.mediaId },
          collapseId: `photo-${p.mediaId}`,
        });
      }
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

  // Paused or resumed: chats become read-only, or writable again. The current state decides, not the
  // payload, so a pause and a resume arriving out of order still end right.
  async "profile.paused"(p: { userId: string }) {
    const { data, error } = await admin.from("profiles").select("paused").eq("id", p.userId).maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    // Deleted since: the account and its chats are gone.
    if (!data) return;
    await setChatPaused(p.userId, data.paused);
  },

  // drafft tempo's free boost of the week was credited (private.credit_weekly_boosts). Tapping it
  // opens Discover, where the boost is used.
  async "boost.weekly"(p: { userId: string }) {
    const { data, error } = await admin.from("profiles").select("language, notify_weekly_boost").eq("id", p.userId)
      .maybeSingle();
    if (error) throw new Error(`profile ${p.userId}: ${error.message}`);
    if (!data?.notify_weekly_boost) return;
    await pushToUser(p.userId, {
      title: "drafft",
      body: weeklyBoost[language(data.language)],
      data: { kind: "weekly_boost" },
      collapseId: "weekly-boost",
    });
  },
};

async function setStatus(mediaId: string, status: "approved" | "rejected") {
  check(await admin.from("profile_media").update({ status }).eq("id", mediaId), "media status");
}

// The session lives in Postgres; the chat gets a custom message pointing to it, from whoever acted.
async function sessionEvent(
  p: { sessionId: string; matchId: string; proposerId: string; actorId: string },
  status: "proposed" | "accepted" | "declined" | "cancelled",
) {
  const actor = status === "proposed" ? p.proposerId : p.actorId;
  const { channel, members } = await ensureChannel(p.matchId);
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
  // Session updates are chat activity: they follow the Messages setting, like in the app.
  if (!other || !(await wants(other, "notify_messages"))) return;
  const name = await firstName(actor);
  const what = session.title || `${session.sport_id} session`;
  const body = {
    proposed: `${name} proposed: ${what}`,
    accepted: `${name} accepted: ${what}`,
    declined: `${name} can't make it: ${what}`,
    cancelled: `${name} cancelled: ${what}`,
  }[status];
  await pushToUser(other, { title: "Session", body, data: { match: p.matchId, session: p.sessionId } });
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
