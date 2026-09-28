// Push sentences in the app's languages, the same as the app's NotificationText (casual register,
// European Portuguese, a non-breaking space before ":" in French). `profiles.language` picks one.
export type Language = "en" | "fr" | "es" | "de" | "it" | "pt" | "nl";

export function language(value: unknown): Language {
  return ["en", "fr", "es", "de", "it", "pt", "nl"].includes(value as string) ? value as Language : "en";
}

export const weeklyBoost: Record<Language, string> = {
  en: "Your weekly boost is here. Use it anytime: 30 minutes at the top of decks nearby.",
  fr: "Ton boost de la semaine est là. Utilise-le quand tu veux : 30 minutes en tête des profils près de toi.",
  es: "Ya tienes tu boost semanal. Úsalo cuando quieras: 30 minutos en lo más alto cerca de ti.",
  de: "Dein Wochen-Boost ist da. Nutz ihn, wann du willst: 30 Minuten ganz oben in deiner Nähe.",
  it: "Il tuo boost settimanale è arrivato. Usalo quando vuoi: 30 minuti in cima ai profili vicino a te.",
  pt: "O teu boost semanal chegou. Usa-o quando quiseres: 30 minutos no topo perto de ti.",
  nl: "Je wekelijkse boost is er. Gebruik hem wanneer je wilt: 30 minuten bovenaan bij mensen in de buurt.",
};

/** "Maya reacted ❤️ to: “See you at 7?”", or without the message (previews off, or not text). */
export function reaction(lang: Language, name: string, emoji: string, text?: string): string {
  if (!text) {
    return {
      en: `${name} reacted ${emoji} to your message`,
      fr: `${name} a réagi ${emoji} à ton message`,
      es: `${name} ha reaccionado con ${emoji} a tu mensaje`,
      de: `${name} hat mit ${emoji} auf deine Nachricht reagiert`,
      it: `${name} ha reagito con ${emoji} al tuo messaggio`,
      pt: `${name} reagiu com ${emoji} à tua mensagem`,
      nl: `${name} reageerde met ${emoji} op je bericht`,
    }[lang];
  }
  const oneLine = text.replace(/\s+/g, " ").trim();
  const t = [...oneLine].length > 60 ? [...oneLine].slice(0, 59).join("").trimEnd() + "…" : oneLine;
  return {
    en: `${name} reacted ${emoji} to: “${t}”`,
    fr: `${name} a réagi ${emoji} à : « ${t} »`,
    es: `${name} ha reaccionado con ${emoji} a: «${t}»`,
    de: `${name} hat mit ${emoji} auf „${t}“ reagiert`,
    it: `${name} ha reagito con ${emoji} a: «${t}»`,
    pt: `${name} reagiu com ${emoji} a: «${t}»`,
    nl: `${name} reageerde met ${emoji} op: ‘${t}’`,
  }[lang];
}

/** "Tuesday 14 October at 7:00", in the person's language and time zone. */
function sessionTime(lang: Language, at: Date, timeZone: string): { day: string; time: string } {
  const zone = (() => {
    try {
      new Intl.DateTimeFormat("en", { timeZone });
      return timeZone;
    } catch {
      return "UTC";
    }
  })();
  const locale = lang === "pt" ? "pt-PT" : lang === "en" ? "en-GB" : lang;
  const day = new Intl.DateTimeFormat(locale, { timeZone: zone, weekday: "long", day: "numeric", month: "long" })
    .format(at);
  const time = new Intl.DateTimeFormat(locale, { timeZone: zone, hour: "numeric", minute: "2-digit" }).format(at);
  return { day, time };
}

/**
 * An upcoming session cancelled on its own (the match ended, an account was banned or deleted). Neutral
 * on purpose: no name, no reason. Without a single time (a proposal with several options), no date.
 */
export function sessionAutoCancelled(lang: Language, at: Date | null, timeZone: string): string {
  if (!at) {
    return {
      en: "Your session was cancelled.",
      fr: "Ta séance a été annulée.",
      es: "Tu sesión se ha cancelado.",
      de: "Deine Session wurde abgesagt.",
      it: "La tua sessione è stata annullata.",
      pt: "A tua sessão foi cancelada.",
      nl: "Je sessie is geannuleerd.",
    }[lang];
  }
  const { day, time } = sessionTime(lang, at, timeZone);
  return {
    en: `Your session on ${day} at ${time} was cancelled.`,
    fr: `Ta séance du ${day} à ${time} a été annulée.`,
    es: `Tu sesión del ${day} a las ${time} se ha cancelado.`,
    de: `Deine Session am ${day} um ${time} wurde abgesagt.`,
    it: `La tua sessione di ${day} alle ${time} è stata annullata.`,
    pt: `A tua sessão de ${day} às ${time} foi cancelada.`,
    nl: `Je sessie op ${day} om ${time} is geannuleerd.`,
  }[lang];
}
