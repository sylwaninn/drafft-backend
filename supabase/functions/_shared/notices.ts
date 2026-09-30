// Emails that aren't auth codes: news about the account (a hold lifted, a photo approved or refused on a
// second look), the acknowledgement of a support request and a data export's link, in the person's language;
// plus the team's copies (SUPPORT_INBOX), in English, until the dashboard lists them. Same layout and register
// as emails.ts (WORDING.md): the subject says the one thing (45 characters at most), the title repeats it, the
// note is the one next step. In French the brand speaks as "on" ("On a revu ta photo"), never "nous" as the subject;
// "l'équipe drafft" only names the team (the support reply's title).
import { codeBox, color, escape, layout, paragraph, type Rendered, small, title } from "./emails.ts";
import type { Language } from "./texts.ts";

export type Notice =
  | "accountRestored"
  | "accountReopened"
  | "photoApproved"
  | "photoRefused"
  | "supportReceived"
  | "exportReady";

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
  // A data export, built: the link follows the body, one per part when it has several (renderExportReady).
  // "Export" as the app says it (You › Privacy & data › Export my data); a reply reaches the team (Reply-To
  // SUPPORT_INBOX).
  exportReady: {
    en: {
      subject: "Your drafft export is ready",
      title: "Your export is ready.",
      body:
        "Your drafft data is in one file: your account, profile, activity and messages, with your photos, videos and voice intro.",
      note: "The link works for 7 days. Didn't ask for it? Reply to this email.",
    },
    fr: {
      subject: "Ton export drafft est prêt",
      title: "Ton export est prêt.",
      body:
        "Tes données drafft tiennent dans un fichier\u00A0: ton compte, ton profil, ton activité et tes messages, avec tes photos, tes vidéos et ta présentation vocale.",
      note: "Le lien est valable 7\u00A0jours. Tu n'as rien demandé\u00A0? Réponds à cet e-mail.",
    },
    es: {
      subject: "Tu exportación de drafft está lista",
      title: "Tu exportación está lista.",
      body:
        "Tus datos de drafft están en un archivo: tu cuenta, tu perfil, tu actividad y tus mensajes, con tus fotos, tus vídeos y tu presentación de voz.",
      note: "El enlace vale durante 7 días. ¿No lo has pedido tú? Responde a este correo.",
    },
    de: {
      subject: "Dein drafft-Export ist bereit",
      title: "Dein Export ist bereit.",
      body:
        "Deine drafft-Daten stecken in einer Datei: dein Konto, dein Profil, deine Aktivität und deine Nachrichten, mit deinen Fotos, Videos und deinem Sprach-Intro.",
      note: "Der Link gilt 7 Tage. Du hast das nicht angefordert? Antworte auf diese E-Mail.",
    },
    it: {
      subject: "I tuoi dati drafft sono pronti",
      title: "I tuoi dati sono pronti.",
      body:
        "I tuoi dati drafft sono in un unico file: account, profilo, attività e messaggi, con le tue foto, i tuoi video e la tua presentazione vocale.",
      note: "Il link è valido per 7 giorni. Non l'hai chiesto tu? Rispondi a questa email.",
    },
    pt: {
      subject: "A tua exportação drafft está pronta",
      title: "A tua exportação está pronta.",
      body:
        "Os teus dados drafft estão num só ficheiro: a tua conta, o teu perfil, a tua atividade e as tuas mensagens, com as tuas fotos, os teus vídeos e a tua apresentação de voz.",
      note: "O link é válido durante 7 dias. Não pediste isto? Responde a este email.",
    },
    nl: {
      subject: "Je drafft-export staat klaar",
      title: "Je export staat klaar.",
      body:
        "Je drafft-gegevens staan in één bestand: je account, je profiel, je activiteit en je berichten, met je foto's, video's en je spraakintro.",
      note: "De link is 7 dagen geldig. Niet aangevraagd? Beantwoord deze e-mail.",
    },
  },
};

/** The one button of the export email. */
export const exportCta: Record<Language, string> = {
  en: "Download my data",
  fr: "Télécharger mes données",
  es: "Descargar mis datos",
  de: "Daten herunterladen",
  it: "Scarica i miei dati",
  pt: "Descarregar os dados",
  nl: "Gegevens downloaden",
};

// An export too heavy for one file (export.ts: parts of 45 MiB at most): the same email, with the number of files
// in the body, one button for part 1 (WORDING.md: one CTA) and the other parts as plain links under `others`, the
// links in the plural. `{count}`: the parts, 2 or more; `{n}`: a part's number. The subject and title stay those of
// noticeCopy.exportReady.
export const exportPartsCopy: Record<
  Language,
  { body: string; cta: string; others: string; part: string; note: string }
