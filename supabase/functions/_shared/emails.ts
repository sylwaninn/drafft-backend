// Auth emails in the app's languages (same register as texts.ts: casual, European Portuguese, a
// non-breaking space before ":" in French). One layout: the drafft wordmark, a title, a line, then a
// button (reset link) or the code in large digits (codes the app types into 6 boxes).
import type { Language } from "./texts.ts";

export type AuthEmail = "confirm" | "reset" | "newEmail" | "reauth";

type Copy = { subject: string; title: string; body: string; action?: string; note: string; ignore: string };

const copy: Record<AuthEmail, Record<Language, Copy>> = {
  confirm: {
    en: {
      subject: "Confirm your email",
      title: "Welcome to drafft",
      body: "Enter this code in drafft to confirm your email:",
      note: "The code works for 1 hour.",
      ignore: "If you didn't sign up for drafft, you can ignore this email.",
    },
    fr: {
      subject: "Confirme ton e-mail",
      title: "Bienvenue sur drafft",
      body: "Saisis ce code dans drafft pour confirmer ton e-mail :",
      note: "Le code est valable 1 heure.",
      ignore: "Si tu n'as pas créé de compte drafft, tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "Confirma tu correo",
      title: "Te damos la bienvenida a drafft",
      body: "Introduce este código en drafft para confirmar tu correo:",
      note: "El código vale durante 1 hora.",
      ignore: "Si no te has registrado en drafft, puedes ignorar este correo.",
    },
    de: {
      subject: "Bestätige deine E-Mail",
      title: "Willkommen bei drafft",
      body: "Gib diesen Code in drafft ein, um deine E-Mail-Adresse zu bestätigen:",
      note: "Der Code ist 1 Stunde gültig.",
      ignore: "Wenn du dich nicht bei drafft registriert hast, kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "Conferma la tua email",
      title: "Ti diamo il benvenuto su drafft",
      body: "Inserisci questo codice in drafft per confermare la tua email:",
      note: "Il codice è valido per 1 ora.",
      ignore: "Se non hai creato un account drafft, puoi ignorare questa email.",
    },
    pt: {
      subject: "Confirma o teu email",
      title: "Damos-te as boas-vindas ao drafft",
      body: "Introduz este código no drafft para confirmares o teu email:",
      note: "O código é válido durante 1 hora.",
      ignore: "Se não criaste uma conta drafft, podes ignorar este email.",
    },
    nl: {
      subject: "Bevestig je e-mailadres",
      title: "Welkom bij drafft",
      body: "Vul deze code in drafft in om je e-mailadres te bevestigen:",
      note: "De code is 1 uur geldig.",
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
      subject: "Your drafft code",
      title: "Confirm your new email",
      body: "Enter this code in drafft to switch your account to {email}:",
      note: "The code works for 1 hour.",
      ignore: "If you didn't ask for this, you can ignore this email.",
    },
    fr: {
      subject: "Ton code drafft",
      title: "Confirme ta nouvelle adresse",
      body: "Saisis ce code dans drafft pour passer ton compte sur {email} :",
      note: "Le code est valable 1 heure.",
      ignore: "Si tu n'as rien demandé, tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "Tu código de drafft",
      title: "Confirma tu nuevo correo",
      body: "Introduce este código en drafft para cambiar tu cuenta a {email}:",
      note: "El código vale durante 1 hora.",
      ignore: "Si no lo has pedido, puedes ignorar este correo.",
    },
    de: {
      subject: "Dein drafft-Code",
      title: "Bestätige deine neue E-Mail",
      body: "Gib diesen Code in drafft ein, um dein Konto auf {email} umzustellen:",
      note: "Der Code ist 1 Stunde gültig.",
      ignore: "Wenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "Il tuo codice drafft",
      title: "Conferma la nuova email",
      body: "Inserisci questo codice in drafft per spostare il tuo account su {email}:",
      note: "Il codice è valido per 1 ora.",
      ignore: "Se non l'hai chiesto tu, puoi ignorare questa email.",
    },
    pt: {
      subject: "O teu código drafft",
      title: "Confirma o teu novo email",
      body: "Introduz este código no drafft para mudares a tua conta para {email}:",
      note: "O código é válido durante 1 hora.",
      ignore: "Se não pediste isto, podes ignorar este email.",
    },
    nl: {
      subject: "Je drafft-code",
      title: "Bevestig je nieuwe e-mailadres",
      body: "Vul deze code in drafft in om je account over te zetten naar {email}:",
      note: "De code is 1 uur geldig.",
      ignore: "Heb je dit niet aangevraagd? Dan kun je deze e-mail negeren.",
    },
  },
  reauth: {
    en: {
      subject: "Your drafft code",
      title: "Confirm it's you",
      body: "Enter this code in drafft to change your password:",
      note: "The code works for 1 hour.",
      ignore: "If you didn't ask for this, you can ignore this email.",
    },
    fr: {
      subject: "Ton code drafft",
      title: "Confirme que c'est toi",
      body: "Saisis ce code dans drafft pour changer ton mot de passe :",
      note: "Le code est valable 1 heure.",
      ignore: "Si tu n'as rien demandé, tu peux ignorer cet e-mail.",
    },
    es: {
      subject: "Tu código de drafft",
      title: "Confirma que eres tú",
      body: "Introduce este código en drafft para cambiar tu contraseña:",
      note: "El código vale durante 1 hora.",
      ignore: "Si no lo has pedido, puedes ignorar este correo.",
    },
    de: {
      subject: "Dein drafft-Code",
      title: "Bestätige, dass du es bist",
      body: "Gib diesen Code in drafft ein, um dein Passwort zu ändern:",
      note: "Der Code ist 1 Stunde gültig.",
      ignore: "Wenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.",
    },
    it: {
      subject: "Il tuo codice drafft",
      title: "Conferma che sei tu",
      body: "Inserisci questo codice in drafft per cambiare la password:",
      note: "Il codice è valido per 1 ora.",
      ignore: "Se non l'hai chiesto tu, puoi ignorare questa email.",
    },
    pt: {
      subject: "O teu código drafft",
      title: "Confirma que és tu",
      body: "Introduz este código no drafft para mudares a tua palavra-passe:",
      note: "O código é válido durante 1 hora.",
      ignore: "Se não pediste isto, podes ignorar este email.",
    },
    nl: {
      subject: "Je drafft-code",
      title: "Bevestig dat jij het bent",
      body: "Vul deze code in drafft in om je wachtwoord te wijzigen:",
      note: "De code is 1 uur geldig.",
      ignore: "Heb je dit niet aangevraagd? Dan kun je deze e-mail negeren.",
    },
  },
};

