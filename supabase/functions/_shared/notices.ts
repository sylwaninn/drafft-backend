// Emails that aren't auth codes: news about the account (a hold lifted, a photo approved or refused on a
// second look) and the acknowledgement of a support request, in the person's language; plus the team's
// copies (SUPPORT_INBOX), in English, until the dashboard lists them. Same layout and register as emails.ts
// (WORDING.md): the subject says the one thing (45 characters at most), the title repeats it, the note is the
// one next step. In French the brand speaks as "on" ("On a revu ta photo"), never "nous" as the subject;
// "l'équipe drafft" only names the team (the support reply's title).
import { codeBox, color, escape, layout, paragraph, type Rendered, small, title } from "./emails.ts";
import type { Language } from "./texts.ts";

export type Notice = "accountRestored" | "accountReopened" | "photoApproved" | "photoRefused" | "supportReceived";

export type Copy = { subject: string; title: string; body: string; note: string };

export const noticeCopy: Record<Notice, Record<Language, Copy>> = {
  // A review or a selfie check, done: nothing wrong. The app's hold screen said "We're checking your account."
  accountRestored: {
    en: {
      subject: "Your account check is done",
      title: "Your account check is done.",
      body: "All good: your profile is visible again, and your matches and chats are still there.",
      note: "Open drafft to pick up where you left off.",
    },
    fr: {
      subject: "La vérification de ton compte est terminée",
      title: "La vérification de ton compte est terminée.",
      body: "Tout est bon\u00A0: ton profil est de nouveau visible, et tes matchs et discussions sont toujours là.",
      note: "Ouvre drafft pour reprendre où tu en étais.",
    },
    es: {
      subject: "Hemos terminado de revisar tu cuenta",
      title: "Hemos terminado de revisar tu cuenta.",
      body: "Todo bien: tu perfil vuelve a ser visible y tus matches y chats siguen ahí.",
      note: "Abre drafft para seguir donde lo dejaste.",
    },
    de: {
      subject: "Wir haben dein Konto fertig geprüft",
      title: "Wir haben dein Konto fertig geprüft.",
      body: "Alles gut: Dein Profil ist wieder sichtbar, und deine Matches und Chats sind noch da.",
      note: "Öffne drafft und mach da weiter, wo du aufgehört hast.",
    },
    it: {
      subject: "Abbiamo finito di verificare il tuo account",
      title: "Abbiamo finito di verificare il tuo account.",
      body: "Tutto a posto: il tuo profilo è di nuovo visibile e i tuoi match e le tue chat sono ancora lì.",
      note: "Apri drafft per riprendere da dove avevi lasciato.",
    },
    pt: {
      subject: "Terminámos a verificação da tua conta",
      title: "Terminámos a verificação da tua conta.",
      body: "Está tudo bem: o teu perfil voltou a estar visível, e os teus matches e conversas continuam lá.",
      note: "Abre o drafft para continuares de onde paraste.",
    },
    nl: {
      subject: "We hebben je account gecontroleerd",
      title: "We hebben je account gecontroleerd.",
      body: "Alles is goed: je profiel is weer zichtbaar, en je matches en chats staan er nog.",
      note: "Open drafft om verder te gaan waar je gebleven was.",
    },
  },
  // A closed account, reopened (the team looked again).
  accountReopened: {
    en: {
      subject: "Your drafft account is reopened",
      title: "Your account is reopened.",
      body: "We took another look at your account. Your profile is visible again, and you can use drafft as before.",
      note: "Open drafft to pick up where you left off.",
    },
    fr: {
      subject: "Ton compte drafft est rouvert",
      title: "Ton compte est rouvert.",
      body: "On a réexaminé ton compte. Ton profil est de nouveau visible et tu peux utiliser drafft comme avant.",
      note: "Ouvre drafft pour reprendre où tu en étais.",
    },
    es: {
      subject: "Tu cuenta de drafft está reabierta",
      title: "Tu cuenta está reabierta.",
      body: "Hemos vuelto a revisar tu cuenta. Tu perfil vuelve a ser visible y puedes usar drafft como antes.",
      note: "Abre drafft para seguir donde lo dejaste.",
    },
    de: {
      subject: "Dein drafft-Konto ist wieder offen",
      title: "Dein Konto ist wieder offen.",
      body:
        "Wir haben dein Konto noch einmal geprüft. Dein Profil ist wieder sichtbar und du kannst drafft wie gewohnt nutzen.",
      note: "Öffne drafft und mach da weiter, wo du aufgehört hast.",
    },
    it: {
      subject: "Il tuo account drafft è di nuovo aperto",
      title: "Il tuo account è di nuovo aperto.",
      body: "Abbiamo riesaminato il tuo account. Il tuo profilo è di nuovo visibile e puoi usare drafft come prima.",
      note: "Apri drafft per riprendere da dove avevi lasciato.",
    },
    pt: {
      subject: "A tua conta drafft foi reaberta",
      title: "A tua conta foi reaberta.",
      body: "Voltámos a analisar a tua conta. O teu perfil voltou a estar visível e podes usar o drafft como antes.",
      note: "Abre o drafft para continuares de onde paraste.",
    },
    nl: {
      subject: "Je drafft-account is heropend",
      title: "Je account is heropend.",
      body:
        "We hebben je account opnieuw bekeken. Je profiel is weer zichtbaar en je kunt drafft gebruiken zoals eerst.",
      note: "Open drafft om verder te gaan waar je gebleven was.",
    },
  },
  // A refused photo, approved after the second look the person asked for.
  photoApproved: {
    en: {
      subject: "Your photo is approved",
      title: "Your photo is approved.",
      body: "We took a second look, as you asked: it's now on your profile.",
      note: "Open drafft to see your profile.",
    },
    fr: {
      subject: "Ta photo est validée",
      title: "Ta photo est validée.",
      body: "On l'a revue, comme tu l'as demandé\u00A0: elle est maintenant sur ton profil.",
      note: "Ouvre drafft pour voir ton profil.",
    },
    es: {
      subject: "Tu foto está aprobada",
      title: "Tu foto está aprobada.",
      body: "La hemos vuelto a revisar, como pediste: ya está en tu perfil.",
      note: "Abre drafft para ver tu perfil.",
    },
    de: {
      subject: "Dein Foto ist freigegeben",
      title: "Dein Foto ist freigegeben.",
      body: "Wir haben es noch einmal geprüft, wie du es wolltest: Es ist jetzt in deinem Profil.",
      note: "Öffne drafft, um dein Profil zu sehen.",
    },
    it: {
      subject: "La tua foto è approvata",
      title: "La tua foto è approvata.",
      body: "L'abbiamo ricontrollata, come hai chiesto: ora è sul tuo profilo.",
      note: "Apri drafft per vedere il tuo profilo.",
    },
    pt: {
      subject: "A tua foto foi aprovada",
      title: "A tua foto foi aprovada.",
      body: "Voltámos a vê-la, como pediste: já está no teu perfil.",
      note: "Abre o drafft para veres o teu perfil.",
    },
    nl: {
      subject: "Je foto is goedgekeurd",
      title: "Je foto is goedgekeurd.",
      body: "We hebben hem opnieuw bekeken, zoals je vroeg: hij staat nu op je profiel.",
      note: "Open drafft om je profiel te bekijken.",
    },
  },
  // A refused photo, refused again after the second look the person asked for.
  photoRefused: {
    en: {
      subject: "Your photo can't go on your profile",
      title: "Your photo can't go on your profile.",
      body:
        "We took a second look, as you asked: it doesn't fit the drafft photo guidelines, so it stays off your profile.",
      note: "You can add another photo anytime in drafft.",
    },
    fr: {
      subject: "Ta photo ne peut pas aller sur ton profil",
      title: "Ta photo ne peut pas aller sur ton profil.",
      body:
        "On l'a revue, comme tu l'as demandé\u00A0: elle ne respecte pas les règles photo de drafft, elle reste donc hors de ton profil.",
      note: "Tu peux ajouter une autre photo quand tu veux dans drafft.",
    },
    es: {
      subject: "Tu foto no puede ir en tu perfil",
      title: "Tu foto no puede ir en tu perfil.",
      body:
        "La hemos vuelto a revisar, como pediste: no cumple las normas de fotos de drafft, así que se queda fuera de tu perfil.",
      note: "Puedes añadir otra foto cuando quieras en drafft.",
    },
    de: {
      subject: "Dein Foto kann nicht in dein Profil",
      title: "Dein Foto kann nicht in dein Profil.",
      body:
        "Wir haben es noch einmal geprüft, wie du es wolltest: Es entspricht nicht den Foto-Richtlinien von drafft und kommt deshalb nicht in dein Profil.",
      note: "Du kannst in drafft jederzeit ein anderes Foto hinzufügen.",
    },
    it: {
      subject: "La tua foto non può andare sul profilo",
      title: "La tua foto non può andare sul profilo.",
      body:
        "L'abbiamo ricontrollata, come hai chiesto: non rispetta le regole sulle foto di drafft, quindi resta fuori dal tuo profilo.",
      note: "Puoi aggiungere un'altra foto quando vuoi su drafft.",
    },
    pt: {
      subject: "A tua foto não pode ir para o perfil",
      title: "A tua foto não pode ir para o perfil.",
      body:
        "Voltámos a vê-la, como pediste: não cumpre as regras de fotos do drafft, por isso fica fora do teu perfil.",
      note: "Podes adicionar outra foto quando quiseres no drafft.",
    },
    nl: {
      subject: "Je foto kan niet op je profiel",
      title: "Je foto kan niet op je profiel.",
      body:
        "We hebben hem opnieuw bekeken, zoals je vroeg: hij voldoet niet aan de fotoregels van drafft en komt daarom niet op je profiel.",
      note: "Je kunt in drafft altijd een andere foto toevoegen.",
    },
  },
  // A support request, received: its reference follows the body. Fixed text, nothing the form typed: the
  // signed-out form mails any address, so it must not carry someone else's words.
  supportReceived: {
    en: {
      subject: "We got your message",
      title: "We got your message.",
      body: "We'll reply to this address, usually within 2 working days. Your reference:",
      note: "Mention it if you write to us again.",
    },
    fr: {
      subject: "On a bien reçu ton message",
      title: "On a bien reçu ton message.",
      body: "On te répond à cette adresse, en général sous 2\u00A0jours ouvrés. Ta référence\u00A0:",
      note: "Indique-la si tu nous réécris.",
    },
    es: {
      subject: "Hemos recibido tu mensaje",
      title: "Hemos recibido tu mensaje.",
      body: "Te responderemos a esta dirección, normalmente en 2 días laborables. Tu referencia:",
      note: "Inclúyela si vuelves a escribirnos.",
    },
    de: {
      subject: "Wir haben deine Nachricht erhalten",
      title: "Wir haben deine Nachricht erhalten.",
      body: "Wir antworten dir an diese Adresse, meist innerhalb von 2 Werktagen. Deine Referenz:",
      note: "Gib sie an, wenn du uns noch einmal schreibst.",
    },
    it: {
      subject: "Abbiamo ricevuto il tuo messaggio",
      title: "Abbiamo ricevuto il tuo messaggio.",
      body: "Ti risponderemo a questo indirizzo, di solito entro 2 giorni lavorativi. Il tuo riferimento:",
      note: "Indicalo se ci scrivi di nuovo.",
    },
    pt: {
      subject: "Recebemos a tua mensagem",
      title: "Recebemos a tua mensagem.",
      body: "Vamos responder para este endereço, normalmente em 2 dias úteis. A tua referência:",
      note: "Indica-a se nos voltares a escrever.",
    },
    nl: {
      subject: "We hebben je bericht ontvangen",
      title: "We hebben je bericht ontvangen.",
      body: "We antwoorden naar dit adres, meestal binnen 2 werkdagen. Je referentie:",
      note: "Vermeld hem als je ons opnieuw schrijft.",
    },
  },
};

