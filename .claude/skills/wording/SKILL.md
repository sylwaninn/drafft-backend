---
name: wording
description: |
  drafft's editorial rules for any text people read. Use it BEFORE writing, editing, reviewing or
  translating user-facing copy in any repository: UI strings (Localizable.xcstrings, Android i18n
  variants), microcopy, buttons/CTAs, onboarding, empty states, errors, alerts, push notifications,
  emails, SMS, support replies, moderation notices, paywall, App Store / Play Store listings,
  website copy (i18n.js), screenshots and mockups, social posts, taglines, in any of the 7 languages.
  Triggers: wording, copy, copywriting, microcopy, UX writing, texte, libellé, traduction,
  translation, tagline, slogan, CTA, notification, email, paywall, store listing, landing page.
---

# drafft wording

`WORDING.md` at the root of this repository is the rule book (shared with drafft-ios, the reference: AGENTS.md "Shared docs").
This skill enforces it; it restates no rule.

1. **Read `WORDING.md` in full** before writing a word: it changes, and section 11 logs the latest
   decisions.
2. **Write** with its positioning (§1), personality and tone for the context (§2–3), lexicon (§4)
   and form rules (§6). Every language you touch gets all 7 (en fr es de it pt nl), adapted, not
   literal.
3. **Check the forbidden list (§5)** on every string, in every language. Above all: never the word
   "plan" (any sense, any language) and never a match presented as turning into / ending in /
   leading to something.
4. **Run the review checklist (§10)** and fix anything that fails. Then run `cd supabase/functions && deno test --allow-env --allow-read=.,../../WORDING.md`.
5. **Report** which WORDING.md sections you applied and any rule you had to bend (with the reason),
   so the human can decide.

## Where text lives


- **App strings**: `drafft-ios/Drafft/Resources/Localizable.xcstrings`. Android never adds a key of
  its own: write it in the iPhone catalog, then `python3 scripts/sync-strings.py` in drafft-android.
  The one text written in drafft-android: the Android wording of the iPhone's platform sentences
  (App Store, Apple Account, iPhone Settings) in `core/model/src/main/resources/i18n/android/<lang>.json`.
- **Pushes, emails, SMS**: drafft-backend (`supabase/functions/`), and the apps' `NotificationText`.
- **Website**: drafft-web `public/i18n.js` and `public/index.html`.
- **Store listings and screenshots**: `docs/wording/store.md` in drafft-ios.

## Changing the rules

A new editorial decision (new term, banned phrase, validated tagline) goes into `WORDING.md` (§11 and
the relevant section). Then ask the user whether it goes to the other repositories' copies, and if yes,
open one pull request per repository with the identical change (AGENTS.md, "Shared docs"). Never copy
rules into other files.
