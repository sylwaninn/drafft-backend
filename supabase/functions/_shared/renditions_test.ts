import { assertEquals } from "jsr:@std/assert@1";
import {
  deleteWithRenditions,
  RENDITION_WIDTHS,
  renditionKey,
  renditionsOf,
  WARM_WIDTHS,
  warmRenditions,
  withRenditions,
} from "./renditions.ts";

const photo = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a1b2.jpg";

Deno.test("a photo is deleted with every rendition, anything else alone", () => {
  assertEquals(withRenditions(photo), [
    photo,
    ...RENDITION_WIDTHS.map((w) => `${photo}.w${w}.q70.webp`),
    // Made at quality 85 before 2026-10-01.
    ...RENDITION_WIDTHS.map((w) => `${photo}.w${w}.webp`),
  ]);
  const voice = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/voice/a1b2.m4a";
  assertEquals(withRenditions(voice), [voice]);
  assertEquals(renditionKey(photo, 1080), `${photo}.w1080.q70.webp`);
});

Deno.test("warming asks the Worker for each main width, and never throws", async () => {
  const before = { url: Deno.env.get("MEDIA_PUBLIC_URL"), key: Deno.env.get("MEDIA_SIGNING_KEY") };
  Deno.env.set("MEDIA_PUBLIC_URL", "https://media.test/");
  Deno.env.set("MEDIA_SIGNING_KEY", "test-signing-key");
  try {
    const asked: string[] = [];
    await warmRenditions(photo, (input) => {
      const url = String(input);
      asked.push(new URL(url).searchParams.get("w")!);
      if (url.includes("w=1440")) return Promise.reject(new Error("offline"));
      return Promise.resolve(new Response("ok"));
    });
    assertEquals(asked.sort(), WARM_WIDTHS.map(String).sort());

    const none: string[] = [];
    await warmRenditions("u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/chat/a1b2.jpg", (i) => {
      none.push(String(i));
      return Promise.resolve(new Response("ok"));
    });
    assertEquals(none, [], "only profile photos are warmed");
  } finally {
    for (const [name, value] of [["MEDIA_PUBLIC_URL", before.url], ["MEDIA_SIGNING_KEY", before.key]] as const) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
});

Deno.test("deleting removes the originals before any rendition", async () => {
  const photo2 = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/c3d4.png";
  const order: string[] = [];
  await deleteWithRenditions([photo, photo2], (key) => {
    order.push(key);
    return Promise.resolve();
  });
  assertEquals(order.slice(0, 2), [photo, photo2]);
  assertEquals(order.slice(2).sort(), [...renditionsOf(photo), ...renditionsOf(photo2)].sort());
});