/** `reference`: the support acknowledgement only. */
export function renderNotice(kind: Notice, lang: Language, vars: { reference?: string } = {}): Rendered {
  const c = noticeCopy[kind][lang];
  const body = c.body;
  const rows = [title(c.title), paragraph(escape(c.body))];
  if (vars.reference) rows.push(`<tr><td style="padding-bottom:24px">${codeBox(vars.reference)}</td></tr>`);
  rows.push(small(c.note, color.mute));
  const text = [c.title, "", body, ...(vars.reference ? ["", vars.reference] : []), "", c.note].join("\n");
  return { subject: c.subject, html: layout(lang, c.subject, rows), text };
}

// A reply from the team (sophros), framed in the person's language; the reply itself is as written.
export const supportReplyCopy: Record<Language, { title: string; intro: string; yours: string; note: string }> = {
  en: {
    title: "A reply from the drafft team.",
    intro: "Topic: {topic}",
    yours: "Your message",
    note: "Reply to this email to write back. Your reference:",
  },
  fr: {
    title: "Une réponse de l'équipe drafft.",
    intro: "Sujet\u00A0: {topic}",
    yours: "Ton message",
    note: "Réponds à cet e-mail pour nous écrire. Ta référence\u00A0:",
  },
  es: {
    title: "Una respuesta del equipo de drafft.",
    intro: "Tema: {topic}",
    yours: "Tu mensaje",
    note: "Responde a este correo para escribirnos. Tu referencia:",
  },
  de: {
    title: "Eine Antwort vom drafft-Team.",
    intro: "Thema: {topic}",
    yours: "Deine Nachricht",
    note: "Antworte auf diese E-Mail, um uns zu schreiben. Deine Referenz:",
  },
  it: {
    title: "Una risposta dal team di drafft.",
    intro: "Argomento: {topic}",
    yours: "Il tuo messaggio",
    note: "Rispondi a questa email per scriverci. Il tuo riferimento:",
  },
  pt: {
    title: "Uma resposta da equipa drafft.",
    intro: "Assunto: {topic}",
    yours: "A tua mensagem",
    note: "Responde a este email para nos escreveres. A tua referência:",
  },
  nl: {
    title: "Een antwoord van het drafft-team.",
    intro: "Onderwerp: {topic}",
    yours: "Je bericht",
    note: "Beantwoord deze e-mail om ons te schrijven. Je referentie:",
  },
};

