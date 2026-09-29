import { assertEquals } from "jsr:@std/assert@1";
import {
  language,
  likeReceived,
  matchCreated,
  messageSent,
  reaction,
  sessionAutoCancelled,
  sessionChanged,
  sessionName,
  sessionReminderEvening,
  sessionReminderHour,
  someone,
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
    assertEquals(likeReceived[l].title.length > 0 && likeReceived[l].body.length > 0, true);
    assertEquals(superLikeReceived[l].title.length > 0 && superLikeReceived[l].body.length > 0, true);
  }
  assertEquals(likeReceived.en, { title: "New like", body: "Someone liked your profile." });
});

Deno.test("a push about a person is titled with their name, the same sentences as the app's NotificationText", () => {
  assertEquals(matchCreated("en", "Maya"), { title: "Maya", body: "It's mutual: propose a first session." });
  assertEquals(matchCreated("fr", "Maya"), {
    title: "Maya",
    body: "C'est réciproque : propose une première séance.",
  });
  assertEquals(sessionChanged("de", "accepted", "Maya", "Lauf").body, "Hat die Session bestätigt: Lauf");
  assertEquals(sessionChanged("en", "declined", "Maya", "Run"), {
    title: "Maya",
    body: "Can't make it this time: Run",
  });
  assertEquals(reaction("it", "Maya", "❤️"), { title: "Maya", body: "Ha reagito con ❤️ al tuo messaggio." });
  assertEquals(reaction("fr", "Maya", "❤️", "On se voit à 7h ?").body, "A réagi ❤️ à « On se voit à 7h ? »");
});

Deno.test("a person without a name is titled 'someone', never an empty title", () => {
  for (const l of all) {
    assertEquals(matchCreated(l, null).title, someone[l]);
    assertEquals(matchCreated(l, "  ").title, someone[l]);
    assertEquals(reaction(l, "", "❤️").title, someone[l]);
    assertEquals(sessionChanged(l, "proposed", undefined, "Padel").title, someone[l]);
  }
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
      const push = sessionChanged(l, change, "A", "B");
      assertEquals(push.title === "A" && push.body.endsWith("B"), true);
    }
    assertEquals(sessionAutoCancelled(l, null, "Europe/Paris").body.length > 0, true);
    assertEquals(messageSent[l].length > 0, true);
  }
  assertEquals(messageSent.pt, "Nova mensagem.");
});

Deno.test("session reminders: the time in the person's zone as the title, who it's with in the body", () => {
  const at = new Date("2026-10-25T06:00:00Z"); // 7:00 in Paris, the day winter time starts
  assertEquals(sessionReminderEvening("en", "Sunrise run", at, "Europe/Paris", "Maya"), {
    title: "Tomorrow at 7:00",
    body: "With Maya: Sunrise run",
  });
  assertEquals(sessionReminderHour("fr", "Footing", "Maya"), { title: "Dans une heure", body: "Avec Maya : Footing" });
  assertEquals(sessionReminderHour("de", "Lauf", null).body, "Lauf");
});
