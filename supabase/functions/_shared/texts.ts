// Push texts in the app's languages, the same phrases as the app's NotificationText (WORDING.md: casual
// register, European Portuguese, a non-breaking space before ":" and inside « » in French, the brand speaks
// as "on" in French). `profiles.language` picks one.
//
// Every push is a title and a body (WORDING.md, Push): the title is the person's name when someone did
// something (a match, a message, a reaction, a session), otherwise the event ("New like", "In an hour"),
// never "drafft" (iOS already shows the app's name). The body is one sentence with the useful fact, no emoji
// of ours (a reaction carries the person's own), no "!". A body that ends with a session's name has no full
// stop: that name can be the person's own words, a question included ("Easy 8k, then croissants?").
import { sportNames } from "./sports.ts";

export type Language = "en" | "fr" | "es" | "de" | "it" | "pt" | "nl";

const languages: readonly Language[] = ["en", "fr", "es", "de", "it", "pt", "nl"];

/** The person's language from `profiles.language` ("fr", or a tag like "pt-PT"). Anything else: English. */
export function language(value: unknown): Language {
  if (typeof value !== "string") return "en";
  const base = value.trim().toLowerCase().split(/[-_]/)[0];
  return languages.includes(base as Language) ? base as Language : "en";
}

/** What a push shows: its title (a name or the event) and its body. */
export type PushText = { title: string; body: string };

/** A name for someone whose profile has none (or is gone): the title of their push. */
export const someone: Record<Language, string> = {
  en: "Someone",
  fr: "Quelqu'un",
  es: "Alguien",
  de: "Jemand",
  it: "Qualcuno",
  pt: "Alguém",
  nl: "Iemand",
};

/** The title of a push about a person: their name, or `someone` when they have none. */
function who(lang: Language, name: string | null | undefined): string {
  return name?.trim() || someone[lang];
}

/** A like, anonymous on purpose: the Likes tab is where people see who it was. */
export const likeReceived: Record<Language, PushText> = {
  en: { title: "New like", body: "Someone liked your profile." },
  fr: { title: "Nouveau like", body: "Quelqu'un a liké ton profil." },
  es: { title: "Nuevo like", body: "A alguien le ha gustado tu perfil." },
  de: { title: "Neues Like", body: "Jemandem gefällt dein Profil." },
  it: { title: "Nuovo like", body: "Qualcuno ha messo like al tuo profilo." },
  pt: { title: "Novo like", body: "Alguém gostou do teu perfil." },
  nl: { title: "Nieuwe like", body: "Iemand vindt je profiel leuk." },
};

/** A super like, anonymous like a like. */
export const superLikeReceived: Record<Language, PushText> = {
  en: { title: "New super like", body: "Someone sent you a super like." },
  fr: { title: "Nouveau super like", body: "Quelqu'un t'a envoyé un super like." },
  es: { title: "Nuevo superlike", body: "Alguien te ha enviado un superlike." },
  de: { title: "Neuer Super Like", body: "Jemand hat dir einen Super Like geschickt." },
  it: { title: "Nuovo super like", body: "Qualcuno ti ha mandato un super like." },
  pt: { title: "Novo super like", body: "Alguém enviou-te um super like." },
  nl: { title: "Nieuwe superlike", body: "Iemand heeft je een superlike gestuurd." },
};

