// Auth emails in the app's languages (WORDING.md, same register as texts.ts: casual, European Portuguese, a
// non-breaking space before ":" and "?" in French). One layout: the drafft wordmark, a title that says what
// the subject says, a line, then the code in large digits: every auth email carries a 6-digit code the app
// types into 6 boxes, never a link. The line ends on the word "code" (nothing between it and the digits),
// and no other line uses that word: iOS offers what follows "code" above the keyboard.
import type { Language } from "./texts.ts";

export type AuthEmail = "confirm" | "reset" | "newEmail" | "reauth";

export type Copy = { subject: string; title: string; body: string; note: string; ignore: string };

export const authEmailCopy: Record<AuthEmail, Record<Language, Copy>> = {
  confirm: {
    en: {
      subject: "{code} is your code",
      title: "Confirm your email.",
      body: "To finish signing up, enter this code:",
      note: "It works for 1 hour.",
      ignore: "Didn't sign up for drafft? You can ignore this email.",
    },
    fr: {
      subject: "{code} est ton code",
      title: "Confirme ton adresse e-mail.",
      body: "Pour finir ton inscription, saisis ce code\u00A0:",
      note: "Il est valable 1\u00A0heure.",
      ignore: "Tu n'as pas créé de compte drafft\u00A0? Tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "{code} es tu código",
      title: "Confirma tu correo.",
      body: "Para terminar tu registro, introduce este código:",
      note: "Es válido durante 1 hora.",
      ignore: "¿No te has registrado en drafft? Puedes ignorar este correo.",
    },
    de: {
      subject: "{code} ist dein Code",
      title: "Bestätige deine E-Mail-Adresse.",
      body: "Um deine Registrierung abzuschließen, nutze diesen Code:",
      note: "Er gilt 1 Stunde lang.",
      ignore: "Du hast kein drafft-Konto erstellt? Dann kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "{code} è il tuo codice",
      title: "Conferma la tua email.",
      body: "Per completare la registrazione, inserisci questo codice:",
      note: "Vale per 1 ora.",
      ignore: "Non hai creato un account drafft? Puoi ignorare questa email.",
    },
    pt: {
      subject: "{code} é o teu código",
      title: "Confirma o teu email.",
      body: "Para concluíres o registo, introduz este código:",
      note: "É válido durante 1 hora.",
      ignore: "Não criaste uma conta drafft? Podes ignorar este email.",
    },
    nl: {
      subject: "{code} is je code",
      title: "Bevestig je e-mailadres.",
      body: "Om je aanmelding af te ronden, gebruik je deze code:",
      note: "Hij is 1 uur geldig.",
      ignore: "Geen drafft-account aangemaakt? Dan kun je deze e-mail negeren.",
    },
  },
  reset: {
    en: {
      subject: "{code} is your code",
      title: "Reset your password.",
      body: "To choose a new password, enter this code:",
      note: "It works for 1 hour.",
      ignore: "Didn't ask for this? Ignore this email: your password stays the same.",
    },
    fr: {
      subject: "{code} est ton code",
      title: "Réinitialise ton mot de passe.",
      body: "Pour choisir un nouveau mot de passe, saisis ce code\u00A0:",
      note: "Il est valable 1\u00A0heure.",
      ignore: "Tu n'as rien demandé\u00A0? Ignore cet e-mail\u00A0: ton mot de passe ne change pas.",
    },
    es: {
      subject: "{code} es tu código",
      title: "Restablece tu contraseña.",
      body: "Para elegir una contraseña nueva, introduce este código:",
      note: "Es válido durante 1 hora.",
      ignore: "¿No lo has pedido tú? Ignora este correo: tu contraseña no cambia.",
    },
    de: {
      subject: "{code} ist dein Code",
      title: "Setz dein Passwort zurück.",
      body: "Um ein neues Passwort zu wählen, nutze diesen Code:",
      note: "Er gilt 1 Stunde lang.",
      ignore: "Du hast das nicht angefordert? Ignoriere diese E-Mail: Dein Passwort bleibt, wie es ist.",
    },
    it: {
      subject: "{code} è il tuo codice",
      title: "Reimposta la password.",
      body: "Per scegliere una nuova password, inserisci questo codice:",
      note: "Vale per 1 ora.",
      ignore: "Non l'hai chiesto tu? Ignora questa email: la tua password non cambia.",
    },
    pt: {
      subject: "{code} é o teu código",
      title: "Repõe a tua palavra-passe.",
      body: "Para escolheres uma nova palavra-passe, introduz este código:",
      note: "É válido durante 1 hora.",
      ignore: "Não pediste isto? Ignora este email: a tua palavra-passe mantém-se.",
    },
    nl: {
      subject: "{code} is je code",
      title: "Stel je wachtwoord opnieuw in.",
      body: "Om een nieuw wachtwoord te kiezen, gebruik je deze code:",
      note: "Hij is 1 uur geldig.",
      ignore: "Niet aangevraagd? Negeer deze e-mail: je wachtwoord blijft hetzelfde.",
    },
  },
  newEmail: {
    en: {
      subject: "{code} is your code",
      title: "Confirm your new email.",
      body: "To move your drafft account to {email}, enter this code:",
      note: "It works for 1 hour.",
      ignore: "Didn't ask for this? You can ignore this email.",
    },
    fr: {
      subject: "{code} est ton code",
      title: "Confirme ta nouvelle adresse e-mail.",
      body: "Pour passer ton compte drafft sur {email}, saisis ce code\u00A0:",
      note: "Il est valable 1\u00A0heure.",
      ignore: "Tu n'as rien demandé\u00A0? Tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "{code} es tu código",
      title: "Confirma tu nuevo correo.",
      body: "Para cambiar tu cuenta de drafft a {email}, introduce este código:",
      note: "Es válido durante 1 hora.",
      ignore: "¿No lo has pedido tú? Puedes ignorar este correo.",
    },
    de: {
      subject: "{code} ist dein Code",
      title: "Bestätige deine neue E-Mail-Adresse.",
      body: "Um dein drafft-Konto auf {email} umzustellen, nutze diesen Code:",
      note: "Er gilt 1 Stunde lang.",
      ignore: "Du hast das nicht angefordert? Dann kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "{code} è il tuo codice",
      title: "Conferma la nuova email.",
      body: "Per spostare il tuo account drafft su {email}, inserisci questo codice:",
      note: "Vale per 1 ora.",
      ignore: "Non l'hai chiesto tu? Puoi ignorare questa email.",
    },
    pt: {
      subject: "{code} é o teu código",
      title: "Confirma o teu novo email.",
      body: "Para mudares a tua conta drafft para {email}, introduz este código:",
      note: "É válido durante 1 hora.",
      ignore: "Não pediste isto? Podes ignorar este email.",
    },
    nl: {
      subject: "{code} is je code",
      title: "Bevestig je nieuwe e-mailadres.",
      body: "Om je drafft-account over te zetten naar {email}, gebruik je deze code:",
      note: "Hij is 1 uur geldig.",
      ignore: "Niet aangevraagd? Dan kun je deze e-mail negeren.",
    },
  },
  reauth: {
    en: {
      subject: "{code} is your code",
      title: "Confirm it's you.",
      body: "To change your password, enter this code:",
      note: "It works for 1 hour.",
      ignore: "Didn't ask for this? You can ignore this email.",
    },
    fr: {
      subject: "{code} est ton code",
      title: "Confirme que c'est toi.",
      body: "Pour changer ton mot de passe, saisis ce code\u00A0:",
      note: "Il est valable 1\u00A0heure.",
      ignore: "Tu n'as rien demandé\u00A0? Tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "{code} es tu código",
      title: "Confirma que eres tú.",
      body: "Para cambiar tu contraseña, introduce este código:",
      note: "Es válido durante 1 hora.",
      ignore: "¿No lo has pedido tú? Puedes ignorar este correo.",
    },
    de: {
      subject: "{code} ist dein Code",
      title: "Bestätige, dass du es bist.",
      body: "Um dein Passwort zu ändern, nutze diesen Code:",
      note: "Er gilt 1 Stunde lang.",
      ignore: "Du hast das nicht angefordert? Dann kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "{code} è il tuo codice",
      title: "Conferma che sei tu.",
      body: "Per cambiare la password, inserisci questo codice:",
      note: "Vale per 1 ora.",
      ignore: "Non l'hai chiesto tu? Puoi ignorare questa email.",
    },
    pt: {
      subject: "{code} é o teu código",
      title: "Confirma que és tu.",
      body: "Para mudares a tua palavra-passe, introduz este código:",
      note: "É válido durante 1 hora.",
      ignore: "Não pediste isto? Podes ignorar este email.",
    },
    nl: {
      subject: "{code} is je code",
      title: "Bevestig dat jij het bent.",
      body: "Om je wachtwoord te wijzigen, gebruik je deze code:",
      note: "Hij is 1 uur geldig.",
      ignore: "Niet aangevraagd? Dan kun je deze e-mail negeren.",
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

/** Every auth email takes the `code`; a new address also its `email`. */
export function renderAuthEmail(
  kind: AuthEmail,
  lang: Language,
  vars: { code?: string; email?: string },
): Rendered {
  const c = authEmailCopy[kind][lang];
  const body = c.body.replace("{email}", vars.email ?? "");
  const htmlBody = escape(c.body).replace("{email}", `<strong>${escape(vars.email ?? "")}</strong>`);
  if (!vars.code) throw new Error(`${kind}: code missing`);
  const main = codeBox(vars.code);
  const textMain = vars.code;

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
