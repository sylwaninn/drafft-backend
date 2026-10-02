# Support

Support replies are written in sophros (`admin_reply_support`) and emailed by db-events (`support.reply`),
framed in the person's language, with Reply-To the support address (`SUPPORT_ADDRESS`, SUPPORT_INBOX while it is
unset), like every email to a member about their account (notices, statements of reasons, exports): a reply comes
back to the team. The mailer never sends to reserved domains (`.test`, `.example`, `.invalid`, `.localhost`), which
the demo and test accounts use.

## Support by email

Every support email a member gets, the acknowledgement (`support.created`) and the team's replies
(`support.reply`), has the request's reference at the end of its subject (`We got your message [DR-ABC234]`,
`Re: Help [DR-ABC234]`). Every email to a member about their account has Reply-To `SUPPORT_ADDRESS`
(support@getdrafft.com; while it is unset, SUPPORT_INBOX). The team's copies still go to SUPPORT_INBOX. What comes
back, or anything else written to that address, lands in sophros (migration `20260930000501`):

1. Cloudflare Email Routing hands the email to the Email Worker `cloudflare/support-mail-worker`. It parses it
   (postal-mime), keeps what the person wrote this time (quoted history, `>` lines and signature cut off; an
   HTML-only email, or an empty text part next to HTML, as text), the attachments' names only, and the reference
   (`DR-XXXXXX` in the subject, else in the quoted text, HTML quotes included). The sender is the envelope's (SMTP
   MAIL FROM), never the From header. It is **verified** only when Cloudflare's own Authentication-Results (the
   first such header, authserv-id `mx.cloudflare.net`) say SPF passed for the envelope's domain, or DKIM passed
   for a domain aligned with it.
2. It posts that to `support-inbound` with the header `x-support-inbound-secret` (`SUPPORT_INBOUND_SECRET`, the
   same in the Worker and the function). Both sides parse the payload and the answer with
   `supabase/functions/_shared/support_inbound.ts` (a wrong type is a 400, never coerced), and the function keeps
   the request's context within its 2000 bytes. `receive_support_email`:
   - verified, a known reference, from the address its request was written from (or its account's current
     email): the message joins the request as the member's (`support_messages.direction = 'in'`, at most 8000
     characters), the request reopens, and db-events emails the team a copy (`support.received`, to SUPPORT_INBOX);
   - verified, anything else: a new request from the sender, linked to the account with that email if any (its
     language, else English), acknowledged, the team copied;
   - not verified: always a new request, linked to no account, never acknowledged (no mail to an address that may
     not have written); the team copy says so. A reference it mentioned is kept in its context for the team.
     Another address never joins someone else's thread.
   - the topic is the cleaned subject (no `Re:`, no reference), else "Message by email" in the account's
     language; each email once (by Message-ID, `private.support_inbound`); 10 messages an hour into one request,
     5 new requests an hour per address and 200 in all (their own limits, apart from the app's signed-out
     form); posts over 256 KB refused.
3. Nothing is lost: when the function doesn't take the email (unreachable, 4xx, 5xx, an answer that isn't a
   result), or it isn't a person writing (an auto-reply, a bounce, a mailing list: never filed, so an
   out-of-office can't open request after request), the Worker forwards the whole email to `FALLBACK_ADDRESS`
   (the team's mailbox) with an `X-Drafft-Support` header saying why. Filed but not whole (attachments, a text
   cut to size, lines of their own cut with the quoted history, since "he wrote:" reads like an attribution):
   filed, and forwarded as well. If even that forward fails, the Worker throws and Email Routing refuses the
   email, so the sender's server reports it.

`admin_support` returns each message's `direction`: sophros marks the member's messages that came by email
("By email").

A team reply is never left "Sending" (`sent_at` and `error` both null): whatever stops db-events from sending it,
reading it included, is recorded on the message (`error`) and retried, and a reply the outbox gives up on (out of
budget, or discarded) is marked failed when nothing was recorded (`private.support_reply_given_up`). A replay
that sends it clears the error.

### Setting it up

Done once per environment (production: support@getdrafft.com; staging: support-staging@getdrafft.com); kept to
rebuild it.

1. Function secrets, in both projects (the drift check wants the same names): `SUPPORT_INBOUND_SECRET`
   (`openssl rand -hex 32`, one per environment). Keep `SUPPORT_ADDRESS` unset until the route works (step 7):
   replies go to SUPPORT_INBOX meanwhile.
2. CI deploys `support-inbound` with the backend.
3. Cloudflare, zone `getdrafft.com` › Email › Email Routing: enable it. It adds its MX records
   (`route1/2/3.mx.cloudflare.net`), a DKIM record and an SPF TXT record
   (`v=spf1 include:_spf.mx.cloudflare.net ~all`); one SPF record per name, so it replaces any other on the
   apex. `mail.getdrafft.com` (Resend's sending subdomain, MX to Amazon SES) is separate and not affected.
4. Destination addresses: add the team's mailbox (SUPPORT_INBOX) and confirm the email Cloudflare sends it
   (a Worker can only forward to a verified address).
5. The Worker, from `cloudflare/support-mail-worker`: `npm ci`, then per environment
   `npx wrangler@4 secret put SUPPORT_INBOUND_SECRET --env <env>` (the function's value) and
   `npx wrangler@4 secret put FALLBACK_ADDRESS --env <env>` (the verified mailbox), then
   `npx wrangler@4 deploy --env <env>`.
6. Email Routing › Routing rules: a custom address `support@getdrafft.com` (and `support-staging@`), action "Send
   to a Worker", `drafft-support-mail` (and `drafft-support-mail-staging`). Leave the catch-all off.
7. Try it on staging: send an email to support-staging@getdrafft.com from the address of a staging request,
   with its `[DR-XXXXXX]` in the subject (Reply-To is still SUPPORT_INBOX at this point, so a plain reply would
   go there): the message shows in sophros and the request reopens. Then set `SUPPORT_ADDRESS`
   (`support-staging@getdrafft.com` on staging, `support@getdrafft.com` in production) in both projects: from
   then on, replies come back through this route.
