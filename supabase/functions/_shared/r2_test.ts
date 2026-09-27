import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { assertSafeKey } from "./r2.ts";

const me = "0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10";

Deno.test("assertSafeKey accepts the keys media-upload-url issues", () => {
  for (const key of [`u/${me}/photos/5f0c.jpg`, `u/${me}/chat/5f0c.mp4`, `u/${me}/voice/5f0c.m4a`]) {
    assertEquals(assertSafeKey(key), key);
  }
});

Deno.test("assertSafeKey refuses dot, dot-dot and empty segments", () => {
  for (
    const key of [
      `u/${me}/photos/../../other/photos/x.jpg`,
      `u/${me}/./photos/x.jpg`,
      `u/${me}/%2e%2E/x.jpg`,
      `u/${me}//x.jpg`,
      `/u/${me}/photos/x.jpg`,
      `u/${me}/photos/`,
      "",
      `u/${me}/${"a".repeat(600)}.jpg`,
    ]
  ) {
    assertThrows(() => assertSafeKey(key), Error, "invalid object key");
  }
});
