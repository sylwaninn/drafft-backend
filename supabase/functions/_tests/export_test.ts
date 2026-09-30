// The export's parts and its email (_shared/export.ts, notices.ts): pure functions, no network.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. _tests/
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { zipSync } from "npm:fflate@0.8.2";

Deno.env.set("SUPABASE_URL", "http://supabase.test");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key");
const { archivePath, planParts } = await import("../_shared/export.ts");
const { renderExportReady } = await import("../_shared/notices.ts");
const languages = ["en", "fr", "es", "de", "it", "pt", "nl"] as const;

const user = "11111111-1111-4111-8111-111111111111";

Deno.test("planParts: in order, a part closed when the next file doesn't fit, a file too big for any left out", () => {
  const files = [
    { key: `u/${user}/photos/a.jpg`, bytes: 100 },
    { key: `u/${user}/photos/huge.mp4`, bytes: 10_000 },
    { key: `u/${user}/photos/b.jpg`, bytes: 100 },
  ];
  const { parts, tooLarge } = planParts(files, 1_000, 500);
  assertEquals(tooLarge.map((f) => f.key), [`u/${user}/photos/huge.mp4`]);
  assertEquals(parts.map((p) => p.map((f) => f.key)), [[`u/${user}/photos/a.jpg`], [`u/${user}/photos/b.jpg`]]);
  // Part 1 full with data.json alone: the first file starts part 2.
  assertEquals(planParts(files.slice(0, 1), 1_000, 950).parts.map((p) => p.length), [0, 1]);
});

Deno.test("planParts: what it plans fits once zipped, long non-ASCII names included", () => {
  const files = Array.from(
    { length: 2000 },
    (_, i) => ({ key: `u/${user}/chat/été-${"é".repeat(40)}-${i}.jpg`, bytes: 1 }),
  );
  const limit = 60_000;
  const { parts, tooLarge } = planParts(files, limit, 0);
  assertEquals(tooLarge, []);
  for (const part of parts) {
    const zip = zipSync(Object.fromEntries(part.map((f) => [archivePath(f.key), [new Uint8Array(1), { level: 0 }]])));
    assert(zip.length <= limit, `${zip.length} > ${limit}`);
  }
});

Deno.test("the export email: one button, the other parts as plain links, in every language", () => {
  for (const lang of languages) {
    const one = renderExportReady(lang, ["https://x.test/1?a=1&b=2"]);
    assertEquals(one.html.match(/border-radius:16px/g)?.length, 1, lang);
    assertStringIncludes(one.html, "https://x.test/1?a=1&amp;b=2");
    const three = renderExportReady(lang, [1, 2, 3].map((n) => `https://x.test/${n}`));
    assertEquals(three.html.match(/border-radius:16px/g)?.length, 1, `${lang}: one button`);
    for (const n of [1, 2, 3]) {
      assertStringIncludes(three.html, `href="https://x.test/${n}"`);
      assertStringIncludes(three.text, `https://x.test/${n}`);
    }
    assert(!/\{count\}|\{n\}/.test(three.html + three.text), lang);
    assertStringIncludes(three.text, "3");
  }
});
