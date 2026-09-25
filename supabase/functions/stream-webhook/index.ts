// POST /stream-webhook, called by Stream Chat for the events set in the app's webhook settings
// (scripts/stream-webhook.ts): reaction.new and reaction.updated. Signed with the Stream API secret
// (X-Signature). Message pushes stay Stream's own; reactions are pushed from here, in the person's
// language and under their settings, WhatsApp-style: "Maya reacted ❤️ to: “See you at 7?”".
import { pushToUser } from "../_shared/apns.ts";
import { HttpError, json, serve } from "../_shared/http.ts";
import { stream } from "../_shared/stream.ts";
import { admin } from "../_shared/supabase.ts";
import { language, reaction } from "../_shared/texts.ts";

interface ReactionEvent {
  type: string;
  channel_id?: string;
  message?: { id: string; text?: string; user?: { id: string } };
  reaction?: { type: string; user_id: string };
  user?: { id: string; name?: string };
}

serve(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
  const body = await req.text();
  if (!stream().verifyWebhook(body, req.headers.get("x-signature") ?? "")) {
    throw new HttpError(401, "unauthorized");
  }
  const event = JSON.parse(body) as ReactionEvent;
  if (event.type !== "reaction.new" && event.type !== "reaction.updated") return json({ ok: true });

  const { message, reaction: r, channel_id: matchId } = event;
  const author = message?.user?.id;
  if (!message || !r || !matchId || !author) return json({ ok: true });

  // Nobody reacts to their own message: the app doesn't offer it, and one sent anyway is removed.
  if (r.user_id === author) {
    await stream().channel("messaging", matchId).deleteReaction(message.id, r.type, r.user_id);
    return json({ ok: true, removed: true });
  }

  const [{ data: to, error }, { data: from }] = await Promise.all([
    admin.from("profiles")
      .select("language, notify_messages, notify_message_previews, notify_reactions")
      .eq("id", author).maybeSingle(),
    admin.from("profiles").select("name").eq("id", r.user_id).maybeSingle(),
  ]);
  // A failure answers 500: Stream retries.
  if (error) throw new Error(`profile ${author}: ${error.message}`);
  if (!to || !to.notify_messages || !to.notify_reactions) return json({ ok: true });

  // The app sends the emoji itself as the reaction type.
  await pushToUser(author, {
    title: "drafft",
    body: reaction(language(to.language), from?.name || event.user?.name || "Someone", r.type,
      to.notify_message_previews ? message.text : undefined),
    data: { match: matchId },
    collapseId: `reaction-${message.id}`,
  });
  return json({ ok: true });
});
