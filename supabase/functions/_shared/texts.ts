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
