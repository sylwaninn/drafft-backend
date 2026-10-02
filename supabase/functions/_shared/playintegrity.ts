// Play Integrity on Android: the counterpart of Apple DeviceCheck (devicecheck.ts). The app sends an
// integrity token (a "standard" request); Google alone can read it. We ask Google to decode it, check the
// verdict, and read or write Device recall: three bits kept by Google per device for the linked Google
// Cloud project (drafft uses two), which survive reinstalling the app. bit0 = bitFirst = an account was
// closed on this device, bit1 = bitSecond = an account is on hold on it, like the two DeviceCheck bits
// (types and meaning in devicebits.ts).
//
// Secrets, both needed: PLAY_INTEGRITY_SERVICE_ACCOUNT (the JSON key of a service account of the Google
// Cloud project linked in Play Console's App integrity page, with the Play Integrity API enabled) and
// PLAY_CLOUD_PROJECT_NUMBER (that project's number: the app asks Google for its token with it, the server
// only checks that it is set, as part of the on switch, and never sends it to Google). PLAY_PACKAGE_NAME
// defaults to the app's id. Either one unset (locally): nothing is asked of Google, device-check logs it
// and keeps no Android token, and db-events skips Android devices.
//
// The token is bound to the person: the app puts the SHA-256 of the account's id in the request hash
// (lowercase hex of the digest of the UUID's lowercase text, hyphens included, UTF-8) and the server
// compares. A token more than 10 minutes old, or dated more than a minute ahead, is refused. Device recall
// writes accept a token for 14 days (developer.android.com/google/play/integrity/device-recall), so the last
// verified one is kept for db-events.
import { importPKCS8, SignJWT } from "npm:jose@6";
import type { BitChange, DeviceBits } from "./devicebits.ts";
import { env, optionalEnv } from "./env.ts";

const SCOPE = "https://www.googleapis.com/auth/playintegrity";
const API = "https://playintegrity.googleapis.com/v1";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
/** How old a token may be when the server reads it: the app asks for a new one at each opening. */
const TOKEN_WINDOW_MS = 10 * 60 * 1000;
/** How far ahead of the server's clock a token may be dated. */
const CLOCK_SKEW_MS = 60 * 1000;
/** A hung Google call must not hold a launch, or an email in db-events, back. */
const REQUEST_TIMEOUT_MS = 10 * 1000;
/** How long Google lets a token write Device recall. */
const WRITE_WINDOW_MS = 14 * 24 * 60 * 60 * 1000;

/** Why a token was refused: for the logs only, the app is never told. */
export type Refusal = "package" | "request_hash" | "token_age" | "app" | "device";

export type Verdict =
  | { ok: true; bits: DeviceBits; recall: boolean }
  | { ok: false; reason: Refusal; detail?: string };

/** Our credentials or configuration: the service account, or Google's sign-in. Never a client's fault. */
export class PlayAuthError extends Error {}

/** Google's answer to a decode or a write. A 4xx on a decode is mostly a client token Google refuses. */
export class PlayApiError extends Error {
  constructor(readonly step: "decode" | "write", readonly status: number, body: string) {
    super(`play integrity ${step} ${status}: ${body.slice(0, 200)}`);
  }
}

/** The part of Google's decoded `tokenPayloadExternal` that the checks read. */
export type Payload = {
  requestDetails?: { requestPackageName?: string; requestHash?: string; timestampMillis?: string | number };
  appIntegrity?: { appRecognitionVerdict?: string };
  deviceIntegrity?: {
    deviceRecognitionVerdict?: string[];
    deviceRecall?: { values?: { bitFirst?: boolean; bitSecond?: boolean } };
  };
};

export function playIntegrityConfigured(): boolean {
  return !!optionalEnv("PLAY_INTEGRITY_SERVICE_ACCOUNT") && !!optionalEnv("PLAY_CLOUD_PROJECT_NUMBER");
}

export function packageName(): string {
  return optionalEnv("PLAY_PACKAGE_NAME") ?? "so.drafft.app";
}

