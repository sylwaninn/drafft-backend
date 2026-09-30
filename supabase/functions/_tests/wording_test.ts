// Every word the server sends people (push, email, SMS), in the 7 languages, checked against WORDING.md: the
// forbidden patterns of its `wording-forbidden` block (the same block the app's i18n lint and the website's CI
// read), then the form rules a machine can check (French spaces, no "!", the brand in lowercase, short email
// subjects).
//
//   cd supabase/functions && deno test --allow-env --allow-read=.,../../WORDING.md _tests/wording_test.ts
//
// The modules are imported and their exports walked: every string in an exported object, and what every
// exported function writes, called in each language. A new exported function must be added to `samples` (or
// to `notCopy` when it writes no words), so nothing new escapes the check.
import { assert } from "jsr:@std/assert@1";
import * as emails from "../_shared/emails.ts";
import * as notices from "../_shared/notices.ts";
import * as sms from "../_shared/sms.ts";
import * as texts from "../_shared/texts.ts";

type Language = texts.Language;
const languages: Language[] = ["en", "fr", "es", "de", "it", "pt", "nl"];

/** One string people may read: where it comes from, and its language when known. */
type Copy = { where: string; lang?: Language; text: string };

// MARK: WORDING.md

/** The `wording-forbidden` block: one `pattern | reason` per line, case-insensitive. */
async function forbidden(): Promise<{ pattern: RegExp; reason: string }[]> {
  const md = await Deno.readTextFile(new URL("../../../WORDING.md", import.meta.url));
  const block = md.match(/```wording-forbidden\n([\s\S]*?)\n```/);
  assert(block, "WORDING.md has no ```wording-forbidden block");
  return block[1].split("\n").map((line) => line.trim()).filter(Boolean).map((line) => {
    const split = line.lastIndexOf(" | ");
    assert(split > 0, `WORDING.md: "${line}" is not "pattern | reason"`);
    return { pattern: new RegExp(line.slice(0, split).trim(), "iu"), reason: line.slice(split + 3).trim() };
  });
}

// MARK: Walking the modules

/** Every string inside an exported value; a path segment that is a language code tags the language. */
function strings(value: unknown, where: string, lang?: Language, out: Copy[] = []): Copy[] {
  if (typeof value === "string") out.push({ where, lang, text: value });
  else if (value && typeof value === "object") {
    for (const [key, inner] of Object.entries(value)) {
      const tagged = languages.includes(key as Language) ? key as Language : lang;
      strings(inner, `${where}.${key}`, tagged, out);
    }
  }
  return out;
}

const session = "Padel session";
const at = new Date("2026-10-14T16:30:00Z");

/** What each exported function writes, in one language. */
const samples: Record<string, (l: Language) => unknown> = {
  "texts.matchCreated": (l) => texts.matchCreated(l, "Maya"),
  "texts.sessionName": (l) => [texts.sessionName(l, null, "padel"), texts.sessionName(l, "Sunrise run", "running")],
  "texts.sessionChanged": (l) =>
    (["proposed", "accepted", "declined", "cancelled"] as const).map((c) =>
      texts.sessionChanged(l, c, "Maya", session)
    ),
  "texts.reaction": (l) => [texts.reaction(l, "Maya", "❤️"), texts.reaction(l, "Maya", "❤️", "See you at 7")],
  "texts.sessionAutoCancelled": (l) => [
    texts.sessionAutoCancelled(l, null, "Europe/Paris"),
    texts.sessionAutoCancelled(l, at, "Europe/Paris"),
  ],
  "texts.sessionReminderEvening": (l) => [
    texts.sessionReminderEvening(l, session, at, "Europe/Paris", "Maya"),
    texts.sessionReminderEvening(l, session, at, "Europe/Paris"),
  ],
  "texts.sessionReminderHour": (l) => texts.sessionReminderHour(l, session, "Maya"),
  "emails.renderAuthEmail": (l) =>
    Object.keys(emails.authEmailCopy).map((kind) =>
      rendered(emails.renderAuthEmail(kind as emails.AuthEmail, l, { code: "123456", email: "maya@example.com" }))
    ),
  "notices.renderNotice": (l) =>
    Object.keys(notices.noticeCopy).map((kind) =>
      rendered(notices.renderNotice(kind as notices.Notice, l, { reference: "DR-ABC123" }))
    ),
  "notices.renderExportReady": (l) => [
    rendered(notices.renderExportReady(l, ["https://drafft.test/export.zip"])),
    rendered(notices.renderExportReady(l, [1, 2, 3].map((n) => `https://drafft.test/export-${n}.zip`))),
  ],
  "notices.renderDecision": (l) =>
    Object.keys(notices.decisionCopy).flatMap((kind) => [
      ...Object.keys(notices.reasonCopy).flatMap((category) =>
        rendered(
          notices.renderDecision(l, kind as notices.Decision, category, "community", "Keep it friendly, please."),
        )
      ),
      ...rendered(notices.renderDecision(l, kind as notices.Decision, "other", null)),
    ]),
  "notices.renderSupportReply": (l) =>
    rendered(
      notices.renderSupportReply(l, { reference: "DR-ABC123", topic: "Account", body: "Reply", message: "Question" }),
    ),
  "sms.verificationSms": (l) => sms.verificationSms(l, "123456"),
};