// DESIGN.md palette: canvas, ink, body, mute, primary (on-primary text), canvas-soft.
const color = {
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
    main = `<div style="display:inline-block;background:${color.soft};color:${color.ink};font-size:32px;` +
      `font-weight:800;letter-spacing:8px;padding:14px 20px 14px 28px;border-radius:16px">${escape(vars.code)}</div>`;
    textMain = vars.code;
  }

  const html = `<!doctype html>
<html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${escape(c.subject)}</title></head>
<body style="margin:0;background:${color.canvas};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:40px 20px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px">
<tr><td style="font-size:22px;font-weight:600;color:${color.ink};padding-bottom:32px">drafft</td></tr>
<tr><td style="font-size:26px;font-weight:800;color:${color.ink};padding-bottom:12px">${escape(c.title)}</td></tr>
<tr><td style="font-size:16px;line-height:24px;color:${color.body};padding-bottom:24px">${htmlBody}</td></tr>
<tr><td style="padding-bottom:24px">${main}</td></tr>
<tr><td style="font-size:14px;line-height:20px;color:${color.body};padding-bottom:8px">${escape(c.note)}</td></tr>
<tr><td style="font-size:14px;line-height:20px;color:${color.mute}">${escape(c.ignore)}</td></tr>
</table></td></tr></table></body></html>`;

  const text = [c.title, "", body, "", textMain, "", c.note, c.ignore].join("\n");
  return { subject: c.subject, html, text };
}

function escape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
