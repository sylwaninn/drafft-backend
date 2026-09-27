// Auth emails in the app's languages (same register as texts.ts: casual, European Portuguese, a
// non-breaking space before ":" in French). One layout: the drafft wordmark, a title, a line, then a
// button (reset link) or the code in large digits (codes the app types into 6 boxes).
import type { Language } from "./texts.ts";

export type AuthEmail = "confirm" | "reset" | "newEmail" | "reauth";

type Copy = { subject: string; title: string; body: string; action?: string; note: string; ignore: string };

const copy: Record<AuthEmail, Record<Language, Copy>> = {
  confirm: {
    en: {
      subject: "{code} is your code",
      title: "Welcome to drafft",
      body: "To confirm your email in drafft, enter this code:",
      note: "Valid for 1 hour.",
      ignore: "If you didn't sign up for drafft, you can ignore this email.",
    },
    fr: {
      subject: "{code} est ton code",
      title: "Bienvenue sur drafft",
      body: "Pour confirmer ton e-mail dans drafft, saisis ce code :",
      note: "Valable 1 heure.",
      ignore: "Si tu n'as pas créé de compte drafft, tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "{code} es tu código",
      title: "Te damos la bienvenida a drafft",
      body: "Para confirmar tu correo en drafft, introduce este código:",
      note: "Válido durante 1 hora.",
      ignore: "Si no te has registrado en drafft, puedes ignorar este correo.",
    },
    de: {
      subject: "{code} ist dein Code",
      title: "Willkommen bei drafft",
      body: "Um deine E-Mail-Adresse in drafft zu bestätigen, nutze diesen Code:",
      note: "1 Stunde gültig.",
      ignore: "Wenn du dich nicht bei drafft registriert hast, kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "{code} è il tuo codice",
      title: "Ti diamo il benvenuto su drafft",
      body: "Per confermare la tua email su drafft, inserisci questo codice:",
      note: "Valido per 1 ora.",
      ignore: "Se non hai creato un account drafft, puoi ignorare questa email.",
    },
    pt: {
      subject: "{code} é o teu código",
      title: "Damos-te as boas-vindas ao drafft",
      body: "Para confirmares o teu email no drafft, introduz este código:",
      note: "Válido durante 1 hora.",
      ignore: "Se não criaste uma conta drafft, podes ignorar este email.",
    },
    nl: {
      subject: "{code} is je code",
      title: "Welkom bij drafft",
      body: "Om je e-mailadres in drafft te bevestigen, gebruik je deze code:",
      note: "1 uur geldig.",
      ignore: "Heb je geen drafft-account aangemaakt? Dan kun je deze e-mail negeren.",
    },
  },
  reset: {
    en: {
      subject: "Reset your password",
      title: "New password",
      body: "Tap the button to choose a new password.",
      action: "Choose a new password",
      note: "The link works for 1 hour.",
      ignore: "If you didn't ask for this, you can ignore this email: your password stays the same.",
    },
    fr: {
      subject: "Réinitialise ton mot de passe",
      title: "Nouveau mot de passe",
      body: "Appuie sur le bouton pour choisir un nouveau mot de passe.",
      action: "Choisir un mot de passe",
      note: "Le lien est valable 1 heure.",
      ignore: "Si tu n'as rien demandé, ignore cet e-mail : ton mot de passe ne change pas.",
    },
    es: {
      subject: "Restablece tu contraseña",
      title: "Nueva contraseña",
      body: "Pulsa el botón para elegir una contraseña nueva.",
      action: "Elegir una contraseña",
      note: "El enlace vale durante 1 hora.",
      ignore: "Si no lo has pedido, ignora este correo: tu contraseña no cambia.",
    },
    de: {
      subject: "Setze dein Passwort zurück",
      title: "Neues Passwort",
      body: "Tippe auf den Button, um ein neues Passwort zu wählen.",
      action: "Neues Passwort wählen",
      note: "Der Link ist 1 Stunde gültig.",
      ignore: "Wenn du das nicht angefordert hast, ignoriere diese E-Mail: Dein Passwort bleibt gleich.",
    },
    it: {
      subject: "Reimposta la password",
      title: "Nuova password",
      body: "Tocca il pulsante per scegliere una nuova password.",
      action: "Scegli una password",
      note: "Il link è valido per 1 ora.",
      ignore: "Se non l'hai chiesto tu, ignora questa email: la tua password non cambia.",
    },
    pt: {
      subject: "Repõe a tua palavra-passe",
      title: "Nova palavra-passe",
      body: "Toca no botão para escolheres uma nova palavra-passe.",
      action: "Escolher palavra-passe",
      note: "O link é válido durante 1 hora.",
      ignore: "Se não pediste isto, ignora este email: a tua palavra-passe mantém-se.",
    },
    nl: {
      subject: "Stel je wachtwoord opnieuw in",
      title: "Nieuw wachtwoord",
      body: "Tik op de knop om een nieuw wachtwoord te kiezen.",
      action: "Kies een wachtwoord",
      note: "De link is 1 uur geldig.",
      ignore: "Heb je dit niet aangevraagd? Negeer deze e-mail: je wachtwoord blijft hetzelfde.",
    },
  },
  newEmail: {
    en: {
      subject: "{code} is your code",
      title: "Confirm your new email",
      body: "To switch your drafft account to {email}, enter this code:",
      note: "Valid for 1 hour.",
      ignore: "If you didn't ask for this, you can ignore this email.",
    },
    fr: {
      subject: "{code} est ton code",
      title: "Confirme ta nouvelle adresse",
      body: "Pour passer ton compte drafft sur {email}, saisis ce code :",
      note: "Valable 1 heure.",
      ignore: "Si tu n'as rien demandé, tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "{code} es tu código",
      title: "Confirma tu nuevo correo",
      body: "Para cambiar tu cuenta de drafft a {email}, introduce este código:",
      note: "Válido durante 1 hora.",
      ignore: "Si no lo has pedido, puedes ignorar este correo.",
    },
    de: {
      subject: "{code} ist dein Code",
      title: "Bestätige deine neue E-Mail",
      body: "Um dein drafft-Konto auf {email} umzustellen, nutze diesen Code:",
      note: "1 Stunde gültig.",
      ignore: "Wenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "{code} è il tuo codice",
      title: "Conferma la nuova email",
      body: "Per spostare il tuo account drafft su {email}, inserisci questo codice:",
      note: "Valido per 1 ora.",
      ignore: "Se non l'hai chiesto tu, puoi ignorare questa email.",
    },
    pt: {
      subject: "{code} é o teu código",
      title: "Confirma o teu novo email",
      body: "Para mudares a tua conta drafft para {email}, introduz este código:",
      note: "Válido durante 1 hora.",
      ignore: "Se não pediste isto, podes ignorar este email.",
    },
    nl: {
      subject: "{code} is je code",
      title: "Bevestig je nieuwe e-mailadres",
      body: "Om je drafft-account over te zetten naar {email}, gebruik je deze code:",
      note: "1 uur geldig.",
      ignore: "Heb je dit niet aangevraagd? Dan kun je deze e-mail negeren.",
    },
  },
  reauth: {
    en: {
      subject: "{code} is your code",
      title: "Confirm it's you",
      body: "To change your drafft password, enter this code:",
      note: "Valid for 1 hour.",
      ignore: "If you didn't ask for this, you can ignore this email.",
    },
    fr: {
      subject: "{code} est ton code",
      title: "Confirme que c'est toi",
      body: "Pour changer ton mot de passe drafft, saisis ce code :",
      note: "Valable 1 heure.",
      ignore: "Si tu n'as rien demandé, tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "{code} es tu código",
      title: "Confirma que eres tú",
      body: "Para cambiar tu contraseña de drafft, introduce este código:",
      note: "Válido durante 1 hora.",
      ignore: "Si no lo has pedido, puedes ignorar este correo.",
    },
    de: {
      subject: "{code} ist dein Code",
      title: "Bestätige, dass du es bist",
      body: "Um dein drafft-Passwort zu ändern, nutze diesen Code:",
      note: "1 Stunde gültig.",
      ignore: "Wenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "{code} è il tuo codice",
      title: "Conferma che sei tu",
      body: "Per cambiare la password di drafft, inserisci questo codice:",
      note: "Valido per 1 ora.",
      ignore: "Se non l'hai chiesto tu, puoi ignorare questa email.",
    },
    pt: {
      subject: "{code} é o teu código",
      title: "Confirma que és tu",
      body: "Para mudares a tua palavra-passe do drafft, introduz este código:",
      note: "Válido durante 1 hora.",
      ignore: "Se não pediste isto, podes ignorar este email.",
    },
    nl: {
      subject: "{code} is je code",
      title: "Bevestig dat jij het bent",
      body: "Om je drafft-wachtwoord te wijzigen, gebruik je deze code:",
      note: "1 uur geldig.",
      ignore: "Heb je dit niet aangevraagd? Dan kun je deze e-mail negeren.",
    },
  },
};

