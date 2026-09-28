// Push sentences in the app's languages, the same as the app's NotificationText (casual register,
// European Portuguese, a non-breaking space before ":" in French). `profiles.language` picks one.
import { sportNames } from "./sports.ts";

export type Language = "en" | "fr" | "es" | "de" | "it" | "pt" | "nl";

const languages: readonly Language[] = ["en", "fr", "es", "de", "it", "pt", "nl"];

/** The person's language from `profiles.language` ("fr", or a tag like "pt-PT"). Anything else: English. */
export function language(value: unknown): Language {
  if (typeof value !== "string") return "en";
  const base = value.trim().toLowerCase().split(/[-_]/)[0];
  return languages.includes(base as Language) ? base as Language : "en";
}

/** Every push is titled like the app's own notifications (NotificationText.title). */
export const pushTitle = "drafft";

/** A name for someone whose profile has none (or is gone), inside the sentences below. */
export const someone: Record<Language, string> = {
  en: "Someone",
  fr: "Quelqu'un",
  es: "Alguien",
  de: "Jemand",
  it: "Qualcuno",
  pt: "Alguém",
  nl: "Iemand",
};

/** A like, anonymous on purpose: the Likes tab is where people see who it was. */
export const likeReceived: Record<Language, string> = {
  en: "Someone liked your profile",
  fr: "Quelqu'un a liké ton profil",
  es: "A alguien le gusta tu perfil",
  de: "Jemandem gefällt dein Profil",
  it: "Qualcuno ha messo like al tuo profilo",
  pt: "Alguém gostou do teu perfil",
  nl: "Iemand vindt je profiel leuk",
};

/** A super like, anonymous like a like. */
export const superLikeReceived: Record<Language, string> = {
  en: "Someone sent you a super like",
  fr: "Quelqu'un t'a envoyé un super like",
  es: "Alguien te ha enviado un superlike",
  de: "Jemand hat dir einen Super Like geschickt",
  it: "Qualcuno ti ha mandato un super like",
  pt: "Alguém enviou-te um super like",
  nl: "Iemand heeft je een superlike gestuurd",
};

/** NotificationText .match: "It's a match with Maya! Suggest a first session." */
export function matchCreated(lang: Language, name: string): string {
  return {
    en: `It's a match with ${name}! Suggest a first session.`,
    fr: `C'est un match avec ${name}\u00A0! Propose-lui une première séance.`,
    es: `¡Match con ${name}! Proponle una primera sesión.`,
    de: `Match mit ${name}! Schlag eine erste Session vor.`,
    it: `Match con ${name}! Proponi una prima sessione.`,
    pt: `Match com ${name}! Propõe uma primeira sessão.`,
    nl: `Match met ${name}! Stel een eerste sessie voor.`,
  }[lang];
}

/** A session's name in a push: its title, or "<Sport> session" like the app's Session.displayTitle. */
export function sessionName(lang: Language, title: string | null | undefined, sportId: string): string {
  if (title?.trim()) return title.trim();
  const sport = sportNames[sportId]?.[lang] ?? sportId;
  return {
    en: `${sport} session`,
    fr: `Séance ${sport}`,
    es: `Sesión de ${sport}`,
    de: `${sport}-Session`,
    it: `Sessione di ${sport}`,
    pt: `Sessão de ${sport}`,
    nl: `${sport}-sessie`,
  }[lang];
}

export type SessionChange = "proposed" | "accepted" | "declined" | "cancelled";