/** What the app must put in the request hash: see the header. */
export async function requestHashFor(userId: string): Promise<string> {
  const bytes = new TextEncoder().encode(userId.toLowerCase());
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The checks of Google's guide, in its order: the request is ours and recent, then the app, then the
 * device. A verdict that fails says why, for the logs only.
 */
export function judge(payload: Payload, expected: { packageName: string; requestHash: string; now: number }): Verdict {
  const request = payload.requestDetails;
  if (request?.requestPackageName !== expected.packageName) {
    return { ok: false, reason: "package", detail: `got ${String(request?.requestPackageName).slice(0, 80)}` };
  }
  if (request.requestHash !== expected.requestHash) return { ok: false, reason: "request_hash" };
  const age = expected.now - Number(request.timestampMillis);
  if (!Number.isFinite(age) || age > TOKEN_WINDOW_MS || age < -CLOCK_SKEW_MS) {
    return { ok: false, reason: "token_age", detail: Number.isFinite(age) ? `${Math.round(age / 1000)} s` : "no date" };
  }
  if (payload.appIntegrity?.appRecognitionVerdict !== "PLAY_RECOGNIZED") return { ok: false, reason: "app" };
  const device = payload.deviceIntegrity?.deviceRecognitionVerdict ?? [];
  if (!device.includes("MEETS_DEVICE_INTEGRITY") && !device.includes("MEETS_STRONG_INTEGRITY")) {
    return { ok: false, reason: "device" };
  }
  const recall = payload.deviceIntegrity?.deviceRecall;
  return {
    ok: true,
    bits: { bit0: !!recall?.values?.bitFirst, bit1: !!recall?.values?.bitSecond },
    recall: recall !== undefined,
  };
}

/** Whether a token stored at `recordedAt` can still write Device recall (a date that can't be read: no). */
export function canWrite(recordedAt: string, now = Date.now()): boolean {
  return now - Date.parse(recordedAt) < WRITE_WINDOW_MS;
}

// MARK: Google's sign-in

let cached: { token: string; expiresAt: number } | undefined;
let signingIn: Promise<string> | undefined;

/** Forgets the access token (a test, or Google refused it). */
export function resetAccessToken() {
  cached = undefined;
  signingIn = undefined;
}

function serviceAccount(): { client_email: string; private_key: string } {
  let account: { client_email?: unknown; private_key?: unknown };
  try {
    account = JSON.parse(env("PLAY_INTEGRITY_SERVICE_ACCOUNT"));
  } catch {
    throw new PlayAuthError("PLAY_INTEGRITY_SERVICE_ACCOUNT is not the JSON key of a service account");
  }
  if (typeof account.client_email !== "string" || typeof account.private_key !== "string") {
    throw new PlayAuthError("PLAY_INTEGRITY_SERVICE_ACCOUNT has no client_email or private_key");
  }
  return { client_email: account.client_email, private_key: account.private_key.replace(/\\n/g, "\n") };
}

async function signIn(): Promise<string> {
  const account = serviceAccount();
  let assertion: string;
  try {
    const key = await importPKCS8(account.private_key, "RS256");
    assertion = await new SignJWT({ scope: SCOPE })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(account.client_email)
      .setAudience(TOKEN_URL)
      .setIssuedAt()
      .setExpirationTime("55m")
      .sign(key);
  } catch (error) {
    throw new PlayAuthError(`PLAY_INTEGRITY_SERVICE_ACCOUNT's private key can't sign: ${error}`);
  }
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!res.ok) throw new PlayAuthError(`google sign-in ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const body = await res.json().catch(() => ({})) as { access_token?: unknown; expires_in?: unknown };
  if (typeof body.access_token !== "string" || !body.access_token) {
    throw new PlayAuthError("google sign-in: no access_token in the answer");
  }
  // Renewed five minutes early; an answer without a lifetime is taken for the usual hour.
  const lifetime = typeof body.expires_in === "number" && body.expires_in > 0 ? body.expires_in : 3600;
  cached = { token: body.access_token, expiresAt: Date.now() + Math.max(60, lifetime - 300) * 1000 };
  return body.access_token;
}

/** The access token, signed in once at a time: concurrent calls share the one request. */
async function accessToken(): Promise<string> {
  if (cached && Date.now() < cached.expiresAt) return cached.token;
  signingIn ??= signIn().finally(() => {
    signingIn = undefined;
  });
  return await signingIn;
}

async function call(path: string, body: Record<string, unknown>, retried = false): Promise<Response> {
  const res = await fetch(`${API}/${packageName()}${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${await accessToken()}`, "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (res.status === 401 && !retried) {
    // A revoked or rotated key, or a token Google no longer takes: sign in again once.
    await res.body?.cancel();
    cached = undefined;
    return await call(path, body, true);
  }
  return res;
}

// MARK: Decode, verify, write

/** Google's reading of a token: throws when Google refuses it (expired, malformed, another project) or can't answer. */
async function decode(integrityToken: string): Promise<Payload> {
  const res = await call(":decodeIntegrityToken", { integrityToken });
  if (!res.ok) throw new PlayApiError("decode", res.status, await res.text());
  const { tokenPayloadExternal } = await res.json() as { tokenPayloadExternal?: Payload };
  if (!tokenPayloadExternal) throw new PlayApiError("decode", res.status, "no payload");
  return tokenPayloadExternal;
}

let recallWarnedAt = 0;

/** Decodes a token and judges it for this account. */
export async function verify(integrityToken: string, userId: string, now = Date.now()): Promise<Verdict> {
  const payload = await decode(integrityToken);
  const verdict = judge(payload, { packageName: packageName(), requestHash: await requestHashFor(userId), now });
  if (verdict.ok && !verdict.recall && now - recallWarnedAt > 60 * 60 * 1000) {
    // Read as "no bits": nobody would ever be flagged. Said once an hour, not at every launch.
    recallWarnedAt = now;
    console.warn(
      "play integrity: a passing verdict has no deviceRecall: is Device recall on for the app in Play Console?",
    );
  }
  return verdict;
}

/** Sets or clears one or both bits; a bit not given keeps its value. Google applies it within 30 s. */
export async function writeBits(integrityToken: string, change: BitChange): Promise<void> {
  const newValues: Record<string, boolean> = {};
  if (change.bit0 !== undefined) newValues.bitFirst = change.bit0;
  if (change.bit1 !== undefined) newValues.bitSecond = change.bit1;
  if (Object.keys(newValues).length === 0) return;
  const res = await call("/deviceRecall:write", { integrityToken, newValues });
  if (!res.ok) throw new PlayApiError("write", res.status, await res.text());
}