/** Like small(), for markup already escaped. */
function muted(html: string): string {
  return `<tr><td style="font-size:14px;line-height:20px;color:${color.mute};padding-bottom:16px">${html}</td></tr>`;
}

export function renderSupportReply(
  lang: Language,
  vars: { reference: string; topic: string; body: string; message: string },
): Rendered {
  const c = supportReplyCopy[lang];
  const subject = `Re: ${vars.topic} [${vars.reference}]`;
  const rows = [
    title(c.title),
    muted(escape(c.intro).replace("{topic}", `<strong>${escape(vars.topic)}</strong>`)),
    paragraph(escape(vars.body).replace(/\n/g, "<br>")),
    muted(`${escape(c.yours)}<br>${escape(vars.message).replace(/\n/g, "<br>")}`),
    small(c.note, color.mute),
    `<tr><td style="padding-bottom:24px">${codeBox(vars.reference)}</td></tr>`,
  ];
  const text = [
    c.title,
    "",
    c.intro.replace("{topic}", vars.topic),
    "",
    vars.body,
    "",
    `${c.yours}${lang === "fr" ? "\u00A0:" : ":"}`,
    vars.message,
    "",
    c.note,
    vars.reference,
  ].join("\n");
  return { subject, html: layout(lang, subject, rows), text };
}

/** The team's copy: a subject and labelled lines, in English. */
export function renderTeamEmail(subject: string, lines: [string, string][]): Rendered {
  const html = layout("en", subject, [
    title(subject),
    ...lines.map(([label, value]) =>
      paragraph(`<strong>${escape(label)}</strong><br>${escape(value).replace(/\n/g, "<br>")}`)
    ),
  ]);
  const text = [subject, "", ...lines.map(([label, value]) => `${label}:\n${value}\n`)].join("\n");
  return { subject, html, text };
}
