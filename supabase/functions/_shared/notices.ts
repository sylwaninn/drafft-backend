// Emails that aren't auth codes: news about the account (a hold lifted, a photo approved or refused on a
// second look) and the
// acknowledgement of a support request, in the person's language; plus the team's copies (SUPPORT_INBOX),
// in English, until the dashboard lists them. Same layout and register as emails.ts.
import { codeBox, color, escape, layout, paragraph, type Rendered, small, title } from "./emails.ts";
import type { Language } from "./texts.ts";

export type Notice = "accountRestored" | "accountReopened" | "photoApproved" | "photoRefused" | "supportReceived";

type Copy = { subject: string; title: string; body: string; note: string };

const copy: Record<Notice, Record<Language, Copy>> = {
  // A review or a selfie check, done: nothing wrong.
  accountRestored: {
    en: {
      subject: "Your drafft account is open again",
      title: "You're all set",
      body:
        "We've finished checking your account: everything is in order. Your profile is visible again, and your matches and chats are right where you left them.",
      note: "Open drafft to pick up where you left off.",
    },
    fr: {
      subject: "Ton compte drafft est de nouveau ouvert",
      title: "Tout est en ordre",
      body:
        "Nous avons terminé la vérification de ton compte : tout est en ordre. Ton profil est de nouveau visible, et tes matchs et tes discussions t'attendent là où tu les as laissés.",
      note: "Ouvre drafft pour reprendre où tu en étais.",
    },
    es: {
      subject: "Tu cuenta de drafft vuelve a estar abierta",
      title: "Todo en orden",
      body:
        "Hemos terminado de revisar tu cuenta: todo está en orden. Tu perfil vuelve a ser visible y tus matches y chats siguen donde los dejaste.",
      note: "Abre drafft para seguir donde lo dejaste.",
    },
    de: {
      subject: "Dein drafft-Konto ist wieder offen",
      title: "Alles in Ordnung",
      body:
        "Wir haben dein Konto geprüft: Alles ist in Ordnung. Dein Profil ist wieder sichtbar, und deine Matches und Chats sind genau da, wo du sie gelassen hast.",
      note: "Öffne drafft und mach da weiter, wo du aufgehört hast.",
    },
    it: {
      subject: "Il tuo account drafft è di nuovo attivo",
      title: "Tutto a posto",
      body:
        "Abbiamo finito di verificare il tuo account: è tutto in ordine. Il tuo profilo è di nuovo visibile e i tuoi match e le tue chat sono dove li avevi lasciati.",
      note: "Apri drafft per riprendere da dove avevi lasciato.",
    },
    pt: {
      subject: "A tua conta drafft está novamente aberta",
      title: "Está tudo em ordem",
      body:
        "Terminámos a verificação da tua conta: está tudo em ordem. O teu perfil voltou a estar visível, e os teus matches e conversas estão onde os deixaste.",
      note: "Abre o drafft para continuares de onde paraste.",
    },
    nl: {
      subject: "Je drafft-account is weer open",
      title: "Alles in orde",
      body:
        "We hebben je account gecontroleerd: alles is in orde. Je profiel is weer zichtbaar, en je matches en chats staan nog precies waar je ze liet.",
      note: "Open drafft om verder te gaan waar je gebleven was.",
    },
  },
  // A closed account, reopened (the team looked again).
  accountReopened: {
    en: {
      subject: "Your drafft account has been reopened",
      title: "Welcome back",
      body:
        "We've looked at your account again and reopened it. Your profile is visible again, and you can use drafft as before.",
      note: "Thanks for your patience.",
    },
    fr: {
      subject: "Ton compte drafft a été rouvert",
      title: "Content de te revoir",
      body:
        "Nous avons réexaminé ton compte et l'avons rouvert. Ton profil est de nouveau visible et tu peux utiliser drafft comme avant.",
      note: "Merci pour ta patience.",
    },
    es: {
      subject: "Hemos reabierto tu cuenta de drafft",
      title: "Qué bien tenerte de vuelta",
      body:
        "Hemos vuelto a revisar tu cuenta y la hemos reabierto. Tu perfil vuelve a ser visible y puedes usar drafft como antes.",
      note: "Gracias por tu paciencia.",
    },
    de: {
      subject: "Dein drafft-Konto wurde wieder geöffnet",
      title: "Schön, dass du wieder da bist",
      body:
        "Wir haben dein Konto noch einmal geprüft und wieder geöffnet. Dein Profil ist wieder sichtbar und du kannst drafft wie gewohnt nutzen.",
      note: "Danke für deine Geduld.",
    },
    it: {
      subject: "Il tuo account drafft è stato riaperto",
      title: "Che bello rivederti",
      body:
        "Abbiamo riesaminato il tuo account e l'abbiamo riaperto. Il tuo profilo è di nuovo visibile e puoi usare drafft come prima.",
      note: "Grazie per la pazienza.",
    },
    pt: {
      subject: "A tua conta drafft foi reaberta",
      title: "Que bom ver-te de volta",
      body:
        "Voltámos a analisar a tua conta e reabrimo-la. O teu perfil voltou a estar visível e podes usar o drafft como antes.",
      note: "Agradecemos a tua paciência.",
    },
    nl: {
      subject: "Je drafft-account is heropend",
      title: "Fijn dat je er weer bent",
      body:
        "We hebben je account opnieuw bekeken en weer geopend. Je profiel is weer zichtbaar en je kunt drafft gebruiken zoals eerst.",
      note: "Bedankt voor je geduld.",
    },
  },
  // A refused photo, approved after the second look the person asked for.
  photoApproved: {
    en: {
      subject: "Your photo has been approved",
      title: "Your photo is live",
      body:
        "You asked for a second look at one of your photos. Our team checked it: it's approved and now on your profile.",
      note: "Thanks for taking the time to ask.",
    },
    fr: {
      subject: "Ta photo a été acceptée",
      title: "Ta photo est en ligne",
      body:
        "Tu as demandé qu'une de tes photos soit revue. Notre équipe l'a vérifiée : elle est acceptée et apparaît maintenant sur ton profil.",
      note: "Merci d'avoir pris le temps de nous le demander.",
    },
    es: {
      subject: "Hemos aprobado tu foto",
      title: "Tu foto ya está publicada",
      body:
        "Pediste que revisáramos una de tus fotos. Nuestro equipo la ha revisado: está aprobada y ya aparece en tu perfil.",
      note: "Gracias por pedírnoslo.",
    },
    de: {
      subject: "Dein Foto wurde freigegeben",
      title: "Dein Foto ist online",
      body:
        "Du hast um eine zweite Prüfung eines deiner Fotos gebeten. Unser Team hat es angesehen: Es ist freigegeben und jetzt in deinem Profil.",
      note: "Danke, dass du nachgefragt hast.",
    },
    it: {
      subject: "La tua foto è stata approvata",
      title: "La tua foto è online",
      body:
        "Hai chiesto di ricontrollare una delle tue foto. Il nostro team l'ha verificata: è approvata e ora è sul tuo profilo.",
      note: "Grazie per avercelo chiesto.",
    },
    pt: {
      subject: "A tua foto foi aprovada",
      title: "A tua foto já está online",
      body:
        "Pediste que voltássemos a ver uma das tuas fotos. A nossa equipa verificou-a: está aprovada e já aparece no teu perfil.",
      note: "Agradecemos que nos tenhas pedido.",
    },
    nl: {
      subject: "Je foto is goedgekeurd",
      title: "Je foto staat online",
      body:
        "Je vroeg ons een van je foto's opnieuw te bekijken. Ons team heeft hem gecontroleerd: hij is goedgekeurd en staat nu op je profiel.",
      note: "Bedankt dat je het vroeg.",
    },
  },
  // A refused photo, refused again after the second look the person asked for.
  photoRefused: {
    en: {
      subject: "About the photo you asked us to check",
      title: "We looked at your photo again",
      body:
        "You asked for a second look at one of your photos. Our team checked it: it doesn't meet our photo guidelines, so it stays off your profile.",
      note: "You can add another photo anytime in drafft.",
    },
    fr: {
      subject: "À propos de la photo que tu nous as demandé de revoir",
      title: "Nous avons revu ta photo",
      body:
        "Tu as demandé qu'une de tes photos soit revue. Notre équipe l'a vérifiée : elle ne respecte pas nos règles sur les photos, elle reste donc hors de ton profil.",
      note: "Tu peux ajouter une autre photo quand tu veux dans drafft.",
    },
    es: {
      subject: "Sobre la foto que nos pediste revisar",
      title: "Hemos vuelto a revisar tu foto",
      body:
        "Pediste que revisáramos una de tus fotos. Nuestro equipo la ha revisado: no cumple nuestras normas sobre fotos, así que no aparecerá en tu perfil.",
      note: "Puedes añadir otra foto cuando quieras en drafft.",
    },
    de: {
      subject: "Zu dem Foto, das wir noch einmal prüfen sollten",
      title: "Wir haben dein Foto noch einmal geprüft",
      body:
        "Du hast um eine zweite Prüfung eines deiner Fotos gebeten. Unser Team hat es angesehen: Es entspricht nicht unseren Foto-Richtlinien und bleibt deshalb nicht in deinem Profil.",
      note: "Du kannst in drafft jederzeit ein anderes Foto hinzufügen.",
    },
    it: {
      subject: "Sulla foto che ci hai chiesto di ricontrollare",
      title: "Abbiamo ricontrollato la tua foto",
      body:
        "Hai chiesto di ricontrollare una delle tue foto. Il nostro team l'ha verificata: non rispetta le nostre regole sulle foto, quindi resta fuori dal tuo profilo.",
      note: "Puoi aggiungere un'altra foto quando vuoi su drafft.",
    },
    pt: {
      subject: "Sobre a foto que nos pediste para rever",
      title: "Voltámos a ver a tua foto",
      body:
        "Pediste que voltássemos a ver uma das tuas fotos. A nossa equipa verificou-a: não cumpre as nossas regras sobre fotos, por isso fica fora do teu perfil.",
      note: "Podes adicionar outra foto quando quiseres no drafft.",
    },
    nl: {
      subject: "Over de foto die we opnieuw moesten bekijken",
      title: "We hebben je foto opnieuw bekeken",
      body:
        "Je vroeg ons een van je foto's opnieuw te bekijken. Ons team heeft hem gecontroleerd: hij voldoet niet aan onze fotoregels en komt daarom niet op je profiel.",
      note: "Je kunt in drafft altijd een andere foto toevoegen.",
    },
  },
  // A support request, received: its reference follows the body. Fixed text, nothing the form typed: the
  // signed-out form mails any address, so it must not carry someone else's words.
  supportReceived: {
    en: {
      subject: "We got your message",
      title: "Message received",
      body: "Thanks for writing to us. We'll reply to this address, usually within 2 working days. Your reference:",
      note: "Keep this reference if you write to us again.",
    },
    fr: {
      subject: "Nous avons bien reçu ton message",
      title: "Message reçu",
      body:
        "Merci de nous avoir écrit. Nous te répondrons à cette adresse, en général sous 2 jours ouvrés. Ta référence :",
      note: "Garde cette référence si tu nous écris de nouveau.",
    },
    es: {
      subject: "Hemos recibido tu mensaje",
      title: "Mensaje recibido",
      body:
        "Gracias por escribirnos. Te responderemos a esta dirección, normalmente en 2 días laborables. Tu referencia:",
      note: "Guarda esta referencia si vuelves a escribirnos.",
    },
    de: {
      subject: "Wir haben deine Nachricht erhalten",
      title: "Nachricht erhalten",
      body:
        "Danke für deine Nachricht. Wir antworten dir an diese Adresse, meist innerhalb von 2 Werktagen. Deine Referenz:",
      note: "Bewahre diese Referenz auf, falls du uns noch einmal schreibst.",
    },
    it: {
      subject: "Abbiamo ricevuto il tuo messaggio",
      title: "Messaggio ricevuto",
      body:
        "Grazie per averci scritto. Ti risponderemo a questo indirizzo, di solito entro 2 giorni lavorativi. Il tuo riferimento:",
      note: "Conserva questo riferimento se ci scrivi di nuovo.",
    },
    pt: {
      subject: "Recebemos a tua mensagem",
      title: "Mensagem recebida",
      body:
        "Agradecemos a tua mensagem. Vamos responder para este endereço, normalmente em 2 dias úteis. A tua referência:",
      note: "Guarda esta referência se nos voltares a escrever.",
    },
    nl: {
      subject: "We hebben je bericht ontvangen",
      title: "Bericht ontvangen",
      body: "Bedankt voor je bericht. We antwoorden naar dit adres, meestal binnen 2 werkdagen. Je referentie:",
      note: "Bewaar deze referentie als je ons opnieuw schrijft.",
    },
  },
};

