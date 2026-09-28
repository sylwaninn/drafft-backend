// The verification SMS, in the app's languages. Apple's documented shape ("Your Example code is 123456"):
// the code last, nothing after it, so iOS offers it above the keyboard. The sender "drafft" names the app.
// Short, so it stays one SMS even when an accent switches it to Unicode.
import { env, optionalEnv } from "./env.ts";
import type { Language } from "./texts.ts";

const verification: Record<Language, (code: string) => string> = {
  en: (c) => `Your drafft code is ${c}`,
  fr: (c) => `Ton code de vérification est ${c}`,
  es: (c) => `Tu código de verificación es ${c}`,
  de: (c) => `Dein Bestätigungscode ist ${c}`,
  it: (c) => `Il tuo codice di verifica è ${c}`,
  pt: (c) => `O teu código de verificação é ${c}`,
  nl: (c) => `Je verificatiecode is ${c}`,
};

export function verificationSms(lang: Language, code: string): string {
  return verification[lang](code);
}

/** The 10 countries the app offers at the phone step (drafft's PhoneCountry.all, Services/Verification.swift):
 * nothing else is texted, so a bot can't run up the bill on premium numbers elsewhere. Twilio's geo
 * permissions say the same. Keep both lists in step when a country is added. */
const allowedPrefixes = ["+33", "+32", "+41", "+352", "+44", "+34", "+39", "+49"];

/** +1 is the whole North American Numbering Plan: the US and Canada, but also about twenty Caribbean and
 * Pacific countries and territories, where an SMS costs far more. Only the geographic area codes of the US
 * (50 states and DC) and Canada are texted: no Caribbean, no Puerto Rico, Guam or other territories, no
 * toll-free (8XX), premium (900) or other non-geographic codes (5XX personal, 600/622/633).
 * From libphonenumber's metadata (libphonenumber-js 1.13.14, September 2026). A new area code opened
 * after that is refused until it is added here. */
const usAreaCodes = (
  "201 202 203 205 206 207 208 209 210 212 213 214 215 216 217 218 219 220 223 224 225 227 228 229 231 234 " +
  "235 239 240 248 251 252 253 254 256 260 262 267 269 270 272 274 276 279 281 283 301 302 303 304 305 307 " +
  "308 309 310 312 313 314 315 316 317 318 319 320 321 323 324 325 326 327 329 330 331 332 334 336 337 339 " +
  "341 346 347 350 351 352 353 360 361 363 364 369 380 385 386 401 402 404 405 406 407 408 409 410 412 413 " +
  "414 415 417 419 423 424 425 430 432 434 435 440 442 443 445 447 448 458 463 464 469 470 472 475 478 479 " +
  "480 484 501 502 503 504 505 507 508 509 510 512 513 515 516 517 518 520 530 531 534 539 540 541 551 557 " +
  "559 561 562 563 564 567 570 571 572 573 574 575 580 582 585 586 601 602 603 605 606 607 608 609 610 612 " +
  "614 615 616 617 618 619 620 623 626 628 629 630 631 636 640 641 645 646 650 651 656 657 659 660 661 662 " +
  "667 669 678 680 681 682 686 689 701 702 703 704 706 707 708 712 713 714 715 716 717 718 719 720 724 725 " +
  "726 727 728 730 731 732 734 737 738 740 743 747 748 754 757 760 762 763 765 769 770 771 772 773 774 775 " +
  "779 781 785 786 801 802 803 804 805 806 808 810 812 813 814 815 816 817 818 820 821 826 828 830 831 832 " +
  "835 838 839 840 843 845 847 848 850 854 856 857 858 859 860 862 863 864 865 870 872 878 901 903 904 906 " +
  "907 908 909 910 912 913 914 915 916 917 918 919 920 925 928 929 930 931 934 936 937 938 940 941 943 945 " +
  "947 948 949 951 952 954 956 959 970 971 972 973 975 978 979 980 983 984 985 986 989"
).split(" ");
const caAreaCodes = (
  "204 226 236 249 250 257 263 273 289 306 343 354 365 367 368 382 403 416 418 428 431 437 438 450 468 474 " +
  "506 514 519 548 579 581 584 587 604 613 639 647 672 683 705 709 742 753 778 780 782 807 819 825 867 873 " +
  "879 902 905 942"
).split(" ");
const nanpAreaCodes = new Set([...usAreaCodes, ...caAreaCodes]);