> = {
  en: {
    body:
      "Your drafft data is in {count} files: your account, profile, activity and messages, with your photos, videos and voice intro.",
    cta: "Download part 1",
    others: "Other parts",
    part: "Part {n}",
    note: "The links work for 7 days. Didn't ask for it? Reply to this email.",
  },
  fr: {
    body:
      "Tes données drafft tiennent dans {count}\u00A0fichiers\u00A0: ton compte, ton profil, ton activité et tes messages, avec tes photos, tes vidéos et ta présentation vocale.",
    cta: "Télécharger la partie 1",
    others: "Les autres parties",
    part: "Partie {n}",
    note: "Les liens sont valables 7\u00A0jours. Tu n'as rien demandé\u00A0? Réponds à cet e-mail.",
  },
  es: {
    body:
      "Tus datos de drafft están en {count} archivos: tu cuenta, tu perfil, tu actividad y tus mensajes, con tus fotos, tus vídeos y tu presentación de voz.",
    cta: "Descargar la parte 1",
    others: "Las otras partes",
    part: "Parte {n}",
    note: "Los enlaces valen durante 7 días. ¿No lo has pedido tú? Responde a este correo.",
  },
  de: {
    body:
      "Deine drafft-Daten stecken in {count} Dateien: dein Konto, dein Profil, deine Aktivität und deine Nachrichten, mit deinen Fotos, Videos und deinem Sprach-Intro.",
    cta: "Teil 1 herunterladen",
    others: "Die anderen Teile",
    part: "Teil {n}",
    note: "Die Links gelten 7 Tage. Du hast das nicht angefordert? Antworte auf diese E-Mail.",
  },
  it: {
    body:
      "I tuoi dati drafft sono in {count} file: account, profilo, attività e messaggi, con le tue foto, i tuoi video e la tua presentazione vocale.",
    cta: "Scarica la parte 1",
    others: "Le altre parti",
    part: "Parte {n}",
    note: "I link sono validi per 7 giorni. Non l'hai chiesto tu? Rispondi a questa email.",
  },
  pt: {
    body:
      "Os teus dados drafft estão em {count} ficheiros: a tua conta, o teu perfil, a tua atividade e as tuas mensagens, com as tuas fotos, os teus vídeos e a tua apresentação de voz.",
    cta: "Descarregar a parte 1",
    others: "As outras partes",
    part: "Parte {n}",
    note: "Os links são válidos durante 7 dias. Não pediste isto? Responde a este email.",
  },
  nl: {
    body:
      "Je drafft-gegevens staan in {count} bestanden: je account, je profiel, je activiteit en je berichten, met je foto's, video's en je spraakintro.",
    cta: "Deel 1 downloaden",
    others: "De andere delen",
    part: "Deel {n}",
    note: "De links zijn 7 dagen geldig. Niet aangevraagd? Beantwoord deze e-mail.",
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

/** The export email: one button (part 1 when there are several), the other parts as plain links under it, each
 * link on its own line in the text part, then the note. */
export function renderExportReady(lang: Language, links: string[]): Rendered {
  const c = noticeCopy.exportReady[lang];
  const several = links.length > 1 ? exportPartsCopy[lang] : null;
  const body = several ? several.body.replace("{count}", String(links.length)) : c.body;
  const note = several?.note ?? c.note;
  const cta = several?.cta ?? exportCta[lang];
  const rows = [
    title(c.title),
    paragraph(escape(body)),
    `<tr><td style="padding-bottom:24px"><a href="${escape(links[0])}" style="display:inline-block;` +
    `background:${color.primary};color:${color.ink};font-size:16px;font-weight:700;text-decoration:none;` +
    `padding:14px 24px;border-radius:16px">${escape(cta)}</a></td></tr>`,
  ];
  const text = [c.title, "", body, "", cta, links[0], ""];
  if (several) {
    // Part 2 onwards, as plain links.
    const others = links.slice(1).map((link, i) => ({ link, label: several.part.replace("{n}", String(i + 2)) }));
    const anchors = others.map((o) => `<a href="${escape(o.link)}" style="color:${color.ink}">${escape(o.label)}</a>`);
    rows.push(paragraph(`${escape(several.others)}<br>${anchors.join("<br>")}`));
    text.push(several.others, ...others.flatMap((o) => [o.label, o.link]), "");
  }
  rows.push(small(note, color.mute));
  text.push(note);
  return { subject: c.subject, html: layout(lang, c.subject, rows), text: text.join("\n") };
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
