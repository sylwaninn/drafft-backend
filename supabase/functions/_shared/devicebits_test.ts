import { assertEquals } from "jsr:@std/assert@1";
import { bitChange } from "./devicebits.ts";

Deno.test("bitChange: closing sets bit0, a hold sets bit1", () => {
  assertEquals(bitChange("banned", null), { bit0: true });
  assertEquals(bitChange("review", null), { bit1: true });
  assertEquals(bitChange("selfie", "review"), { bit1: true });
});

Deno.test("bitChange: leaving a state clears its bit", () => {
  assertEquals(bitChange(null, "banned"), { bit0: false });
  assertEquals(bitChange(null, "review"), { bit1: false });
  assertEquals(bitChange(null, "selfie"), { bit1: false });
});

Deno.test("bitChange: a move between a ban and a hold changes both bits", () => {
  assertEquals(bitChange("review", "banned"), { bit0: false, bit1: true });
  assertEquals(bitChange("banned", "review"), { bit0: true, bit1: false });
});

Deno.test("bitChange: nothing moved, nothing to write", () => {
  assertEquals(bitChange(null, null), {});
  assertEquals(bitChange(undefined, undefined), {});
});
