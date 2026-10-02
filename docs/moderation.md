# Moderation and staff access

Moderation and support run in [drafft-sophros](https://github.com/sylwaninn/drafft-sophros), its own repository:
one Cloudflare Worker per environment behind Cloudflare Access. It reaches the database with the secret key, only
through the `admin_*` functions (`20260927000007_sophros.sql`, service role only). Each call names the staff
member; the database checks their role in `private.staff` (`support`, `moderator`, `admin`) and writes
`private.admin_audit`, which can't be edited or deleted. Staff are per database:

```sql
insert into private.staff (email, role) values ('someone@getdrafft.com', 'admin');
```

Locally, `supabase db reset` seeds `dev@drafft.local` (admin), the identity sophros uses in dev mode.

## Statements of reasons (DSA art. 17)

When a person on the team refuses a photo, removes a message, puts an account on hold or bans it, the member is
told what was decided and why (migration `20260930000401`): the decision is stored in
`private.moderation_decisions` (kept like the moderation log: 1 year, 3 about a banned account, even once it is
erased) and db-events (`moderation.decision`) emails it in their language: the reason, the section of the terms of
use it falls under with a link to it (`https://getdrafft.com/<lang>/terms#community`, `#eligibility`,
`#moderation`, or the terms as a whole for `other`), the team's note if any, and how to contest it (the in-app help
center, or a reply, reviewed by someone else). It is pushed when no other push says it (a removed message, a
review, a ban; a refused photo and a selfie request have their own); without an email address on the account the
push doesn't point to one, and the missing email is logged. A photo refused by a person gets this statement as its
only email. A removed message is told once Stream shows it removed (a 404 or code 16 counts as removed). Automatic
decisions (the photo check, holds from a device or a link to a banned account) keep their own messages. The
statements are part of the member's data export.

What sophros sends with each decision:

| RPC (service role) | New parameters | Statement sent |
| --- | --- | --- |
| `admin_set_hold(p_actor, p_user, p_state, p_reason, p_category, p_details)` | reason category, note for the member | a hold put or changed: `account_review`, `account_selfie`, `account_banned`; a selfie asked again with a category (the state stays `selfie`): `account_selfie`, pushed as a selfie request; none when lifted, or unchanged otherwise |
| `admin_review_media(p_actor, p_media, p_approved, p_reason, p_category, p_details)` | same | `photo_refused`, when a photo becomes refused |
| `admin_decide_photo(p_actor, p_media, p_reason, p_hold, p_hold_reason, p_category, p_details)` | same, for the photo and the hold | `photo_refused` for a pending photo, plus the hold's |
| `admin_close_report(p_actor, p_report, p_resolution, p_hold, p_category, p_details)` | same, for the hold | the hold's |
| `admin_decide_flags(p_actor, p_ids, p_reason, p_hold, p_hold_reason, p_category, p_details)` | same, for the hold | the hold's |
| `admin_log(p_actor, 'message.delete', p_user, '<match>/<message>', p_reason, p_override, p_category, p_details, p_override_basis)` | same; `p_user` is the author, one of the two members | `message_deleted` |

`p_reason` stays the team's internal reason (audit log, moderation log); `p_details` is written for the member
and sent as written. Both are checked once, before anything applies: `p_category` must be one of
`admin_reason_categories(p_actor)` → `[{ id, termsAnchor }]` (`harassment`, `hate`, `sexual_content`,
`violence_illegal`, `underage`, `impersonation`, `scam_commercial`, `privacy`, `fake_account`, `evasion`,
`photo_guidelines`, `identity_check`, `other`), else `invalid_category`; a decision that sends a statement needs
one (`category_required`); a note over 1,000 characters fails with `details_too_long` (never cut). The audit log
records the category. A removal needs `<match id>/<message id>` and its author among the two members
(`invalid_target`).

## Reading conversations and selfies

`admin_log(p_actor, 'conversation.view', p_user, p_match, p_reason, p_override, …, p_override_basis)` is the gate
sophros calls before reading a conversation from Stream (and `'message.delete'` before removing a message). It needs
a reason written by the person (`reason_required` when empty) and a basis,
from `admin_conversation_access(p_actor, p_match)` → `{ basis: ('report' | 'support' | 'hold')[], canOverride }`
(`not_found` for an unknown match): `report` (a report between the two members), `support` (a help request from
either, open or from the last 90 days), `hold` (either account on hold or banned, unless the reader put that hold
themself). Without one it fails with `no_basis`; an admin may still read it with `p_override = true` and
`p_override_basis` (`legal_request` or `member_safety`, else `override_basis_required`), for a legal request or
members' safety only; the audit log records the override and why. The audit log records the basis.
`admin_selfies(p_actor, p_user, p_reason)` needs a reason too (`reason_required`).