// DESIGN.md palette: canvas, ink, body, mute, primary (on-primary text), canvas-soft.
export const color = {
  canvas: "#ffffff",
  ink: "#0e0f0c",
  body: "#454745",
  mute: "#868685",
  primary: "#9fe870",
  soft: "#e8ebe6",
};

export type Rendered = { subject: string; html: string; text: string };

/** A link email (confirm, reset) takes `link`; a code email (newEmail, reauth) takes `code`. */
export function renderAuthEmail(
  kind: AuthEmail,
  lang: Language,
  vars: { link?: string; code?: string; email?: string },
): Rendered {
  const c = copy[kind][lang];
  const body = c.body.replace("{email}", vars.email ?? "");
  const htmlBody = escape(c.body).replace("{email}", `<strong>${escape(vars.email ?? "")}</strong>`);

  let main: string;
  let textMain: string;
  if (c.action) {
    if (!vars.link) throw new Error(`${kind}: link missing`);
    main =
      `<a href="${escape(vars.link)}" style="display:inline-block;background:${color.primary};color:${color.ink};` +
      `font-weight:600;font-size:16px;text-decoration:none;padding:14px 24px;border-radius:999px">${
        escape(c.action)
      }</a>`;
    textMain = `${c.action}: ${vars.link}`;
  } else {
    if (!vars.code) throw new Error(`${kind}: code missing`);
    main = codeBox(vars.code);
    textMain = vars.code;
  }

  const html = layout(lang, c.subject.replace("{code}", vars.code ?? ""), [
    title(c.title),
    paragraph(htmlBody),
    `<tr><td style="padding-bottom:24px">${main}</td></tr>`,
    small(c.note, color.body),
    small(c.ignore, color.mute),
  ]);

  const text = [c.title, "", body, "", textMain, "", c.note, c.ignore].join("\n");
  // iOS offers the word right after "code" above the keyboard: so the subject is "123456 is your code", and
  // no copy has a word after "code" but the code itself (the sender's name already says drafft).
  const subject = c.subject.replace("{code}", vars.code ?? "");
  return { subject, html, text };
}