/** NotificationText .sessionProposed/.sessionAccepted/.sessionDeclined/.sessionCancelled. */
export function sessionChanged(lang: Language, change: SessionChange, name: string, session: string): string {
  const n = name, t = session;
  return {
    proposed: {
      en: `${n} suggested a session: ${t}`,
      fr: `${n} te propose une séance\u00A0: ${t}`,
      es: `${n} te propone una sesión: ${t}`,
      de: `${n} schlägt dir eine Session vor: ${t}`,
      it: `${n} ti propone una sessione: ${t}`,
      pt: `${n} propõe-te uma sessão: ${t}`,
      nl: `${n} stelt een sessie voor: ${t}`,
    },
    accepted: {
      en: `${n} is in: ${t}`,
      fr: `${n} a accepté\u00A0: ${t}`,
      es: `${n} ha aceptado: ${t}`,
      de: `${n} ist dabei: ${t}`,
      it: `${n} ha accettato: ${t}`,
      pt: `${n} aceitou: ${t}`,
      nl: `${n} doet mee: ${t}`,
    },
    declined: {
      en: `${n} can't make it: ${t}`,
      fr: `${n} ne peut pas venir\u00A0: ${t}`,
      es: `${n} no puede ir: ${t}`,
      de: `${n} kann nicht: ${t}`,
      it: `${n} non può venire: ${t}`,
      pt: `${n} não pode ir: ${t}`,
      nl: `${n} kan niet: ${t}`,
    },
    cancelled: {
      en: `${n} cancelled: ${t}`,
      fr: `${n} a annulé\u00A0: ${t}`,
      es: `${n} ha cancelado: ${t}`,
      de: `${n} hat abgesagt: ${t}`,
      it: `${n} ha annullato: ${t}`,
      pt: `${n} cancelou: ${t}`,
      nl: `${n} heeft afgezegd: ${t}`,
    },
  }[change][lang];
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

/** A photo refused, by Rekognition or by the team (the app's PhotoRefusal screen says why). */
export const photoRefused: Record<Language, string> = {
  en: "One of your photos wasn't approved. Tap to see why.",
  fr: "Une de tes photos n'a pas été validée. Touche pour savoir pourquoi.",
  es: "Una de tus fotos no se ha aprobado. Toca para ver por qué.",
  de: "Eines deiner Fotos wurde nicht freigegeben. Tippe, um zu sehen, warum.",
  it: "Una delle tue foto non è stata approvata. Tocca per scoprire perché.",
  pt: "Uma das tuas fotos não foi aprovada. Toca para saber porquê.",
  nl: "Een van je foto's is niet goedgekeurd. Tik om te zien waarom.",
};

/** Moderation news the person is waiting for: a hold lifted, a selfie asked for, judged. Never a new
 * restriction (review, ban): those are said by the app's own screen, not pushed. */
export type ModerationPush = "restored" | "reopened" | "selfieApproved" | "selfieRequested" | "selfieRetry";

export const moderationPush: Record<ModerationPush, Record<Language, string>> = {
  restored: {
    en: "Your account is open again. Everything is in order.",
    fr: "Ton compte est de nouveau ouvert. Tout est en ordre.",
    es: "Tu cuenta vuelve a estar abierta. Todo está en orden.",
    de: "Dein Konto ist wieder offen. Alles ist in Ordnung.",
    it: "Il tuo account è di nuovo attivo. È tutto in ordine.",
    pt: "A tua conta está novamente aberta. Está tudo em ordem.",
    nl: "Je account is weer open. Alles is in orde.",
  },
  reopened: {
    en: "We've looked again and reopened your account. Welcome back.",
    fr: "Nous avons réexaminé ton compte et l'avons rouvert. Content de te revoir.",
    es: "Hemos vuelto a revisar tu cuenta y la hemos reabierto. Qué bien tenerte de vuelta.",
    de: "Wir haben dein Konto noch einmal geprüft und wieder geöffnet. Schön, dass du wieder da bist.",
    it: "Abbiamo riesaminato il tuo account e l'abbiamo riaperto. Che bello rivederti.",
    pt: "Voltámos a analisar a tua conta e reabrimo-la. Que bom ver-te de volta.",
    nl: "We hebben je account opnieuw bekeken en weer geopend. Fijn dat je er weer bent.",
  },
  selfieApproved: {
    en: "Your selfie is verified. Your account is open again.",
    fr: "Ton selfie est validé. Ton compte est de nouveau ouvert.",
    es: "Tu selfie está verificado. Tu cuenta vuelve a estar abierta.",
    de: "Dein Selfie ist bestätigt. Dein Konto ist wieder offen.",
    it: "Il tuo selfie è verificato. Il tuo account è di nuovo attivo.",
    pt: "A tua selfie foi validada. A tua conta está novamente aberta.",
    nl: "Je selfie is bevestigd. Je account is weer open.",
  },
  selfieRequested: {
    en: "We need a quick selfie to confirm it's you. Tap to take it.",
    fr: "Nous avons besoin d'un selfie rapide pour confirmer que c'est bien toi. Touche pour le prendre.",
    es: "Necesitamos un selfie rápido para confirmar que eres tú. Toca para hacerlo.",
    de: "Wir brauchen ein kurzes Selfie, um zu bestätigen, dass du es bist. Tippe, um es aufzunehmen.",
    it: "Ci serve un selfie veloce per confermare che sei tu. Tocca per scattarlo.",
    pt: "Precisamos de uma selfie rápida para confirmar que és tu. Toca para a tirar.",
    nl: "We hebben een snelle selfie nodig om te bevestigen dat jij het bent. Tik om hem te maken.",
  },
  selfieRetry: {
    en: "We couldn't confirm it's you from your selfie. Tap to take a new one.",
    fr: "Ton selfie ne nous a pas permis de confirmer que c'est bien toi. Touche pour en prendre un nouveau.",
    es: "No hemos podido confirmar que eres tú con tu selfie. Toca para hacer otro.",
    de: "Wir konnten mit deinem Selfie nicht bestätigen, dass du es bist. Tippe, um ein neues aufzunehmen.",
    it: "Non siamo riusciti a confermare che sei tu dal tuo selfie. Tocca per scattarne uno nuovo.",
    pt: "Não conseguimos confirmar que és tu com a tua selfie. Toca para tirar uma nova.",
    nl: "We konden met je selfie niet bevestigen dat jij het bent. Tik om een nieuwe te maken.",
  },
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

/**
 * The pieces of a Stream message push (sent by Stream, from the template in scripts/stream-push.ts), kept on
 * each person's Stream user so the push is in their app language: "Maya sent you a message" (NotificationText
 * .message), or with previews on "Maya: See you at 7?" (NotificationText.preview).
 */
export const messageSent: Record<Language, string> = {
  en: "sent you a message",
  fr: "t'a envoyé un message",
  es: "te ha enviado un mensaje",
  de: "hat dir eine Nachricht geschickt",
  it: "ti ha inviato un messaggio",
  pt: "enviou-te uma mensagem",
  nl: "heeft je een bericht gestuurd",
};

/** Between the name and the message text when previews are on ("Maya : …" in French). */
export function previewSeparator(lang: Language): string {
  return lang === "fr" ? "\u00A0: " : ": ";
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

/** NotificationText.reminderEvening: the evening before, with the session's time in the person's zone. */
export function sessionReminderEvening(lang: Language, session: string, at: Date, timeZone: string): string {
  const { time } = sessionTime(lang, at, timeZone);
  return {
    en: `Tomorrow at ${time}: ${session}. Pack your kit tonight.`,
    fr: `Demain à ${time}\u00A0: ${session}. Prépare ton sac ce soir.`,
    es: `Mañana a las ${time}: ${session}. Prepara tu bolsa esta noche.`,
    de: `Morgen um ${time}: ${session}. Pack heute Abend deine Sachen.`,
    it: `Domani alle ${time}: ${session}. Prepara la borsa stasera.`,
    pt: `Amanhã às ${time}: ${session}. Prepara o saco esta noite.`,
    nl: `Morgen om ${time}: ${session}. Pak vanavond je tas in.`,
  }[lang];
}

/** NotificationText.reminderHour. */
export function sessionReminderHour(lang: Language, session: string): string {
  return {
    en: `In an hour: ${session}. See you there!`,
    fr: `Dans une heure\u00A0: ${session}. À tout à l'heure\u00A0!`,
    es: `En una hora: ${session}. ¡Nos vemos allí!`,
    de: `In einer Stunde: ${session}. Bis gleich!`,
    it: `Tra un'ora: ${session}. A dopo!`,
    pt: `Daqui a uma hora: ${session}. Até já!`,
    nl: `Over een uur: ${session}. Tot zo!`,
  }[lang];
}
