<!-- Shared copy of drafft-ios/WORDING.md, kept identical in every repository that has it. Changing it? Ask whether the other copies follow (AGENTS.md, Shared docs). -->

# WORDING.md

The single source of truth for every word people read from drafft: app UI, onboarding, CTAs, empty
states, errors, push, email, SMS, paywall, App Store / Play Store, website, screenshots, social.

- **Read it before writing or changing any user-facing text, in any of the 7 languages. Apply it.
  Run the [review checklist](#10-review-checklist) before you finish.**
- Canonical file: `drafft-ios/WORDING.md`. `drafft-backend/WORDING.md`, `drafft-web/WORDING.md` and
  `drafft-android/WORDING.md` are synced copies: edit only this one, then run `scripts/sync-docs.sh`
  in the drafft workspace.
- Every new editorial decision goes here (section 11). Other files point here, never restate rules.
- Machine-checked: the forbidden patterns in section 5 fail CI (`scripts/ci/i18n_lint.py` here, a
  test in drafft-backend, a CI step in drafft-web).

## 1. Positioning

- **Who:** the audience is described in PRODUCT.md only, never in copy, a README or another doc.
- **What drafft does:** profiles lead with how someone trains (sports, how often). When two
  people like each other, drafft makes it easy to **propose a session**: sport, day, time. The
  first date can happen on the track, the wall or the court.
- **Promise (one sentence):**
  - EN: "Singles who love sport as much as you do, and one more session in your week."
  - FR: « Des célibataires qui aiment le sport autant que toi, et une séance de plus dans la semaine. »
  - The full message system (line, promise, invitation, confirmation) is in section 7.
- **A match promises nothing.** It's mutual interest. drafft *invites* people to take it further,
  it never states that a match becomes or leads to anything.
- **Against the category:**
  - bpm.so owns "the first date is a workout" and sweat ("Swipe less. Sweat more.").
  - Breeze plans dates for you.
  - drafft owns **the start**: the proposal you make, the start line, the moment you both show up.

## 2. Personality

| Trait | We are | We are not |
|---|---|---|
| Direct | We say the next step: sport, day, time | Pushy, bossy, hurried |
| Friendly | Light club humour, the wink after a session | Heavy jokes, double meanings, sarcasm |
| Respectful | Every level, every pace, safety first | Elitist, body-focused, performance cult |
| Precise | Concrete details show we mean it | Technical, cold, jargon |
| Upbeat | Optimistic, looking at the start | A shouting fitness coach, hype |

## 3. Tone by context

| Context | Do | Example (EN / FR) |
|---|---|---|
| Onboarding | One idea per screen, say why we ask, reassure | "Your sports come first. Photos next." / « Tes sports d'abord. Les photos ensuite. » |
| Error | Say what happened, never blame, one way out | "It didn't send. Check your connection and try again." / « Envoi impossible. Vérifie ta connexion et réessaie. » |
| Celebration | Calm, full stop, then the next step | "It's mutual. Propose a session while it's fresh." / « C'est réciproque. Propose une séance tant que c'est frais. » |
| Nudge / reminder | Useful fact or open invitation, no guilt | "Léa proposed 2 times. Pick one." / « Léa a proposé 2 créneaux. Choisis-en un. » |
| Paywall | Concrete benefit, honest price, easy exit | "See who likes you and match in one tap." / « Vois qui te like et matche en un geste. » |
| Safety / moderation | Plain, calm, firm, no irony | "You can leave a session anytime, no reason needed." / « Tu peux quitter une séance à tout moment, sans te justifier. » |
| Goodbye / delete | Respectful, no guilt trip | "Your account is deleted. Thanks for the sessions." / « Ton compte est supprimé. Merci pour ces séances. » |

## 4. Lexicon

### Brand terms (always)

| Concept | EN | FR | Notes |
|---|---|---|---|
| Product | drafft | drafft | Always lowercase, even at sentence start. Never "Drafft", "DRAFFT" |
| Paid tier | drafft tempo | drafft tempo | Never Plus, Premium, Pro, VIP, club, "+" |
| A training date | session | séance | The login session is "login" / « connexion » |
| Send one | propose (a session) | proposer (une séance) | The only verb. Not suggest, offer, invite, pitch |
| The sent card | session invite | proposition de séance | |
| Time options | times | créneaux | "Pick a time", "Other times" (button), "Propose other times" (title) / « Autres créneaux », « Proposer d'autres créneaux » |
| The short note on an invite | note | petit mot | Not "pitch" |
| Mutual like | match; screen title "It's mutual." | match ; titre « C'est réciproque. » | Never "It's a match." |
| First date | first date | premier rendez-vous | FR avoids « un date » (bpm's word) |
| Start line | start line (two words) | départ, ligne de départ | "startline" in one word only as a campaign hashtag |
| Level | level | niveau | The app has **no level field**: never promise matching or filtering by level. Say "every level welcome", level only in people's own words |
| How often | "3× a week" | « 3× par semaine » | |
| Pace (speed) / rhythm (life) | pace / rhythm | allure / rythme | |
| Likes, super like, boost | like, super like, boost | like, super like, boost | Lowercase in copy. Pack names in the stores keep their capitals, as in App Store Connect: "1 Boost", "5 Boosts", "3 Super Likes" (each language keeps its own spelling: ES "Superlikes", IT "Boost" and "Super Like", NL "Superlikes") |

### Core terms in all 7 languages

| Concept | en | fr | es | de | it | pt | nl |
|---|---|---|---|---|---|---|---|
| Session | session | séance | sesión | Session | sessione | sessão | sessie |
| Propose | propose | proposer | proponer | vorschlagen | proporre | propor | voorstellen |
| Sent card | session invite | proposition de séance | propuesta | Vorschlag | proposta | proposta | voorstel |
| Times | times | créneaux | horarios | Zeiten | orari | horários | tijden |
| Note | note | petit mot | nota | Notiz | nota | nota | berichtje |
| Match title | It's mutual. | C'est réciproque. | Es mutuo. | Ihr mögt euch beide. | È reciproco. | É recíproco. | Het is wederzijds. |
| Login | login | connexion | acceso | Anmeldung | accesso | acesso | inloggen |
| Tier | drafft tempo | drafft tempo | drafft tempo | drafft tempo | drafft tempo | drafft tempo | drafft tempo |

### Preferred words

- EN: propose, start, show up, meet, together, pace, your week, your sports, session.
- FR: proposer, se retrouver, prendre le départ, élan, rendez-vous, séance, créneau, allure.
- After a session, suggest coffee, a smoothie, brunch, a swim in the lake. Never alcohol or dinner
  as the goal.

## 5. Forbidden

### 5.1 "plan" is banned, in every sense, in all 7 languages

Never say or suggest that a match "turns into a plan", "ends in a plan", "leads to a plan". In French
« plan » reads as « plan cul » / « plan d'un soir ». The word goes everywhere, even when it's innocent
(subscriptions, training plans), so the rule stays simple and machine-checkable.

| Banned | Use instead |
|---|---|
| EN plan, plans, planned, planning ("plan a session") | propose a session, set a time, "session set" |
| EN subscription "plan" | option, length ("Pick an option to continue.") |
| FR plan, planifier, « finit en plan », « bon plan » | proposer une séance, caler un créneau, formule (abonnement) |
| FR « plan d'entraînement » | « programme », « routine » |
| ES plan, planear, quedar en plan | proponer una sesión, quedar |
| DE Plan, planen, geplant | vorschlagen, ausmachen, Abo-Option |
| IT piano (plan), pianificare, programmare un appuntamento | proporre una sessione, organizzarsi |
| PT plano (plan), planear | propor uma sessão, combinar |
| NL plan, plannen, gepland | voorstellen, afspreken |

A match may be *invited* to become a session: "Turn your matches into sessions." is allowed (session
is not a plan, and it's an invitation, not a promise). Never with a date, a night or anything else.

### 5.2 Hookup / sexual / ambiguous

hookup, one-night, fling, "casual", « d'un soir », « plan cul », « coup d'un soir », « se croquer »,
chaud / hot, sexy, "get physical", "sweat together" / « transpirer ensemble », endurance or stamina
in a romantic sense, positions, "body count", partner in a dating sense (FR « partenaire »: use
« binôme » for training), Netflix. No double meaning, ever.

**Desire and attraction words.** In a dating app, a word that is innocent elsewhere reads as desire
for the person. Copy talks about the thing (the photo, the answer, the sport, the time), never about
what the person makes someone feel. Same family as « plan » (5.1).

| Banned when it points at a person or their profile | Use instead |
|---|---|
| FR « envie » (« ce qui t'a donné envie », « envie de toi »), « craquer » / « faire craquer », « plaire » / « ce qui t'a plu », « attirer », « désir », « tenter », « séduire », « conquérir » | « petit mot », « réagir », « convaincre », « retenir l'attention » |
| EN "turn on", "into you", "tempt", "desire", "seduce", "make me fall", "caught your eye", "win me over" | note, react, convince, "stood out" |
| ES conquistar, seducir, "te pone" | convencer |
| DE rumkriegen, verführen, anmachen | überzeugen |
| IT conquistare, sedurre | convincere |
| PT conquistar, seduzir | convencer |
| NL versieren, verleiden | overtuigen |

« envie » stays fine when it's about the thing, not the person: « Pas envie d'attendre ? ».

### 5.3 Category clichés and competitor territory

"It's a match", "find your perfect match", "the one", soulmate / swolemate, gym crush, swipe right,
"find your person / people", sparks, "small talk" / "skip the small talk", "swipe less, X more" and
any "X less, Y more", "100% sportifs", "people who actually train", sweat and « sueur » (bpm), "It
all starts with…" (Tinder ™), "designed to be deleted" (Hinge), "No chat, just dates" (Breeze).

### 5.4 Never invent a value

No invented number, percentage, count, rating, score, ranking or statistic, anywhere: UI, push, email,
store, website, screenshots. That includes placeholders computed in code ("62% agree", "12 people
nearby", "4.8 stars") and demo values left in shipped copy. Every value shown comes from real data;
when there is none, show no value (a label without a figure, or nothing). No demo or placeholder text
in anything people can see ("Demo text…", "Lorem ipsum", "TBD").

### 5.5 Pressure, judgement, filler

- Fake urgency and guilt: "Don't miss out", "Last chance", "Hurry", "X people are waiting",
  "You haven't…", invented user counts, rates or press (5.4).
- Body or performance judgement: fit, in shape, beach body, "no couch potatoes", "real athletes".
- Robotic filler: "Oops", "Uh-oh", "Success!", "An error occurred", "Invalid input", "Something went
  wrong" with no way out, "Click here", bare "Are you sure?".
- Masculine default in gendered languages (FR « Content de te revoir » → « Te revoilà. »).

### 5.6 Machine-checked patterns

Case-insensitive regexes, one per line, `pattern | reason`. The lints read this block from their
repository's copy of this file: keep the format.

```wording-forbidden
\bplan(s|ned|ning|ner|ners)?\b | "plan" is banned (5.1)
\bplanifi\w* | "plan" is banned (5.1)
\bplane(ar|ado|ada|amos)\b | "plan" is banned (5.1)
\bplanos?\b | "plan" is banned (5.1)
\b(ge)?plan(t|en|nen|nt|de)\b | "plan" is banned (5.1)
\bgepland\b | "plan" is banned (5.1)
\bpianific\w* | "plan" is banned (5.1)
\bhook ?-?ups?\b | hookup wording (5.2)
\bone[- ]night\b | hookup wording (5.2)
\bd'un soir\b | hookup wording (5.2)
\bit[’']s a match\b | category cliché (5.3)
\bc[’']est un match\b | category cliché (5.3)
\bperfect match\b | category cliché (5.3)
\bsw[oa]l?e ?mates?\b | category cliché (5.3)
\bsoul ?mates?\b | category cliché (5.3)
\bswipe right\b | category cliché (5.3)
\bgym crush\b | category cliché (5.3)
\bsmall talk\b | category cliché (5.3)
\bsweat\w* | bpm territory (5.3)
\bsueur\b | bpm territory (5.3)
\bdonn\w* envie\b | desire wording (5.2)
\bfaire craquer\b | desire wording (5.2)
\brumzukriegen\b | desire wording (5.2)
\bwin (me|you|them) over\b | desire wording (5.2)
\boops\b | robotic filler (5.5)
\bdon[’']t miss out\b | fake urgency (5.5)
```

## 6. Form rules

- **Address:** the informal "you" in every language: EN you, FR tu, ES tú (vosotros for two people,
  Spain), DE du, IT tu, PT tu (European), NL je/jij. "You two": FR vous, ES vosotros, DE ihr.
- **Case:** sentence case everywhere (titles, buttons, store names). drafft always lowercase. The one exception: the pack names in the stores (section 4).
- **CTAs:** a verb first, 1–3 words, 20 characters max in EN. Say what happens ("Propose a session",
  "Pick this time"), not "OK", "Continue" or "Submit" when a precise verb exists. Keep names out of
  one-line buttons ("Say hi", not "Say hi to Maximilien").
- **Buttons stay on one line, in every language.** Check the longest translation (FR, DE, NL run
  30–40 % longer than EN), not the EN. Rough budget per line (17 pt semibold, 375 pt iPhone):
  full-width button ≈ 28 characters (≈ 25 with an icon); button inside a card, such as the session
  card in a chat, ≈ 18; two buttons side by side ≈ 12. Over budget, adapt the wording in that language
  (drop "above", a possessive, a second verb) and keep the meaning; a short noun phrase is fine when
  the icon and context carry the verb ("Other times" / « Autres créneaux »). When a label holds a
  value (a day, a count), the code drops that detail to stay on one line (`ViewThatFits`), never "…".
- **Titles and headlines:** short statements ending with a full stop ("You've seen everyone nearby.").
- **Body:** one idea per sentence, 2 sentences max on a screen block, contractions in EN.
- **Punctuation:**
  - No exclamation marks in UI, push or email. Allowed in people's own voice (icebreakers,
    screenshot messages).
  - No "·" separator (lint). No "…" on UI copy, except progress states ("Sending…") and excerpts
    of people's content.
  - A colon joins two clauses at most once per string. No em dash in UI copy.
  - FR: non-breaking space (U+00A0) before `: ; ! ?` and inside « ». Other languages follow their
    own typography (DE „…“, ES ¿…?).
- **Emoji:** none in UI, push, email, store titles. At most one per message in screenshot chats or
  user-voice prompts.
- **Numbers:** digits ("3× a week", "2 km", "7:00"). Dates and times come from the locale
  formatter, never hand-built.
- **Gender:** neutral wording in gendered languages. Never the FR middle-dot form (« sportif·ve »,
  banned by the design lint), never a masculine default. Rephrase: « Te revoilà. », « les personnes
  qui s'entraînent ».
- **Translation:** adapt, don't translate word for word. Same register, same length class (a short
  EN string stays short), same placeholders. Sport names follow the app's sport list. Write as a senior
  copywriter, not a literal translator: informal address but never slangy or over-familiar (FR: no
  « boulot », « bouffe », « matos », « direct »), no calques, distinct labels for distinct things
  (the Discover tab is not a discovery session).
- **Push:** the title is the person's name or the event; the body is one sentence with the useful
  fact (sport, day, time). No emoji, no "!".
- **Email:** subject ≤ 45 characters, says the one thing; first line repeats it; one CTA.
- **Store:** follow Apple/Google limits (section 7.4).

## 7. Taglines and the start line territory

### 7.1 The territory: the start line

Start, start line, the signal, the first stride, the shared momentum of two people who show up at the
same time. It's about *intention* (you proposed, you came), not performance, not sweat. It is the
brand's image, used sparingly (7.2): the Invitation carries it, the other formulas talk about rhythm.

- Words: start line, start, go, show up, first stride, same pace, set a time.
- FR: départ, ligne de départ, élan, top départ, prendre le départ, se retrouver, à vos marques.
- Never: finish line, winning, podium, race against each other, "beat", PB as a dating goal.

### 7.2 The message system: four formulas, one role each

Every surface (website, app welcome, stores, emails, ads) draws from these four and from nothing
else. A new tagline is a decision-log entry, not a new string.

| Role | EN | FR | Where |
|---|---|---|---|
| **Line** (what it is) | Meet someone who gets your rhythm. | Rencontre quelqu'un qui comprend ton rythme. | Website hero, app welcome, store description opening, social bio, Play feature graphic, `og:title`, footer |
| **Promise** (what you get) | Singles who love sport as much as you do, and one more session in your week. | Des célibataires qui aiment le sport autant que toi, et une séance de plus dans la semaine. | Website hero (right column), meta description, "how it works" blocks |
| **Invitation** (call to action) | You already speak the same language. See you at the start line? | Vous parlez déjà la même langue. On se retrouve sur la ligne de départ ? | Website closing call to action, ads, social. The only place where the start line is the formula |
| **Confirmation** (a session is set) | Session confirmed. Tuesday at 7:00. | Séance confirmée. Mardi à 7 h. | Session screen, push, email. Facts, not a slogan; the day and time come from the locale formatter |

Rules:

- **One role per place.** The Line names what drafft is, the Promise says what you get, the
  Invitation closes. Don't stack two roles in one block, don't paraphrase them.
- **Rhythm** is the Line's word: how often someone trains and how their week runs (section 4). It
  stays out of the Promise. Never "tempo" in these lines: it is the paid tier's name.
- **The start line is spent sparingly**: it is the Invitation's image and the campaign hashtag, not a
  refrain. No "start line" in titles, meta tags, welcome screens or session confirmations. Never
  "Meet me on the start line" or "Rendez-vous au départ" as a brand line (retired).
- **Descriptor**: "dating app" / « app de rencontre » (never « appli », never "sports dating app",
  except the App Store name, 7.4).
- **No promise on a match.** The Promise offers a session (it adds one to your week), it never says a
  match becomes or leads to something.

Each formula in all 7 languages (gender-neutral where the language marks it):

| | Line |
|---|---|
| en | Meet someone who gets your rhythm. |
| fr | Rencontre quelqu'un qui comprend ton rythme. |
| es | Conoce a alguien que entienda tu ritmo. |
| de | Triff jemanden, der deinen Rhythmus versteht. |
| it | Incontra qualcuno che capisce il tuo ritmo. |
| pt | Conhece alguém que perceba o teu ritmo. |
| nl | Ontmoet iemand die jouw ritme begrijpt. |

| | Promise |
|---|---|
| en | Singles who love sport as much as you do, and one more session in your week. |
| fr | Des célibataires qui aiment le sport autant que toi, et une séance de plus dans la semaine. |
| es | Gente soltera que ama el deporte tanto como tú, y una sesión más en la semana. |
| de | Singles, die Sport so lieben wie du, und eine Session mehr in der Woche. |
| it | Single che amano lo sport quanto te, e una sessione in più nella settimana. |
| pt | Pessoas solteiras que gostam de desporto tanto como tu, e mais uma sessão na semana. |
| nl | Singles die net zo van sport houden als jij, en één sessie extra in de week. |

| | Invitation | Confirmation (lead-in) |
|---|---|---|
| en | You already speak the same language. See you at the start line? | Session confirmed. |
| fr | Vous parlez déjà la même langue. On se retrouve sur la ligne de départ ? | Séance confirmée. |
| es | Ya habláis el mismo idioma. ¿Nos vemos en la línea de salida? | Sesión confirmada. |
| de | Ihr sprecht schon dieselbe Sprache. Sehen wir uns an der Startlinie? | Session bestätigt. |
| it | Parlate già la stessa lingua. Ci vediamo sulla linea di partenza? | Sessione confermata. |
| pt | Já falam a mesma língua. Vemo-nos na linha de partida? | Sessão confirmada. |
| nl | Jullie spreken al dezelfde taal. Zien we elkaar op de startlijn? | Sessie bevestigd. |

Retired as brand lines (kept here so nobody reintroduces them): "Turn your matches into sessions.",
"Meet singles who train." (still the store subtitle, 7.4), "Meet singles who share your rhythm.",
"Same rhythm? Propose a session.", "Meet me on the start line.", "Dating, with a start time.",
"Same start line. Your pace.", "From match to start line.", "Ready, set, meet.", "Better in the
draft." (the last two may still serve a one-off event or campaign, never a product surface).

### 7.3 Declensions

- Match screen: "It's mutual." + "Propose a session while it's fresh." / « C'est réciproque. » +
  « Propose une séance tant que c'est frais. »
- Session confirmed: "Session confirmed." + the day and time (Confirmation, 7.2). No slogan.
- Website closing call to action: the Invitation (7.2).
- Social: #meetmeonthestartline (campaign hashtag only).

### 7.4 Store frame

| Field | Limit | EN | FR |
|---|---|---|---|
| App name | 30 | drafft: Sports Dating | drafft : rencontre sportive |
| Subtitle (iOS) | 30 | Meet singles who train | Célibataires qui s'entraînent |
| Short description (Play) | 80 | Meet someone who gets your rhythm, then propose a session. | Rencontre quelqu'un qui comprend ton rythme, puis propose une séance. |

The subtitle is the Line's short form: the line itself is too long for 30 characters and would drop
"singles" from the store index.

Full store texts: `docs/wording/store.md`.

## 8. Before / after

| Type | Before | After |
|---|---|---|
| Website hero | First dates that move. | Meet someone who gets your rhythm. / Rencontre quelqu'un qui comprend ton rythme. |
| Website promise | Every match ends in a plan: a sport, a place, a time. | Singles who love sport as much as you do, and one more session in your week. |
| Match screen | It's a match. | It's mutual. |
| Match body | Say hi, then plan a first session. | You both train. Say hi, or propose a session while it's fresh. |
| Chats empty | Say hi to a new match and plan a first session. | Say hi to a new match, or propose a first session. |
| CTA | Keep swiping | Back to Discover |
| Push | It's a match with Léa! Suggest a first session. | Léa likes you back. Propose a first session. |
| Error | Something went wrong. | It didn't go through. Try again in a moment. |
| Paywall headline | Take it back. | Train at your tempo. |
| Session idea | Bouldering, then a beer? | Bouldering, then a smoothie? |
| FR greeting | Content de te revoir | Te revoilà. |
| Delete | We're sorry to see you go. / Your call. Here's what deleting removes. | Here's what deleting removes. / « Voici ce que la suppression efface. » |

## 9. Screenshot and marketing content

For App Store / Play screenshots, the website phone, social posts and demos.

- **People:** varied ages, levels (beginner to competitive), sports, bodies, origins,
  genders and orientations. Invented names common in the market's country. Never real people, never
  invented testimonials, user counts, ratings or press.
- **Bios:** written like a real person on their phone: short, specific, a little self-deprecating.
  One concrete detail beats three adjectives ("Slowest in my run club, first at the bakery after.").
- **Chats:** 4–8 messages, natural rhythm (short replies, a question back, one typo-free joke), ending
  on a session proposal or a picked time. Real details: a place, a time, a pace. No marketing
  voice, no brand name in messages, no "!!!", at most one emoji.
- **Humour:** gentle teasing about training habits (the 5:45 alarm, the fake "easy pace", the
  post-run croissant). Never about bodies, exes, gender, alcohol, or anything that could read as
  flirting-with-innuendo.
- **Always:** respectful, positive, consent-aware (the other person picks or proposes another time).
- Sets in use: `docs/wording/screenshots.md`.

## 10. Review checklist

Run on every text before you validate it.

- [ ] No "plan" in any sense or language (5.1). No match → date/night promise.
- [ ] No hookup word or double meaning (5.2). Read it once as a suspicious reader.
- [ ] No category cliché or competitor line (5.3). No fake urgency, guilt, body judgement (5.5).
- [ ] Brand terms exact: drafft, drafft tempo, session/séance, propose/proposer, times/créneaux.
- [ ] Informal "you"; FR non-breaking spaces; gender-neutral; sentence case.
- [ ] CTA starts with a verb, 1–3 words, says what happens, fits one line in every language (6).
- [ ] Headline ends with a full stop; no "!" or emoji in UI, push, email.
- [ ] Error: what happened + one way out, no blame.
- [ ] All 7 languages updated, adapted (not literal), same placeholders, no longer than needed.
- [ ] Nothing invented: no value, percentage or count without real data (5.4), no testimonials,
  no demo text, no features we don't have (no "place" field in an
  invite, no level field on profiles, selfie check only when moderation asks).
- [ ] Lints pass (`python3 scripts/ci/i18n_lint.py`, backend tests, web CI).

## 11. Decision log

- 2026-09-29: Guidelines created. "plan" banned in every sense and language, subscriptions included.
- 2026-09-29: A match promises nothing: we invite ("Turn your matches into sessions"), we never
  state that a match becomes or leads to something.
- 2026-09-29: "It's a match." replaced by "It's mutual." / « C'est réciproque. ».
- 2026-09-29: Primary territory "Meet me on the start line"; "First dates that move." retired (too
  close to bpm's "the first date is a workout"). Trademark check (INPI/EUIPO) pending.
- 2026-09-29: One verb to send a session: propose / proposer. "pitch" becomes note / petit mot.
- 2026-09-29: The app has no level field and no place field: copy never promises either.
- 2026-09-29: A pair of unknown genders may take the standard plural in ES/IT/PT ("los dos",
  "entrambi", "os dois") when a neutral phrasing would read unnaturally.
- 2026-09-29: FR brand voice: « on » (never « nous » as subject); « l'équipe drafft » only as the
  signature of a support reply.
- 2026-09-29: Push title = the person's name or the event ("New like", "In an hour"), never "drafft".
  An unknown name falls back to "Someone" / « Quelqu'un ».
- 2026-09-29: Session cards posted in a chat stay in English (one message, two readers): the only
  exception to "one language per person".
- 2026-09-29: Auth-code email subjects keep the code wording iOS autofill recognises.
- 2026-09-29: Never invent a value or percentage (5.4): the icebreaker's computed "% agree so far"
  and the "Demo text" line of the legal sheets were removed.
- 2026-09-29: Session ideas and prompts suggest coffee, brunch, smoothies, picnics; never drinks or
  dinner, never a city-specific place (the app runs in several cities).
- 2026-09-30: Primary line replaced by "Meet singles who train." / « Rencontre des célibataires qui
  s'entraînent. » (store subtitle: "Meet singles who train" / « Célibataires qui s'entraînent »).
  « Rendez-vous au départ » read oddly in French out of context and didn't say sport dating; it stays
  for a confirmed session and campaigns (7.2 n°9). The start line remains the brand territory.
  Rejected: "the first date is a session" (bpm), « et plus si affinités » (double meaning),
  "it all starts with…" (Tinder), « célibataire et sportif » (masculine default).
- 2026-09-30: Store screenshots and the Play feature graphic: rules, captions in 7 languages and the
  pipeline in `docs/store-screenshots/`.
- 2026-09-30: Pack names in the stores keep their capitals, as in App Store Connect and Google Play ("5 Boosts",
  "3 Super Likes"). Running copy stays lowercase (like, super like, boost). The earlier rule "lowercase, also in
  store product names" is withdrawn.
- 2026-09-30: The delete page no longer opens on "Your call." / « À toi de voir. »: it read as curt, even
  resentful. It states the fact instead: "Here's what deleting removes." / « Voici ce que la
  suppression efface. »
- 2026-10-01: "plan" stays banned with no exception, subscriptions included: also out of the
  catalog's English keys (the lint checks keys) and of "plano" in ES/PT, even as "flat" or
  "segundo plano" (background).
- 2026-10-01: Desire and attraction words banned when they point at a person (5.2), like « plan »:
  « ce qui t'a donné envie », « faire craquer », "win me over", DE "rumkriegen". The like comment
  field becomes "Add a note" / « Ajoute un petit mot »; the prompt "The way to win me over" reads
  "To convince me, propose" / « Pour me convaincre, propose-moi ».
- 2026-10-01: Buttons stay on one line in every language, with a character budget per layout (6).
  The session card's "Propose other times" wrapped in French and German: it became "Other times" /
  « Autres créneaux » (calendar icon); the sheet it opens keeps the full title. Other labels over
  budget were shortened in the languages concerned (calendar, data, undo, comment buttons), and the
  confirm and send buttons drop the day or the count rather than wrap.
- 2026-10-01: One message system (7.2): four formulas, one role each. Line "Meet someone who gets your
  rhythm." / « Rencontre quelqu'un qui comprend ton rythme. » (replaces "Meet singles who train.");
  Promise "Singles who love sport as much as you do, and one more session in your week." / « Des
  célibataires qui aiment le sport autant que toi, et une séance de plus dans la semaine. »;
  Invitation "You already speak the same language. See you at the start line?" / « Vous parlez déjà la
  même langue. On se retrouve sur la ligne de départ ? »; Confirmation "Session confirmed." + day and
  time (« calée » judged too familiar). The start line is spent sparingly: only the Invitation and the
  campaign hashtag. Taglines 2 to 9 of the former list are retired. Store subtitle stays "Meet singles
  who train" / « Célibataires qui s'entraînent » (30-character limit, keeps "singles" indexed).
  Descriptor fixed: "dating app" / « app de rencontre », never « appli ».
  Known proximity: bpm's store copy says « Marre des matchs qui ne comprennent pas ton rythme »
  (`docs/wording/competitive-research.md`). The Line stays on "rhythm" by the founder's choice; the
  Promise and Invitation stay clear of it.
