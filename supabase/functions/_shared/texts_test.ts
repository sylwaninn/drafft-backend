import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  language,
  likeReceived,
  matchCreated,
  messageSent,
  previewSeparator,
  reaction,
  sessionAutoCancelled,
  sessionChanged,
  sessionName,
  superLikeReceived,
} from "./texts.ts";
import { sportNames } from "./sports.ts";

const all = ["en", "fr", "es", "de", "it", "pt", "nl"] as const;

Deno.test("language picks each of the app's 7 languages", () => {
  for (const l of all) assertEquals(language(l), l);
});

Deno.test("language reads region tags and case", () => {
  assertEquals(language("pt-PT"), "pt");
  assertEquals(language("fr_FR"), "fr");
  assertEquals(language(" DE "), "de");
});

Deno.test("language falls back to English", () => {
  for (const value of [null, undefined, "", "ja", "english", 42, {}, "xx-FR"]) assertEquals(language(value), "en");
});

Deno.test("like pushes never name the person", () => {
  for (const l of all) {
    assertEquals(likeReceived[l].length > 0, true);
    assertEquals(superLikeReceived[l].length > 0, true);
  }
  assertEquals(likeReceived.en, "Someone liked your profile");
});

Deno.test("sentences match the app's NotificationText", () => {
  assertEquals(matchCreated("en", "Maya"), "It's a match with Maya! Suggest a first session.");
  assertEquals(matchCreated("fr", "Maya"), "C'est un match avec Maya ! Propose-lui une première séance.");
  assertEquals(sessionChanged("de", "accepted", "Maya", "Lauf"), "Maya ist dabei: Lauf");
  assertEquals(sessionChanged("en", "declined", "Maya", "Run"), "Maya can't make it: Run");
  assertEquals(reaction("it", "Maya", "❤️"), "Maya ha reagito con ❤️ al tuo messaggio");
});

Deno.test("a session without a title is named after its sport, in the person's language", () => {
  assertEquals(sessionName("en", "", "padel"), "Padel session");
  assertEquals(sessionName("fr", null, "running"), "Séance Running");
  assertEquals(sessionName("nl", "  Sunrise run ", "running"), "Sunrise run");
  assertEquals(sessionName("en", null, "unknownSport"), "unknownSport session");
});

Deno.test("every sport has a name in every language", () => {
  for (const [id, names] of Object.entries(sportNames)) {
    for (const l of all) assertEquals(typeof names[l] === "string" && names[l].length > 0, true, `${id} ${l}`);
  }
});

Deno.test("every sentence exists in every language", () => {
  for (const l of all) {
    for (const change of ["proposed", "accepted", "declined", "cancelled"] as const) {
      assertEquals(sessionChanged(l, change, "A", "B").includes("A"), true);
    }
    assertEquals(sessionAutoCancelled(l, null, "Europe/Paris").length > 0, true);
  }
});

Deno.test("message push pieces exist in every language, like NotificationText .message and .preview", () => {
  for (const l of all) assert(messageSent[l].length > 0);
  assertEquals(messageSent.pt, "enviou-te uma mensagem");
  assertEquals(previewSeparator("fr"), "\u00A0: ");
  assertEquals(previewSeparator("de"), ": ");
});