/** NotificationText .match: "Maya" / "It's mutual: propose a first session." (WORDING.md: never "It's a match"). */
export function matchCreated(lang: Language, name: string | null | undefined): PushText {
  return {
    title: who(lang, name),
    body: {
      en: "It's mutual: propose a first session.",
      fr: "C'est réciproque : propose une première séance.",
      es: "Es mutuo: proponle una primera sesión.",
      de: "Ihr mögt euch beide: Schlag eine erste Session vor.",
      it: "È reciproco: proponi una prima sessione.",
      pt: "É recíproco: propõe uma primeira sessão.",
      nl: "Het is wederzijds: stel een eerste sessie voor.",
    }[lang],
  };
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

/** NotificationText .sessionProposed/.sessionAccepted/.sessionDeclined/.sessionCancelled: "Maya" /
 * "Proposed a session: Padel session". One verb to send one: propose (WORDING.md). */
export function sessionChanged(
  lang: Language,
  change: SessionChange,
  name: string | null | undefined,
  session: string,
): PushText {
  const t = session;
  const body = {
    proposed: {
      en: `Proposed a session: ${t}`,
      fr: `Te propose une séance : ${t}`,
      es: `Te propone una sesión: ${t}`,
      de: `Schlägt dir eine Session vor: ${t}`,
      it: `Ti propone una sessione: ${t}`,
      pt: `Propõe-te uma sessão: ${t}`,
      nl: `Stelt een sessie voor: ${t}`,
    },
    accepted: {
      en: `Confirmed the session: ${t}`,
      fr: `A confirmé la séance : ${t}`,
      es: `Ha confirmado la sesión: ${t}`,
      de: `Hat die Session bestätigt: ${t}`,
      it: `Ha confermato la sessione: ${t}`,
      pt: `Confirmou a sessão: ${t}`,
      nl: `Heeft de sessie bevestigd: ${t}`,
    },
    declined: {
      en: `Can't make it this time: ${t}`,
      fr: `Ne peut pas cette fois-ci : ${t}`,
      es: `Esta vez no puede: ${t}`,
      de: `Kann diesmal nicht: ${t}`,
      it: `Stavolta non può: ${t}`,
      pt: `Desta vez não pode: ${t}`,
      nl: `Kan deze keer niet: ${t}`,
    },
    cancelled: {
      en: `Cancelled the session: ${t}`,
      fr: `A annulé la séance : ${t}`,
      es: `Ha cancelado la sesión: ${t}`,
      de: `Hat die Session abgesagt: ${t}`,
      it: `Ha annullato la sessione: ${t}`,
      pt: `Cancelou a sessão: ${t}`,
      nl: `Heeft de sessie afgezegd: ${t}`,
    },
  }[change][lang];
  return { title: who(lang, name), body };
}

/**
 * The text of a session's card in the chat (a Stream message from whoever acted, `drafft.type: "session"`).
 * English on purpose: it is one message for both people, who may not share a language. The app never shows
 * it (it draws its own card and its own preview from `drafft`); only sophros and Stream's search read it.
 */
export const sessionCard: Record<SessionChange, string> = {
  proposed: "Proposed a session",
  accepted: "Confirmed the session",
  declined: "Declined the session invite",
  cancelled: "Cancelled the session",
};

export const weeklyBoost: Record<Language, PushText> = {
  en: { title: "Your weekly boost", body: "Use it anytime: 30 minutes up front for people near you." },
  fr: {
    title: "Ton boost de la semaine",
    body: "Utilise-le quand tu veux : 30 minutes en tête des profils près de toi.",
  },
  es: {
    title: "Tu boost semanal",
    body: "Úsalo cuando quieras: 30 minutos en primera fila para la gente cerca de ti.",
  },
  de: { title: "Dein Wochen-Boost", body: "Nutz ihn, wann du willst: 30 Minuten ganz vorn bei Leuten in deiner Nähe." },
  it: { title: "Il tuo boost settimanale", body: "Usalo quando vuoi: 30 minuti in cima ai profili vicino a te." },
  pt: { title: "O teu boost semanal", body: "Usa-o quando quiseres: 30 minutos no topo para quem está perto de ti." },
  nl: {
    title: "Je wekelijkse boost",
    body: "Gebruik hem wanneer je wilt: 30 minuten bovenaan bij mensen in de buurt.",
  },
};

/** A photo refused, by Rekognition or by the team (the app's PhotoRefusal screen says why). */
export const photoRefused: Record<Language, PushText> = {
  en: { title: "Photo not approved", body: "See why one of your photos can't go on your profile." },
  fr: { title: "Photo non validée", body: "Découvre pourquoi une de tes photos ne peut pas aller sur ton profil." },
  es: { title: "Foto no aprobada", body: "Mira por qué una de tus fotos no puede ir en tu perfil." },
  de: { title: "Foto nicht freigegeben", body: "Sieh nach, warum eines deiner Fotos nicht in dein Profil kann." },
  it: { title: "Foto non approvata", body: "Scopri perché una delle tue foto non può andare sul tuo profilo." },
  pt: { title: "Foto não aprovada", body: "Vê porque é que uma das tuas fotos não pode ir para o teu perfil." },
  nl: { title: "Foto niet goedgekeurd", body: "Bekijk waarom een van je foto's niet op je profiel kan." },
};

/** Moderation news the person is waiting for: a hold lifted, a selfie asked for, judged. Never a new
 * restriction (review, ban): those are said by the app's own screen, not pushed. */
export type ModerationPush = "restored" | "reopened" | "selfieApproved" | "selfieRequested" | "selfieRetry";

const backInChats: Record<Language, string> = {
  en: "Your profile is visible again, and your chats are where you left them.",
  fr: "Ton profil est de nouveau visible, et tes discussions t'attendent là où tu les as laissées.",
  es: "Tu perfil vuelve a ser visible y tus chats siguen donde los dejaste.",
  de: "Dein Profil ist wieder sichtbar, und deine Chats sind da, wo du sie gelassen hast.",
  it: "Il tuo profilo è di nuovo visibile e le tue chat sono dove le avevi lasciate.",
  pt: "O teu perfil voltou a estar visível e as tuas conversas estão onde as deixaste.",
  nl: "Je profiel is weer zichtbaar en je chats staan waar je ze liet.",
};

const selfieCheck: Record<Language, string> = {
  en: "Selfie check",
  fr: "Vérification par selfie",
  es: "Verificación con selfie",
  de: "Selfie-Check",
  it: "Verifica con selfie",
  pt: "Verificação com selfie",
  nl: "Selfiecheck",
};

export const moderationPush: Record<ModerationPush, Record<Language, PushText>> = {
  // The app's hold screen said "We're checking your account.": this says the check is done.
  restored: {
    en: { title: "Check done", body: backInChats.en },
    fr: { title: "Vérification terminée", body: backInChats.fr },
    es: { title: "Revisión terminada", body: backInChats.es },
    de: { title: "Prüfung abgeschlossen", body: backInChats.de },
    it: { title: "Verifica completata", body: backInChats.it },
    pt: { title: "Verificação concluída", body: backInChats.pt },
    nl: { title: "Controle afgerond", body: backInChats.nl },
  },
  reopened: {
    en: {
      title: "Account reopened",
      body: "We took another look: your account is open and your profile visible again.",
    },
    fr: {
      title: "Compte rouvert",
      body: "On a réexaminé ton compte : il est rouvert et ton profil de nouveau visible.",
    },
    es: {
      title: "Cuenta reabierta",
      body: "Hemos vuelto a revisar tu cuenta: está reabierta y tu perfil vuelve a ser visible.",
    },
    de: {
      title: "Konto wieder offen",
      body: "Wir haben noch einmal hingesehen: Dein Konto ist wieder offen und dein Profil sichtbar.",
    },
    it: {
      title: "Account riaperto",
      body: "Abbiamo ricontrollato: il tuo account è riaperto e il tuo profilo di nuovo visibile.",
    },
    pt: {
      title: "Conta reaberta",
      body: "Voltámos a analisar: a tua conta foi reaberta e o teu perfil voltou a estar visível.",
    },
    nl: {
      title: "Account heropend",
      body: "We hebben opnieuw gekeken: je account is weer open en je profiel zichtbaar.",
    },
  },
  selfieApproved: {
    en: { title: "Selfie verified", body: backInChats.en },
    fr: { title: "Selfie validé", body: backInChats.fr },
    es: { title: "Selfie verificado", body: backInChats.es },
    de: { title: "Selfie bestätigt", body: backInChats.de },
    it: { title: "Selfie verificato", body: backInChats.it },
    pt: { title: "Selfie validada", body: backInChats.pt },
    nl: { title: "Selfie bevestigd", body: backInChats.nl },
  },
  selfieRequested: {
    en: { title: selfieCheck.en, body: "Take a quick selfie so we can confirm it's you." },
    fr: { title: selfieCheck.fr, body: "Prends un selfie rapide pour qu'on confirme que c'est bien toi." },
    es: { title: selfieCheck.es, body: "Hazte un selfie rápido para que confirmemos que eres tú." },
    de: { title: selfieCheck.de, body: "Mach ein kurzes Selfie, damit wir bestätigen können, dass du es bist." },
    it: { title: selfieCheck.it, body: "Scatta un selfie veloce così confermiamo che sei tu." },
    pt: { title: selfieCheck.pt, body: "Tira uma selfie rápida para confirmarmos que és tu." },
    nl: { title: selfieCheck.nl, body: "Maak een snelle selfie zodat we kunnen bevestigen dat jij het bent." },
  },
  selfieRetry: {
    en: { title: selfieCheck.en, body: "We couldn't confirm it's you from that selfie: take a new one." },
    fr: {
      title: selfieCheck.fr,
      body: "On n'a pas pu confirmer que c'est bien toi avec ce selfie : prends-en un nouveau.",
    },
    es: { title: selfieCheck.es, body: "No hemos podido confirmar que eres tú con ese selfie: hazte otro." },
    de: {
      title: selfieCheck.de,
      body: "Mit diesem Selfie konnten wir nicht bestätigen, dass du es bist: Mach bitte ein neues.",
    },
    it: {
      title: selfieCheck.it,
      body: "Con quel selfie non siamo riusciti a confermare che sei tu: scattane un altro.",
    },
    pt: { title: selfieCheck.pt, body: "Com essa selfie não conseguimos confirmar que és tu: tira uma nova." },
    nl: { title: selfieCheck.nl, body: "Met die selfie konden we niet bevestigen dat jij het bent: maak een nieuwe." },
  },
};

/** "Maya" / "Reacted ❤️ to “See you at 7?”", or without the message (previews off, or not text). The emoji
 * is the person's reaction, not ours. */
export function reaction(lang: Language, name: string | null | undefined, emoji: string, text?: string): PushText {
  const title = who(lang, name);
  if (!text) {
    return {
      title,
      body: {
        en: `Reacted ${emoji} to your message.`,
        fr: `A réagi ${emoji} à ton message.`,
        es: `Ha reaccionado con ${emoji} a tu mensaje.`,
        de: `Hat mit ${emoji} auf deine Nachricht reagiert.`,
        it: `Ha reagito con ${emoji} al tuo messaggio.`,
        pt: `Reagiu com ${emoji} à tua mensagem.`,
        nl: `Reageerde met ${emoji} op je bericht.`,
      }[lang],
    };
  }
  const oneLine = text.replace(/\s+/g, " ").trim();
  const t = [...oneLine].length > 60 ? [...oneLine].slice(0, 59).join("").trimEnd() + "…" : oneLine;
  return {
    title,
    body: {
      en: `Reacted ${emoji} to “${t}”`,
      fr: `A réagi ${emoji} à « ${t} »`,
      es: `Ha reaccionado con ${emoji} a «${t}»`,
      de: `Hat mit ${emoji} auf „${t}“ reagiert.`,
      it: `Ha reagito con ${emoji} a «${t}»`,
      pt: `Reagiu com ${emoji} a «${t}»`,
      nl: `Reageerde met ${emoji} op ‘${t}’`,
    }[lang],
  };
}

/**
 * The body of a message push when it doesn't show the text (previews off, or a photo, video or voice
 * message), under the sender's name as the title (NotificationText .message). Stream sends message pushes
 * (template in scripts/stream-push.ts), so this sentence and `someone` are kept on each person's Stream user
 * (`drafft_push`, _shared/stream.ts): the push is in their app language.
 */
export const messageSent: Record<Language, string> = {
  en: "New message.",
  fr: "Nouveau message.",
  es: "Nuevo mensaje.",
  de: "Neue Nachricht.",
  it: "Nuovo messaggio.",
  pt: "Nova mensagem.",
  nl: "Nieuw bericht.",
};

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
export function sessionAutoCancelled(lang: Language, at: Date | null, timeZone: string): PushText {
  const title = {
    en: "Session cancelled",
    fr: "Séance annulée",
    es: "Sesión cancelada",
    de: "Session abgesagt",
    it: "Sessione annullata",
    pt: "Sessão cancelada",
    nl: "Sessie geannuleerd",
  }[lang];
  if (!at) {
    return {
      title,
      body: {
        en: "The session invite no longer stands.",
        fr: "La proposition de séance ne tient plus.",
        es: "La propuesta de sesión ya no sigue en pie.",
        de: "Der Session-Vorschlag gilt nicht mehr.",
        it: "La proposta di sessione non è più valida.",
        pt: "A proposta de sessão já não está de pé.",
        nl: "Het sessievoorstel gaat niet meer door.",
      }[lang],
    };
  }
  const { day, time } = sessionTime(lang, at, timeZone);
  return {
    title,
    body: {
      en: `Your session on ${day} at ${time} won't go ahead.`,
      fr: `Ta séance du ${day} à ${time} n'aura pas lieu.`,
      es: `Tu sesión del ${day} a las ${time} ya no se hace.`,
      de: `Deine Session am ${day} um ${time} findet nicht statt.`,
      it: `La tua sessione di ${day} alle ${time} non si farà.`,
      pt: `A tua sessão de ${day} às ${time} já não vai acontecer.`,
      nl: `Je sessie op ${day} om ${time} gaat niet door.`,
    }[lang],
  };
}

/** "With Maya: Padel session", or the session alone when the other person has no name. */
function withWhom(lang: Language, session: string, name: string | null | undefined): string {
  const n = name?.trim();
  if (!n) return session;
  return {
    en: `With ${n}: ${session}`,
    fr: `Avec ${n} : ${session}`,
    es: `Con ${n}: ${session}`,
    de: `Mit ${n}: ${session}`,
    it: `Con ${n}: ${session}`,
    pt: `Com ${n}: ${session}`,
    nl: `Met ${n}: ${session}`,
  }[lang];
}

/** The evening before: "Tomorrow at 7:00" / "With Maya: Padel session", the time in the person's zone. */
export function sessionReminderEvening(
  lang: Language,
  session: string,
  at: Date,
  timeZone: string,
  name?: string | null,
): PushText {
  const { time } = sessionTime(lang, at, timeZone);
  return {
    title: {
      en: `Tomorrow at ${time}`,
      fr: `Demain à ${time}`,
      es: `Mañana a las ${time}`,
      de: `Morgen um ${time}`,
      it: `Domani alle ${time}`,
      pt: `Amanhã às ${time}`,
      nl: `Morgen om ${time}`,
    }[lang],
    body: withWhom(lang, session, name),
  };
}

/** An hour before: "In an hour" / "With Maya: Padel session". */
export function sessionReminderHour(lang: Language, session: string, name?: string | null): PushText {
  return {
    title: {
      en: "In an hour",
      fr: "Dans une heure",
      es: "Dentro de una hora",
      de: "In einer Stunde",
      it: "Tra un'ora",
      pt: "Daqui a uma hora",
      nl: "Over een uur",
    }[lang],
    body: withWhom(lang, session, name),
  };
}