/** `reference`: the support acknowledgement only. */
export function renderNotice(kind: Notice, lang: Language, vars: { reference?: string } = {}): Rendered {
  const c = copy[kind][lang];
  const body = c.body;
  const rows = [title(c.title), paragraph(escape(c.body))];
  if (vars.reference) rows.push(`<tr><td style="padding-bottom:24px">${codeBox(vars.reference)}</td></tr>`);
  rows.push(small(c.note, color.mute));
  const text = [c.title, "", body, ...(vars.reference ? ["", vars.reference] : []), "", c.note].join("\n");
  return { subject: c.subject, html: layout(lang, c.subject, rows), text };
}

// A reply from the team (sophros), framed in the person's language; the reply itself is as written.
const replyCopy: Record<Language, { title: string; intro: string; yours: string; note: string }> = {
  en: {
    title: "From the drafft team",
    intro: "Here's our reply about: {topic}",
    yours: "Your message",
    note: "Just reply to this email to write back. Your reference:",
  },
  fr: {
    title: "De la part de l'équipe drafft",
    intro: "Voici notre réponse au sujet de : {topic}",
    yours: "Ton message",
    note: "Réponds simplement à cet email pour nous écrire. Ta référence :",
  },
  es: {
    title: "Del equipo de drafft",
    intro: "Esta es nuestra respuesta sobre: {topic}",
    yours: "Tu mensaje",
    note: "Responde a este correo para escribirnos. Tu referencia:",
  },
  de: {
    title: "Vom drafft-Team",
    intro: "Hier ist unsere Antwort zu: {topic}",
    yours: "Deine Nachricht",
    note: "Antworte einfach auf diese E-Mail, um uns zu schreiben. Deine Referenz:",
  },
  it: {
    title: "Dal team di drafft",
    intro: "Ecco la nostra risposta su: {topic}",
    yours: "Il tuo messaggio",
    note: "Rispondi a questa email per scriverci. Il tuo riferimento:",
  },
  pt: {
    title: "Da equipa drafft",
    intro: "Aqui está a nossa resposta sobre: {topic}",
    yours: "A tua mensagem",
    note: "Responde a este email para nos escreveres. A tua referência:",
  },
  nl: {
    title: "Van het drafft-team",
    intro: "Hier is ons antwoord over: {topic}",
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
  const c = replyCopy[lang];
  const subject = `Re: ${vars.topic} [${vars.reference}]`;
  const rows = [
    title(c.title),
    muted(escape(c.intro).replace("{topic}", `<strong>${escape(vars.topic)}</strong>`)),
    paragraph(escape(vars.body).replace(/\n/g, "<br>")),
    muted(`${escape(c.yours)}<br>${escape(vars.message).replace(/\n/g, "<br>")}`),
    small(escape(c.note), color.mute),
    `<tr><td style="padding-bottom:24px">${codeBox(vars.reference)}</td></tr>`,
  ];
  const text = [
    c.title,
    "",
    c.intro.replace("{topic}", vars.topic),
    "",
    vars.body,
    "",
    `${c.yours}:`,
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
