---
name: wording
description: |
  drafft's editorial rules for any text people read. Use it BEFORE writing, editing, reviewing or
  translating user-facing copy: UI strings, microcopy, buttons/CTAs, onboarding, empty states,
  errors, alerts, push notifications, emails, SMS, paywall, App Store / Play Store listings,
  website/landing copy, screenshots and mockups (profiles, bios, chat messages), social posts,
  taglines, marketing content, Localizable.xcstrings or i18n.js changes, in any of the 7 languages.
  Triggers: wording, copy, copywriting, microcopy, UX writing, texte, libellé, traduction,
  translation, tagline, slogan, CTA, notification, email, paywall, store listing, landing page.
---

# drafft wording

`WORDING.md` at the repository root is the only source of truth. This skill enforces it; it
restates no rule.

1. **Read `WORDING.md` in full** before writing a word (it's short). Don't rely on memory: it
   changes, and section 11 logs the latest decisions.
2. **Write** with its positioning (§1), personality and tone for the context (§2–3), lexicon (§4)
   and form rules (§6). Every language you touch gets all 7 (en fr es de it pt nl), adapted, not
   literal.
3. **Check the forbidden list (§5)** on every string, in every language. Above all: never the word
   "plan" (any sense, any language) and never a match presented as turning into / ending in /
   leading to something.
4. **Run the review checklist (§10)** and fix anything that fails. Then run the repository's
   automated check:
   - drafft: `python3 scripts/ci/i18n_lint.py`
   - drafft-backend: `cd supabase/functions && deno test --allow-env --allow-read=.,../../WORDING.md`
   - drafft-web: the "Check wording" step of `.github/workflows/ci.yml`
5. **Report** in your answer which WORDING.md sections you applied and any rule you had to bend
   (with the reason), so the human can decide.

A new editorial decision (new term, new banned phrase, validated tagline) goes into `WORDING.md`
§11 and the relevant section, in `drafft` only, then `scripts/sync-wording.sh` copies it to
drafft-backend and drafft-web. Never copy rules into other files.