/** A code or reference in large type, on a soft block. */
export function codeBox(value: string): string {
  return `<div style="display:inline-block;background:${color.soft};color:${color.ink};font-size:32px;` +
    `font-weight:800;letter-spacing:8px;padding:14px 20px 14px 28px;border-radius:16px">${escape(value)}</div>`;
}

export function title(text: string): string {
  return `<tr><td style="font-size:26px;font-weight:800;color:${color.ink};padding-bottom:12px">${
    escape(text)
  }</td></tr>`;
}

/** `html` is already escaped (it may hold a <strong>). */
export function paragraph(html: string): string {
  return `<tr><td style="font-size:16px;line-height:24px;color:${color.body};padding-bottom:24px">${html}</td></tr>`;
}

export function small(text: string, tone: string = color.body): string {
  return `<tr><td style="font-size:14px;line-height:20px;color:${tone};padding-bottom:8px">${escape(text)}</td></tr>`;
}

/** Every drafft email: white page, the wordmark, then the rows. */
export function layout(lang: string, subject: string, rows: string[]): string {
  return `<!doctype html>
<html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${escape(subject)}</title></head>
<body style="margin:0;background:${color.canvas};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:40px 20px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px">
<tr><td style="font-size:22px;font-weight:600;color:${color.ink};padding-bottom:32px">drafft</td></tr>
${rows.join("\n")}
</table></td></tr></table></body></html>`;
}

export function escape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
