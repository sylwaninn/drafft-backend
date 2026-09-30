// Which Rekognition faces make a photo fit to be the portrait (recognisable). No network.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. _tests/
import { assert, assertFalse } from "jsr:@std/assert@1";
import { type FaceBox, recognisable } from "../_shared/moderation.ts";

const face = (confidence: number, width: number, height: number): FaceBox => ({
  Confidence: confidence,
  BoundingBox: { Width: width, Height: height },
});

Deno.test("a clear, close face makes a portrait", () => {
  assert(recognisable([face(99.8, 0.3, 0.4)]));
});

Deno.test("no face, a tiny face or an unsure one does not", () => {
  assertFalse(recognisable([]));
  assertFalse(recognisable([face(99.9, 0.1, 0.1)]));
  assertFalse(recognisable([face(80, 0.4, 0.4)]));
});

Deno.test("one recognisable face among others is enough", () => {
  assert(recognisable([face(99, 0.05, 0.05), face(97, 0.2, 0.2)]));
});