export function isAllowedNumber(e164: string): boolean {
  if (!/^\+[1-9]\d{6,14}$/.test(e164)) return false;
  // NANP: +1, a 3-digit area code, then 7 digits (the exchange never starts with 0 or 1).
  if (e164.startsWith("+1")) return /^\+1\d{3}[2-9]\d{6}$/.test(e164) && nanpAreaCodes.has(e164.slice(2, 5));
  return allowedPrefixes.some((p) => e164.startsWith(p));
}

/** Lines that never get a code: virtual and VoIP numbers (made in seconds, the usual way back after a
 * ban), and lines that can't take an SMS anyway. */
const refusedLineTypes = new Set([
  "nonFixedVoip",
  "fixedVoip",
  "tollFree",
  "premium",
  "sharedCost",
  "uan",
  "voicemail",
  "pager",
  "landline",
]);

/** Twilio Lookup v2 (Line Type Intelligence, a few cents each), only at a phone verification. Lookup
 * runs in Twilio's US1 region, so it has its own US1 API key (TWILIO_LOOKUP_API_KEY_SID and _SECRET).
 * Unset (locally), unknown type, or Lookup down: the code goes out; this filters, it doesn't gate. */
export async function isRefusedLine(e164: string): Promise<boolean> {
  const sid = optionalEnv("TWILIO_LOOKUP_API_KEY_SID"), secret = optionalEnv("TWILIO_LOOKUP_API_KEY_SECRET");
  if (!sid || !secret) return false;
  try {
    const res = await fetch(
      `https://lookups.twilio.com/v2/PhoneNumbers/${encodeURIComponent(e164)}?Fields=line_type_intelligence`,
      { headers: { authorization: `Basic ${btoa(`${sid}:${secret}`)}` }, signal: AbortSignal.timeout(4000) },
    );
    if (!res.ok) throw new Error(`lookup ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json() as { line_type_intelligence?: { type?: string | null } | null };
    return refusedLineTypes.has(body.line_type_intelligence?.type ?? "");
  } catch (error) {
    console.error("twilio lookup", error);
    return false;
  }
}

const regionHosts: Record<string, string> = {
  us1: "api.twilio.com",
  ie1: "api.dublin.ie1.twilio.com",
  au1: "api.sydney.au1.twilio.com",
};

/** Hosted: Twilio, through a Messaging Service (sender "drafft" where allowed, a number elsewhere).
 * Local: MAILPIT_URL set, the SMS lands in Mailpit as an email and no phone is texted, unless
 * SMS_REAL=true in .env.local sends it through Twilio to try it on a real phone. */
export async function sendSms(to: string, body: string): Promise<void> {
  const mailpit = optionalEnv("SMS_REAL") === "true" ? undefined : optionalEnv("MAILPIT_URL");
  if (mailpit) {
    const res = await fetch(`${mailpit}/api/v1/send`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        From: { Email: "sms@drafft.local", Name: "drafft SMS" },
        To: [{ Email: `${to.replace("+", "")}@sms.drafft.local` }],
        Subject: `SMS to ${to}`,
        Text: body,
      }),
    });
    if (!res.ok) throw new Error(`mailpit ${res.status}: ${await res.text()}`);
    return;
  }

  const account = env("TWILIO_ACCOUNT_SID");
  // An API key (SK…) rather than the account's auth token: it can be revoked on its own.
  const auth = btoa(`${env("TWILIO_API_KEY_SID")}:${env("TWILIO_API_KEY_SECRET")}`);
  // Ireland (ie1) by default: drafft's Twilio keys and Messaging Service live there, next to its EU users.
  // TWILIO_REGION overrides it (us1, au1). A key and a service only work on their own region's host.
  const host = regionHosts[(optionalEnv("TWILIO_REGION") ?? "ie1").toLowerCase()] ?? regionHosts.ie1;
  const res = await fetch(`https://${host}/2010-04-01/Accounts/${account}/Messages.json`, {
    method: "POST",
    headers: { authorization: `Basic ${auth}`, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ To: to, Body: body, MessagingServiceSid: env("TWILIO_MESSAGING_SERVICE_SID") }),
  });
  if (!res.ok) throw new Error(`twilio ${res.status}: ${await res.text()}`);
}
