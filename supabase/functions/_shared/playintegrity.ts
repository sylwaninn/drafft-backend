// Play Integrity on Android: the counterpart of Apple DeviceCheck (devicecheck.ts). The app sends an
// integrity token (a "standard" request); Google alone can read it. We ask Google to decode it, check the
// verdict, and read or write Device recall: three bits kept by Google per device for drafft's developer
// account, which survive reinstalling the app. bit0 = bitFirst = an account was closed on this device,
// bit1 = bitSecond = an account is on hold on it, like the two DeviceCheck bits.
//
// Secrets: PLAY_INTEGRITY_SERVICE_ACCOUNT (the service account's JSON key, linked to the Google Cloud
// project that Play Console's App integrity page lists) and PLAY_CLOUD_PROJECT_NUMBER (public: the app
// asks Google for its token with it). PLAY_PACKAGE_NAME defaults to the app's id. Unset (locally): nothing
// is asked of Google, and device-check keeps no Android token.
//
// The token is bound to the person: the app puts the SHA-256 of the account's id, as lowercase hex, in
// the request hash, and the server compares. A token older than 10 minutes is refused. Device recall
// writes accept a token for 14 days, so the last verified one is kept for db-events.
import { importPKCS8, SignJWT } from "npm:jose@6";
import { env, optionalEnv } from "./env.ts";

const SCOPE = "https://www.googleapis.com/auth/playintegrity";
const API = "https://playintegrity.googleapis.com/v1";
const TOKEN_WINDOW_MS = 10 * 60 * 1000;
/** How long Google lets a token write Device recall. */
export const WRITE_WINDOW_MS = 14 * 24 * 60 * 60 * 1000;

export type Bits = { bit0: boolean; bit1: boolean };

export type Verdict = { ok: true; bits: Bits } | { ok: false; reason: string };

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

/** What the app must put in the request hash: the SHA-256 of the account's id, lowercase hex. */
export async function requestHashFor(userId: string): Promise<string> {
  const bytes = new TextEncoder().encode(userId.toLowerCase());
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The checks of Google's guide, in its order: the request is ours and recent, then the app, then the
 * device. A verdict that fails says why for the logs only; the app is never told.
 */
export function judge(payload: Payload, expected: { packageName: string; requestHash: string; now: number }): Verdict {
  const request = payload.requestDetails;
  if (request?.requestPackageName !== expected.packageName) return { ok: false, reason: "package" };
  if (request.requestHash !== expected.requestHash) return { ok: false, reason: "request_hash" };
  const age = expected.now - Number(request.timestampMillis);
  if (!Number.isFinite(age) || age > TOKEN_WINDOW_MS || age < -60_000) return { ok: false, reason: "token_age" };
  if (payload.appIntegrity?.appRecognitionVerdict !== "PLAY_RECOGNIZED") return { ok: false, reason: "app" };
  const device = payload.deviceIntegrity?.deviceRecognitionVerdict ?? [];
  if (!device.includes("MEETS_DEVICE_INTEGRITY") && !device.includes("MEETS_STRONG_INTEGRITY")) {
    return { ok: false, reason: "device" };
  }
  const values = payload.deviceIntegrity?.deviceRecall?.values;
  return { ok: true, bits: { bit0: !!values?.bitFirst, bit1: !!values?.bitSecond } };
}

let cached: { token: string; at: number } | undefined;

async function accessToken(): Promise<string> {
  if (cached && Date.now() - cached.at < 45 * 60 * 1000) return cached.token;
  const account = JSON.parse(env("PLAY_INTEGRITY_SERVICE_ACCOUNT")) as { client_email: string; private_key: string };
  const key = await importPKCS8(account.private_key, "RS256");
  const assertion = await new SignJWT({ scope: SCOPE })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(account.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt()
    .setExpirationTime("55m")
    .sign(key);
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw new Error(`play integrity auth ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const { access_token } = await res.json() as { access_token: string };
  cached = { token: access_token, at: Date.now() };
  return access_token;
}

async function call(path: string, body: Record<string, unknown>): Promise<Response> {
  return await fetch(`${API}/${packageName()}${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${await accessToken()}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

/** Google's reading of a token: throws when Google refuses it (expired, malformed, wrong project). */
export async function decode(integrityToken: string): Promise<Payload> {
  const res = await call(":decodeIntegrityToken", { integrityToken });
  if (!res.ok) throw new Error(`play integrity decode ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const { tokenPayloadExternal } = await res.json() as { tokenPayloadExternal?: Payload };
  if (!tokenPayloadExternal) throw new Error("play integrity decode: no payload");
  return tokenPayloadExternal;
}

/** Decodes a token and judges it for this account. */
export async function verify(integrityToken: string, userId: string): Promise<Verdict> {
  const payload = await decode(integrityToken);
  return judge(payload, { packageName: packageName(), requestHash: await requestHashFor(userId), now: Date.now() });
}

/** Sets or clears one or both bits; a bit not given keeps its value. Google applies it within 30 s. */
export async function writeBits(integrityToken: string, change: { bit0?: boolean; bit1?: boolean }): Promise<void> {
  const newValues: Record<string, boolean> = {};
  if (change.bit0 !== undefined) newValues.bitFirst = change.bit0;
  if (change.bit1 !== undefined) newValues.bitSecond = change.bit1;
  const res = await call("/deviceRecall:write", { integrityToken, newValues });
  if (!res.ok) throw new Error(`play integrity write ${res.status}: ${(await res.text()).slice(0, 200)}`);
}
