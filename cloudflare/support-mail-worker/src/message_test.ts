import { assertEquals } from "jsr:@std/assert@1";
import { automatic, cloudflareResults, findReference, htmlToText, stripQuoted, verifiedSender } from "./message.ts";

Deno.test("the reference: from the subject, else the quoted text, uppercase; none when absent", () => {
  assertEquals(findReference("Re: Help [DR-ABC234]", ""), "DR-ABC234");
  assertEquals(findReference("RE: aide", "> Ta référence : dr-xyz789"), "DR-XYZ789");
  assertEquals(findReference("Re: Help", "no reference"), null);
  assertEquals(findReference("DR-ABCDEI", ""), null, "never an I or an O: not one of ours");
});

Deno.test("what they wrote this time: the quoted history cut off, in every language", () => {
  const replies = [
    "Still stuck.\n\nOn Mon, 30 Sep 2026 at 10:00, drafft <no-reply@mail.getdrafft.com> wrote:\n> Try again?",
    "Still stuck.\n\nLe lun. 30 sept. 2026 à 10:00, drafft <no-reply@mail.getdrafft.com> a écrit :\n> Réessaie ?",
    "Still stuck.\n\nEl lun, 30 sept 2026 a las 10:00, drafft escribió:\n> ¿Otra vez?",
    "Still stuck.\n\nAm Mo., 30. Sept. 2026 um 10:00 Uhr schrieb drafft <no-reply@mail.getdrafft.com>:\n> Nochmal?",
    "Still stuck.\n\nIl giorno lun 30 set 2026 alle 10:00 drafft ha scritto:\n> Di nuovo?",
    "Still stuck.\n\nNo dia seg., 30/09/2026 às 10:00, drafft escreveu:\n> Outra vez?",
    "Still stuck.\n\nOp ma 30 sep 2026 om 10:00 schreef drafft <no-reply@mail.getdrafft.com>:\n> Opnieuw?",
    "Still stuck.\n\nOn Mon, 30 Sep 2026 at 10:00, drafft <\nno-reply@mail.getdrafft.com> wrote:\n> Try again?",
    "Still stuck.\n\n-----Original Message-----\nFrom: drafft",
    "Still stuck.\n\n________________________________\nDe : drafft\nEnvoyé : lundi 30 septembre 2026",
    "Still stuck.\n\nFrom: drafft <no-reply@mail.getdrafft.com>\nSent: Monday, 30 September 2026 10:00\nSubject: Re",
    "Still stuck.\n-- \nLéa, sent from my phone",
  ];
  for (const reply of replies) assertEquals(stripQuoted(reply), { text: "Still stuck.", dropped: false }, reply);
});

Deno.test("inline answers keep what was written; a message that is all quote is kept whole", () => {
  assertEquals(stripQuoted("> Did it work?\nNo.\n> And now?\nYes.\r\n"), { text: "No.\nYes.", dropped: false });
  assertEquals(stripQuoted("> only a quote"), { text: "> only a quote", dropped: false });
  assertEquals(stripQuoted("On Monday it failed again.\nThanks"), {
    text: "On Monday it failed again.\nThanks",
    dropped: false,
  });
});

Deno.test("their own lines cut with the history are reported, so the team keeps a copy", () => {
  // "He wrote:" reads like an attribution: the abuse they quote must not vanish.
  assertEquals(
    stripQuoted(
      "Hi,\nI want to report someone.\nOn Saturday, the guy I matched with wrote:\nsomething awful\nPlease block him.",
    ),
    { text: "Hi,\nI want to report someone.", dropped: true },
  );
  assertEquals(stripQuoted("Bonjour,\nLe mec avec qui j'ai matché a écrit :\nun message horrible").dropped, true);
  // Answers written between our quoted lines.
  assertEquals(
    stripQuoted("See my answers below.\n\nOn Mon, drafft <support@getdrafft.com> wrote:\n> Which phone?\niPhone 15"),
    { text: "See my answers below.", dropped: true },
  );
  // Our own email quoted back without ">", and a short signature: nothing of theirs.
  assertEquals(stripQuoted("Thanks.\n\nFrom: drafft\nSent: Monday\nYour reference: DR-ABC234").dropped, false);
  assertEquals(stripQuoted("Thanks.\n-- \nLéa\nRunner").dropped, false);
});

Deno.test("an HTML-only email as text: breaks and paragraphs kept, quotes and styles dropped", () => {
  assertEquals(
    htmlToText(
      "<html><head><style>p{}</style></head><p>Hello&nbsp;there<br>line 2</p><div>A &amp; B &#233;&#x2764;</div>" +
        "<blockquote>quoted</blockquote>",
    ),
    "Hello there\nline 2\nA & B é❤",
  );
  assertEquals(htmlToText("<p>Hi</p><blockquote>a<blockquote>b</blockquote>c</blockquote>"), "Hi", "nested quotes");
  assertEquals(htmlToText("<p>Hi</p><blockquote>ref DR-ABC234</blockquote>", { quotes: true }), "Hi\nref DR-ABC234");
});

Deno.test("the sender: verified by Cloudflare's own results only, SPF for its domain or aligned DKIM", () => {
  const cf = (results: string) => cloudflareResults(`mx.cloudflare.net; ${results}`);
  assertEquals(cloudflareResults("mx.evil.example; spf=pass smtp.mailfrom=lea@drafft.so"), null, "not Cloudflare's");
  assertEquals(cloudflareResults(null), null);
  const spf = cf(
    "spf=pass (mx.cloudflare.net: domain of lea@drafft.so designates 1.2.3.4) smtp.mailfrom=lea@drafft.so",
  );
  assertEquals(verifiedSender("lea@drafft.so", spf), true);
  assertEquals(verifiedSender("mallory@gmail.com", spf), false, "SPF for another domain");
  assertEquals(verifiedSender("lea@drafft.so", cf("spf=softfail smtp.mailfrom=lea@drafft.so; dkim=none")), false);
  assertEquals(
    verifiedSender("lea@mail.drafft.so", cf("spf=fail smtp.mailfrom=x; dkim=pass header.d=drafft.so")),
    true,
  );
  assertEquals(
    verifiedSender("lea@drafft.so", cf("dkim=pass header.d=evil.example; spf=none")),
    false,
    "DKIM unaligned",
  );
  assertEquals(verifiedSender("lea@drafft.so", null), false);
});

Deno.test("an auto-reply, a bounce, a list, a report: not a person writing", () => {
  const h = (init: Record<string, string>) => new Headers(init);
  assertEquals(automatic("lea@drafft.so", h({})), null);
  assertEquals(automatic("lea@drafft.so", h({ "auto-submitted": "no" })), null);
  assertEquals(automatic("lea@drafft.so", h({ "auto-submitted": "auto-replied" })), "auto-submitted: auto-replied");
  assertEquals(automatic("lea@drafft.so", h({ "x-autoreply": "yes" })), "auto-reply");
  assertEquals(automatic("lea@drafft.so", h({ precedence: "bulk" })), "precedence: bulk");
  assertEquals(automatic("news@shop.example", h({ "list-unsubscribe": "<mailto:x>" })), "mailing list");
  assertEquals(automatic("", h({})), "bounce");
  assertEquals(automatic("MAILER-DAEMON@mx.example", h({})), "bounce");
  assertEquals(
    automatic("lea@drafft.so", h({ "content-type": "multipart/report; report-type=delivery-status" })),
    "delivery report",
  );
});
