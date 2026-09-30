// Emails that aren't auth codes: news about the account (a hold lifted, a photo approved on a second look, a
// decision by the team with its statement of reasons), the acknowledgement of a support request and a data export's link, in the person's language;
// plus the team's copies (SUPPORT_INBOX), in English, until the dashboard lists them. Same layout and register as emails.ts
// (WORDING.md): the subject says the one thing (45 characters at most, the acknowledgement's reference included), the title repeats it, the note is the
// one next step. In French the brand speaks as "on" ("On a revu ta photo"), never "nous" as the subject;
// "l'équipe drafft" only names the team (the support reply's title).
import { codeBox, color, escape, layout, paragraph, type Rendered, small, title } from "./emails.ts";
import type { Language } from "./texts.ts";

export type Notice =
  | "accountRestored"
  | "accountReopened"
  | "photoApproved"
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
  // A support request, received: its reference follows the body and ends the subject (renderNotice), so the
  // subject here keeps to 33 characters. Fixed text, nothing the form typed: the signed-out form mails any
  // address, so it must not carry someone else's words. A reply goes to the support address (support-inbound).
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
      subject: "Deine Nachricht ist angekommen",
      title: "Deine Nachricht ist angekommen.",
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
  // A data export, built: the link follows the body, one per part when it has several (renderExportReady). "Export" as the app says it (You ›
  // Privacy & data › Export my data); a reply reaches the team (Reply-To the support address).
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

/** `reference`: the support acknowledgement only. It ends the subject too ("We got your message [DR-ABC123]"):
 * a reply keeps it, and the support mail Worker files the reply in its request by it. */
