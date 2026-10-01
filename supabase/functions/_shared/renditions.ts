// Photo renditions: the smaller copies the media Worker (cloudflare/media-worker) makes for `&w=` and keeps
// in R2 next to their original, `<key>.w<width>.webp`. Deleting a photo deletes them with it
// (withRenditions); approving one has the Worker make the main ones at once (warmRenditions), so nobody
// waits on a first transformation. Keep RENDITION_WIDTHS in step with the Worker's WIDTHS: its test
// compares them.
import { signedMediaUrl } from "./media_url.ts";

export const RENDITION_WIDTHS = [160, 320, 640, 1080, 1440];

/** Made as soon as a photo is approved: cards (1080, 1440 on the largest phones) and grids (320). */
export const WARM_WIDTHS = [320, 1080, 1440];

/** The objects the Worker resizes (its RESIZABLE): only these have renditions. */
const RESIZABLE = /\.(jpg|heic|png)$/;

export const renditionKey = (key: string, width: number) => `${key}.w${width}.webp`;

/** An object and every rendition that may be kept for it: what deleting it removes. */
export function withRenditions(key: string): string[] {
  return [key, ...renditionsOf(key)];
}

/** The renditions that may be kept for an object (none for what the Worker doesn't resize). */
export function renditionsOf(key: string): string[] {
  return RESIZABLE.test(key) ? RENDITION_WIDTHS.map((w) => renditionKey(key, w)) : [];
}

/**
 * Deletes objects with their renditions: the originals first, then the renditions. A rendition the
 * Worker was still writing looks at its original once written and deletes itself if it's gone, so in
 * this order no copy outlives its photo.
 */
export async function deleteWithRenditions(keys: string[], remove: (key: string) => Promise<void>): Promise<void> {
  await Promise.all(keys.map(remove));
  await Promise.all(keys.flatMap(renditionsOf).map(remove));
}

/**
 * Asks the Worker for a photo's main renditions, so it makes and keeps them now. Best effort: never
 * throws (a rendition not made now is made on its first view).
 */
export async function warmRenditions(key: string, fetcher: typeof fetch = fetch): Promise<void> {
  if (!/^u\/[0-9a-f-]{36}\/(photos|demo)\//.test(key) || !RESIZABLE.test(key)) return;
  let url: string;
  try {
    url = await signedMediaUrl(key);
  } catch (error) {
    console.warn(`renditions ${key}: ${error instanceof Error ? error.message : error}`);
    return;
  }
  // Unsigned (no MEDIA_SIGNING_KEY): a public bucket, no Worker to ask.
  if (!url.includes("sig=")) return;
  await Promise.all(WARM_WIDTHS.map(async (width) => {
    try {
      // A Worker that hangs must not hold the event (and its retries) until the function's time runs out.
      const res = await fetcher(`${url}&w=${width}`, { signal: AbortSignal.timeout(15_000) });
      await res.body?.cancel();
      if (!res.ok) console.warn(`renditions ${key} w${width}: HTTP ${res.status}`);
    } catch (error) {
      console.warn(`renditions ${key} w${width}: ${error instanceof Error ? error.message : error}`);
    }
  }));
}