/** Exported functions that write no words of their own: markup helpers, parsing, sending, the team's copy. */
const notCopy = new Set([
  "texts.language",
  "notices.termsLink",
  "emails.codeBox",
  "emails.title",
  "emails.paragraph",
  "emails.small",
  "emails.layout",
  "emails.escape",
  "notices.renderTeamEmail",
  "sms.isE164",
  "sms.checkLine",
  "sms.sendSms",
]);

/** A rendered email as people read it: the subject and the plain-text part (the HTML says the same). */
function rendered(email: emails.Rendered): string[] {
  return [email.subject, ...email.text.split("\n")];
}

const modules = { texts, emails, notices, sms };

function allCopy(): Copy[] {
  const out: Copy[] = [];
  for (const [name, module] of Object.entries(modules)) {
    for (const [key, value] of Object.entries(module)) {
      const where = `${name}.${key}`;
      if (typeof value !== "function") strings(value, where, undefined, out);
      else if (samples[where]) { for (const l of languages) strings(samples[where](l), `${where}(${l})`, l, out); }
    }
  }
  return out;
}

// MARK: Tests

Deno.test("every exported function is either sampled or known to write no words", () => {
  const missing = Object.entries(modules).flatMap(([name, module]) =>
    Object.entries(module).filter(([key, value]) =>
      typeof value === "function" && !samples[`${name}.${key}`] && !notCopy.has(`${name}.${key}`)
    ).map(([key]) => `${name}.${key}`)
  );
  assert(missing.length === 0, `add to samples (or notCopy): ${missing.join(", ")}`);
});

Deno.test("no push, email or SMS uses a pattern WORDING.md forbids, in any language", async () => {
  const rules = await forbidden();
  assert(rules.length > 0, "WORDING.md's wording-forbidden block is empty");
  const copy = allCopy();
  assert(copy.length > 500, `only ${copy.length} strings found: the walk missed something`);
  const hits = copy.flatMap((c) =>
    rules.filter((r) => r.pattern.test(c.text)).map((r) => `${c.where}: ${r.reason}: ${JSON.stringify(c.text)}`)
  );
  assert(hits.length === 0, `see WORDING.md section 5:\n${hits.join("\n")}`);
});

Deno.test("French puts a non-breaking space before : ; ! ? » and after «", () => {
  const bad = allCopy().filter((c) => c.lang === "fr").filter((c) => {
    // A time ("07:00"), a URL and a reply's "Re:" (a mail convention) are not French punctuation.
    const text = c.text.replace(/\d:\d/g, "").replace(/https?:\/\/\S+/g, "").replace(/^Re: /, "");
    return /[^\u00A0\u202F][:;!?»]/.test(text) || /«[^\u00A0\u202F]/.test(text);
  }).map((c) => `${c.where}: ${JSON.stringify(c.text)}`);
  assert(bad.length === 0, `WORDING.md section 6, Punctuation:\n${bad.join("\n")}`);
});

Deno.test("no exclamation mark in a push, an email or an SMS, and drafft in lowercase", () => {
  const bad = allCopy().filter((c) => /[!¡]/.test(c.text) || /\b(Drafft|DRAFFT)\b/.test(c.text))
    .map((c) => `${c.where}: ${JSON.stringify(c.text)}`);
  assert(bad.length === 0, `WORDING.md sections 4 and 6:\n${bad.join("\n")}`);
});

Deno.test("an email subject says one thing in 45 characters at most", () => {
  const subjects = [
    ...strings(emails.authEmailCopy, "emails.authEmailCopy"),
    ...strings(notices.noticeCopy, "notices.noticeCopy"),
    ...strings(notices.decisionCopy, "notices.decisionCopy"),
  ].filter((c) => c.where.endsWith(".subject"));
  assert(subjects.length === 7 * 15, `${subjects.length} subjects`);
  const long = subjects.filter((c) => [...c.text.replace("{code}", "123456")].length > 45)
    .map((c) => `${c.where}: ${JSON.stringify(c.text)}`);
  assert(long.length === 0, `WORDING.md section 6, Email:\n${long.join("\n")}`);
});

Deno.test("the support acknowledgement's subject, its reference included, keeps to 45 characters", () => {
  const long = languages.map((l) => notices.renderNotice("supportReceived", l, { reference: "DR-ABC123" }).subject)
    .filter((subject) => [...subject].length > 45);
  assert(long.length === 0, `WORDING.md section 6, Email:\n${long.join("\n")}`);
});