export function renderNotice(kind: Notice, lang: Language, vars: { reference?: string } = {}): Rendered {
  const c = noticeCopy[kind][lang];
  const body = c.body;
  const subject = vars.reference ? `${c.subject} [${vars.reference}]` : c.subject;
  const rows = [title(c.title), paragraph(escape(c.body))];
  if (vars.reference) rows.push(`<tr><td style="padding-bottom:24px">${codeBox(vars.reference)}</td></tr>`);
  rows.push(small(c.note, color.mute));
  const text = [c.title, "", body, ...(vars.reference ? ["", vars.reference] : []), "", c.note].join("\n");
  return { subject, html: layout(lang, subject, rows), text };
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

// MARK: Statements of reasons

// A decision by a person on the team about a member (DSA art. 17): what was decided, why (a category from
// private.reason_categories, and the team's note when they wrote one, sent as written), the rule it applies,
// and how to contest it. Sent by db-events (`moderation.decision`) with Reply-To the support address.
export type Decision = "photo_refused" | "message_deleted" | "account_review" | "account_selfie" | "account_banned";

export const decisionCopy: Record<Decision, Record<Language, { subject: string; title: string; body: string }>> = {
  photo_refused: {
    en: {
      subject: "A photo can't go on your profile",
      title: "A photo can't go on your profile.",
      body: "A person on the drafft team looked at one of your photos and refused it.",
    },
    fr: {
      subject: "Une photo ne peut pas aller sur ton profil",
      title: "Une photo ne peut pas aller sur ton profil.",
      body: "Quelqu'un de l'équipe a examiné une de tes photos et l'a refusée.",
    },
    es: {
      subject: "Una foto no puede ir en tu perfil",
      title: "Una foto no puede ir en tu perfil.",
      body: "Una persona del equipo de drafft ha revisado una de tus fotos y la ha rechazado.",
    },
    de: {
      subject: "Ein Foto kann nicht in dein Profil",
      title: "Ein Foto kann nicht in dein Profil.",
      body: "Eine Person aus dem drafft-Team hat eines deiner Fotos geprüft und abgelehnt.",
    },
    it: {
      subject: "Una foto non può andare sul tuo profilo",
      title: "Una foto non può andare sul tuo profilo.",
      body: "Una persona del team di drafft ha esaminato una delle tue foto e l'ha rifiutata.",
    },
    pt: {
      subject: "Uma foto não pode ir para o teu perfil",
      title: "Uma foto não pode ir para o teu perfil.",
      body: "Uma pessoa da equipa drafft analisou uma das tuas fotos e recusou-a.",
    },
    nl: {
      subject: "Een foto kan niet op je profiel",
      title: "Een foto kan niet op je profiel.",
      body: "Iemand van het drafft-team heeft een van je foto's bekeken en afgewezen.",
    },
  },
  message_deleted: {
    en: {
      subject: "We removed one of your messages",
      title: "We removed one of your messages.",
      body: "A person on the drafft team removed one of your messages in a chat.",
    },
    fr: {
      subject: "On a supprimé un de tes messages",
      title: "On a supprimé un de tes messages.",
      body: "Quelqu'un de l'équipe a supprimé un de tes messages dans une discussion.",
    },
    es: {
      subject: "Hemos eliminado uno de tus mensajes",
      title: "Hemos eliminado uno de tus mensajes.",
      body: "Una persona del equipo de drafft ha eliminado uno de tus mensajes en un chat.",
    },
    de: {
      subject: "Wir haben eine deiner Nachrichten entfernt",
      title: "Wir haben eine deiner Nachrichten entfernt.",
      body: "Eine Person aus dem drafft-Team hat eine deiner Nachrichten in einem Chat entfernt.",
    },
    it: {
      subject: "Abbiamo rimosso un tuo messaggio",
      title: "Abbiamo rimosso un tuo messaggio.",
      body: "Una persona del team di drafft ha rimosso un tuo messaggio in una chat.",
    },
    pt: {
      subject: "Removemos uma das tuas mensagens",
      title: "Removemos uma das tuas mensagens.",
      body: "Uma pessoa da equipa drafft removeu uma das tuas mensagens numa conversa.",
    },
    nl: {
      subject: "We hebben een bericht van je verwijderd",
      title: "We hebben een bericht van je verwijderd.",
      body: "Iemand van het drafft-team heeft een van je berichten in een chat verwijderd.",
    },
  },
  account_review: {
    en: {
      subject: "We're checking your account",
      title: "We're checking your account.",
      body: "Until a person on the drafft team has checked it, your profile is hidden and your chats are read-only.",
    },
    fr: {
      subject: "On vérifie ton compte",
      title: "On vérifie ton compte.",
      body:
        "Jusqu'à ce que quelqu'un de l'équipe l'ait vérifié, ton profil est masqué et tes discussions sont en lecture seule.",
    },
    es: {
      subject: "Estamos revisando tu cuenta",
      title: "Estamos revisando tu cuenta.",
      body:
        "Hasta que una persona del equipo de drafft la revise, tu perfil está oculto y tus chats son de solo lectura.",
    },
    de: {
      subject: "Wir prüfen dein Konto",
      title: "Wir prüfen dein Konto.",
      body:
        "Bis eine Person aus dem drafft-Team es geprüft hat, ist dein Profil verborgen und deine Chats sind schreibgeschützt.",
    },
    it: {
      subject: "Stiamo verificando il tuo account",
      title: "Stiamo verificando il tuo account.",
      body:
        "Finché una persona del team di drafft non l'avrà verificato, il tuo profilo è nascosto e le chat sono in sola lettura.",
    },
    pt: {
      subject: "Estamos a verificar a tua conta",
      title: "Estamos a verificar a tua conta.",
      body:
        "Até uma pessoa da equipa drafft a verificar, o teu perfil fica oculto e as tuas conversas ficam só de leitura.",
    },
    nl: {
      subject: "We controleren je account",
      title: "We controleren je account.",
      body:
        "Tot iemand van het drafft-team het heeft gecontroleerd, is je profiel verborgen en kun je je chats alleen lezen.",
    },
  },
  account_selfie: {
    en: {
      subject: "We need a selfie to check your account",
      title: "We need a selfie to check your account.",
      body: "Until you send it, your profile is hidden and your chats are read-only. Open drafft to take it.",
    },
    fr: {
      subject: "On a besoin d'un selfie pour ton compte",
      title: "On a besoin d'un selfie pour ton compte.",
      body:
        "Tant que tu ne l'as pas envoyé, ton profil est masqué et tes discussions sont en lecture seule. Ouvre drafft pour le prendre.",
    },
    es: {
      subject: "Necesitamos un selfie para tu cuenta",
      title: "Necesitamos un selfie para tu cuenta.",
      body: "Hasta que lo envíes, tu perfil está oculto y tus chats son de solo lectura. Abre drafft para hacerlo.",
    },
    de: {
      subject: "Wir brauchen ein Selfie für dein Konto",
      title: "Wir brauchen ein Selfie für dein Konto.",
      body:
        "Bis du es schickst, ist dein Profil verborgen und deine Chats sind schreibgeschützt. Öffne drafft, um es aufzunehmen.",
    },
    it: {
      subject: "Ci serve un selfie per il tuo account",
      title: "Ci serve un selfie per il tuo account.",
      body: "Finché non lo invii, il tuo profilo è nascosto e le chat sono in sola lettura. Apri drafft per scattarlo.",
    },
    pt: {
      subject: "Precisamos de uma selfie para a tua conta",
      title: "Precisamos de uma selfie para a tua conta.",
      body:
        "Até a enviares, o teu perfil fica oculto e as tuas conversas ficam só de leitura. Abre o drafft para a tirar.",
    },
    nl: {
      subject: "We hebben een selfie van je nodig",
      title: "We hebben een selfie van je nodig.",
      body: "Tot je hem stuurt, is je profiel verborgen en kun je je chats alleen lezen. Open drafft om hem te maken.",
    },
  },
  account_banned: {
    en: {
      subject: "Your drafft account is closed",
      title: "Your account is closed.",
      body:
        "A person on the drafft team closed your account for good: your profile is hidden and you can't sign up again.",
    },
    fr: {
      subject: "Ton compte drafft est fermé",
      title: "Ton compte est fermé.",
      body:
        "Quelqu'un de l'équipe a fermé ton compte définitivement\u00A0: ton profil est masqué et tu ne peux plus t'inscrire à nouveau.",
    },
    es: {
      subject: "Tu cuenta de drafft está cerrada",
      title: "Tu cuenta está cerrada.",
      body:
        "Una persona del equipo de drafft ha cerrado tu cuenta de forma definitiva: tu perfil está oculto y no puedes volver a registrarte.",
    },
    de: {
      subject: "Dein drafft-Konto ist geschlossen",
      title: "Dein Konto ist geschlossen.",
      body:
        "Eine Person aus dem drafft-Team hat dein Konto dauerhaft geschlossen: Dein Profil ist verborgen und du kannst dich nicht neu registrieren.",
    },
    it: {
      subject: "Il tuo account drafft è chiuso",
      title: "Il tuo account è chiuso.",
      body:
        "Una persona del team di drafft ha chiuso il tuo account in modo definitivo: il tuo profilo è nascosto e non puoi registrarti di nuovo.",
    },
    pt: {
      subject: "A tua conta drafft foi encerrada",
      title: "A tua conta foi encerrada.",
      body:
        "Uma pessoa da equipa drafft encerrou a tua conta de vez: o teu perfil fica oculto e não te podes registar de novo.",
    },
    nl: {
      subject: "Je drafft-account is gesloten",
      title: "Je account is gesloten.",
      body:
        "Iemand van het drafft-team heeft je account definitief gesloten: je profiel is verborgen en je kunt je niet opnieuw aanmelden.",
    },
  },
};

/** The reason categories of private.reason_categories, as the member reads them after "Why:". */
export type ReasonCategory =
  | "harassment"
  | "hate"
  | "sexual_content"
  | "violence_illegal"
  | "underage"
  | "impersonation"
  | "scam_commercial"
  | "privacy"
  | "fake_account"
  | "evasion"
  | "photo_guidelines"
  | "identity_check"
  | "other";

export const reasonCopy: Record<ReasonCategory, Record<Language, string>> = {
  harassment: {
    en: "harassing, threatening or insulting someone",
    fr: "harceler, menacer ou insulter quelqu'un",
    es: "acosar, amenazar o insultar a alguien",
    de: "jemanden belästigen, bedrohen oder beleidigen",
    it: "molestare, minacciare o insultare qualcuno",
    pt: "assediar, ameaçar ou insultar alguém",
    nl: "iemand lastigvallen, bedreigen of beledigen",
  },
  hate: {
    en: "hateful or discriminatory content",
    fr: "un contenu haineux ou discriminatoire",
    es: "contenido de odio o discriminatorio",
    de: "hasserfüllte oder diskriminierende Inhalte",
    it: "contenuti d'odio o discriminatori",
    pt: "conteúdo de ódio ou discriminatório",
    nl: "haatdragende of discriminerende inhoud",
  },
  sexual_content: {
    en: "sexual content or nudity",
    fr: "un contenu sexuel ou de la nudité",
    es: "contenido sexual o desnudos",
    de: "sexuelle Inhalte oder Nacktheit",
    it: "contenuti sessuali o nudità",
    pt: "conteúdo sexual ou nudez",
    nl: "seksuele inhoud of naakt",
  },
  violence_illegal: {
    en: "violent or illegal content",
    fr: "un contenu violent ou illégal",
    es: "contenido violento o ilegal",
    de: "gewalttätige oder illegale Inhalte",
    it: "contenuti violenti o illegali",
    pt: "conteúdo violento ou ilegal",
    nl: "gewelddadige of illegale inhoud",
  },
  underage: {
    en: "drafft is only for people aged 18 or over",
    fr: "drafft est réservé aux personnes de 18\u00A0ans ou plus",
    es: "drafft es solo para mayores de 18 años",
    de: "drafft ist nur für Menschen ab 18",
    it: "drafft è solo per chi ha almeno 18 anni",
    pt: "o drafft é só para maiores de 18 anos",
    nl: "drafft is alleen voor mensen van 18 of ouder",
  },
  impersonation: {
    en: "pretending to be someone else, or using someone else's photos",
    fr: "se faire passer pour quelqu'un d'autre, ou utiliser ses photos",
    es: "hacerse pasar por otra persona o usar sus fotos",
    de: "sich als jemand anderes ausgeben oder fremde Fotos nutzen",
    it: "fingersi un'altra persona o usare le sue foto",
    pt: "fazer-se passar por outra pessoa ou usar as fotos dela",
    nl: "je voordoen als iemand anders of andermans foto's gebruiken",
  },
  scam_commercial: {
    en: "a scam, selling or advertising, or asking for money",
    fr: "une arnaque, de la vente ou de la publicité, ou une demande d'argent",
    es: "una estafa, vender o anunciar algo, o pedir dinero",
    de: "Betrug, Verkauf oder Werbung, oder Bitten um Geld",
    it: "una truffa, vendite o pubblicità, o richieste di denaro",
    pt: "uma burla, vendas ou publicidade, ou pedidos de dinheiro",
    nl: "oplichting, verkoop of reclame, of vragen om geld",
  },
  privacy: {
    en: "sharing someone's personal information or messages without their consent",
    fr: "partager les informations personnelles ou les messages de quelqu'un sans son accord",
    es: "compartir información personal o mensajes de alguien sin su consentimiento",
    de: "persönliche Daten oder Nachrichten von jemandem ohne Zustimmung teilen",
    it: "condividere informazioni personali o messaggi di qualcuno senza il suo consenso",
    pt: "partilhar informações pessoais ou mensagens de alguém sem consentimento",
    nl: "iemands persoonlijke gegevens of berichten delen zonder toestemming",
  },
  fake_account: {
    en: "a fake account, several accounts, or automated use",
    fr: "un faux compte, plusieurs comptes ou une utilisation automatisée",
    es: "una cuenta falsa, varias cuentas o un uso automatizado",
    de: "ein Fake-Konto, mehrere Konten oder automatisierte Nutzung",
    it: "un account falso, più account o un uso automatizzato",
    pt: "uma conta falsa, várias contas ou uma utilização automatizada",
    nl: "een nepaccount, meerdere accounts of geautomatiseerd gebruik",
  },
  evasion: {
    en: "getting around a restriction, a block or a ban",
    fr: "contourner une restriction, un blocage ou un bannissement",
    es: "saltarse una restricción, un bloqueo o una expulsión",
    de: "eine Einschränkung, Blockierung oder Sperre umgehen",
    it: "aggirare una restrizione, un blocco o un ban",
    pt: "contornar uma restrição, um bloqueio ou uma expulsão",
    nl: "een beperking, blokkering of ban omzeilen",
  },
  photo_guidelines: {
    en: "the photo breaks the community guidelines on profile photos",
    fr: "la photo ne respecte pas les règles de la communauté sur les photos de profil",
    es: "la foto no cumple las normas de la comunidad sobre las fotos de perfil",
    de: "das Foto verstößt gegen die Community-Regeln für Profilfotos",
    it: "la foto non rispetta le regole della community sulle foto del profilo",
    pt: "a foto não cumpre as regras da comunidade sobre fotos de perfil",
    nl: "de foto voldoet niet aan de communityregels voor profielfoto's",
  },
  identity_check: {
    en: "we need to confirm your photos are of you",
    fr: "on doit vérifier que tes photos sont bien de toi",
    es: "tenemos que confirmar que las fotos son tuyas",
    de: "wir müssen prüfen, ob die Fotos dich zeigen",
    it: "dobbiamo verificare che le foto siano tue",
    pt: "temos de confirmar que as fotos são tuas",
    nl: "we moeten controleren of de foto's van jou zijn",
  },
  other: {
    en: "a breach of drafft's terms of use",
    fr: "un manquement aux conditions d'utilisation de drafft",
    es: "un incumplimiento de las condiciones de uso de drafft",
    de: "ein Verstoß gegen die Nutzungsbedingungen von drafft",
    it: "una violazione dei termini di utilizzo di drafft",
    pt: "uma violação dos termos de utilização do drafft",
    nl: "een schending van de gebruiksvoorwaarden van drafft",
  },
};

/** A section of the terms of use (private.reason_categories.terms_anchor), as its heading reads on the page. */
export type TermsAnchor = "eligibility" | "community" | "moderation";

export const termsSections: Record<TermsAnchor, Record<Language, string>> = {
  eligibility: {
    en: "To use drafft",
    fr: "Pour utiliser drafft",
    es: "Para usar drafft",
    de: "Voraussetzungen für drafft",
    it: "Per usare drafft",
    pt: "Para usar o drafft",
    nl: "Om drafft te gebruiken",
  },
  community: {
    en: "Community guidelines",
    fr: "Règles de la communauté",
    es: "Normas de la comunidad",
    de: "Community-Regeln",
    it: "Regole della community",
    pt: "Regras da comunidade",
    nl: "Communityregels",
  },
  moderation: {
    en: "Moderation and sanctions",
    fr: "Modération et sanctions",
    es: "Moderación y sanciones",
    de: "Moderation und Sanktionen",
    it: "Moderazione e sanzioni",
    pt: "Moderação e sanções",
    nl: "Moderatie en sancties",
  },
};

/** The terms of use in the person's language, at a section when there is one. */
export function termsLink(lang: Language, anchor: TermsAnchor | null): string {
  return `https://getdrafft.com/${lang === "en" ? "" : `${lang}/`}terms${anchor ? `#${anchor}` : ""}`;
}

/** Around every statement: the reason line, the rule (a section of the terms, or the terms as a whole), the
 * team's note, how to contest. */
export const statementCopy: Record<
  Language,
  { why: string; rule: string; rules: string; note: string; contest: string }
> = {
  en: {
    why: "Why: {reason}.",
    rule: "The rule: {section}, in drafft's terms of use.",
    rules: "The rules are in drafft's terms of use.",
    note: "A note from the team",
    contest:
      "Think it's a mistake? Reply to this email, or write to us from You › Help › Help center in drafft: someone else on the team will look at it again.",
  },
  fr: {
    why: "Pourquoi\u00A0: {reason}.",
    rule: "La règle\u00A0: {section}, dans les conditions d'utilisation de drafft.",
    rules: "Les règles figurent dans les conditions d'utilisation de drafft.",
    note: "Un mot de l'équipe",
    contest:
      "Tu penses que c'est une erreur\u00A0? Réponds à cet e-mail, ou écris-nous depuis Toi › Aide › Centre d'aide dans drafft\u00A0: une autre personne de l'équipe réexaminera la décision.",
  },
  es: {
    why: "Motivo: {reason}.",
    rule: "La norma: {section}, en las condiciones de uso de drafft.",
    rules: "Las normas están en las condiciones de uso de drafft.",
    note: "Una nota del equipo",
    contest:
      "¿Crees que es un error? Responde a este correo o escríbenos desde Tú › Ayuda › Centro de ayuda en drafft: otra persona del equipo volverá a revisarlo.",
  },
  de: {
    why: "Grund: {reason}.",
    rule: "Die Regel: {section}, in den Nutzungsbedingungen von drafft.",
    rules: "Die Regeln stehen in den Nutzungsbedingungen von drafft.",
    note: "Eine Notiz vom Team",
    contest:
      "Du hältst das für einen Fehler? Antworte auf diese E-Mail oder schreib uns in drafft unter Du › Hilfe › Hilfe-Center: Eine andere Person aus dem Team prüft es noch einmal.",
  },
  it: {
    why: "Motivo: {reason}.",
    rule: "La regola: {section}, nei termini di utilizzo di drafft.",
    rules: "Le regole sono nei termini di utilizzo di drafft.",
    note: "Una nota del team",
    contest:
      "Pensi che sia un errore? Rispondi a questa email o scrivici da Tu › Aiuto › Centro assistenza in drafft: un'altra persona del team la riesaminerà.",
  },
  pt: {
    why: "Motivo: {reason}.",
    rule: "A regra: {section}, nos termos de utilização do drafft.",
    rules: "As regras estão nos termos de utilização do drafft.",
    note: "Uma nota da equipa",
    contest:
      "Achas que é um erro? Responde a este email ou escreve-nos em Tu › Ajuda › Centro de ajuda no drafft: outra pessoa da equipa volta a analisar.",
  },
  nl: {
    why: "Reden: {reason}.",
    rule: "De regel: {section}, in de gebruiksvoorwaarden van drafft.",
    rules: "De regels staan in de gebruiksvoorwaarden van drafft.",
    note: "Een berichtje van het team",
    contest:
      "Denk je dat het een fout is? Beantwoord deze e-mail of schrijf ons via Jij › Hulp › Helpcentrum in drafft: iemand anders van het team bekijkt het opnieuw.",
  },
};

/** A statement of reasons: `category` and `anchor` from the decision (moderation_decision), `details` the team's
 * note, as written. A category this file doesn't know throws: the member is never told a vaguer reason. */
export function renderDecision(
  lang: Language,
  kind: Decision,
  category: string,
  anchor: string | null,
  details?: string | null,
): Rendered {
  const c = decisionCopy[kind][lang];
  const f = statementCopy[lang];
  if (!(category in reasonCopy)) throw new Error(`statement: unknown reason category ${category}`);
  if (anchor !== null && !(anchor in termsSections)) throw new Error(`statement: unknown terms section ${anchor}`);
  const section = anchor as TermsAnchor | null;
  const reason = reasonCopy[category as ReasonCategory][lang];
  const why = f.why.replace("{reason}", reason);
  const rule = section ? f.rule.replace("{section}", termsSections[section][lang]) : f.rules;
  const link = termsLink(lang, section);
  const note = details?.trim();
  const rows = [
    title(c.title),
    paragraph(escape(c.body)),
    paragraph(`<strong>${escape(why)}</strong>`),
    paragraph(`${escape(rule)}<br><a href="${escape(link)}" style="color:${color.ink}">${escape(link)}</a>`),
  ];
  if (note) rows.push(muted(`${escape(f.note)}<br>${escape(note).replace(/\n/g, "<br>")}`));
  rows.push(small(f.contest, color.mute));
  const text = [c.title, "", c.body, "", why, rule, link, ...(note ? ["", f.note, note] : []), "", f.contest].join(
    "\n",
  );
  return { subject: c.subject, html: layout(lang, c.subject, rows), text };
}

// A reply from the team (sophros), framed in the person's language; the reply itself is as written. The subject
// ends with the reference, which a reply keeps: the support mail Worker files it in its request.
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
