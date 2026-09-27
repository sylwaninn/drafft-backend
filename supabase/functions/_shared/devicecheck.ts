// Apple DeviceCheck: two bits per iPhone, kept by Apple for drafft's developer account. The app sends an
// opaque token from DCDevice; Apple alone knows which iPhone it stands for. bit0 = an account was closed
// on this iPhone, bit1 = an account is on hold on it (20260927000004_identity_marks.sql).
//
// Signed like APNs (ES256 .p8), with a key that has DeviceCheck enabled: DEVICECHECK_KEY_ID,
// DEVICECHECK_PRIVATE_KEY, and the team in APNS_TEAM_ID. Unset (locally): nothing is sent to Apple.
import { importPKCS8, SignJWT } from "npm:jose@6";
import { env, optionalEnv } from "./env.ts";

export type DeviceEnvironment = "development" | "production";

let cached: { jwt: string; at: number } | undefined;

export function deviceCheckConfigured(): boolean {
  return !!optionalEnv("DEVICECHECK_KEY_ID") && !!optionalEnv("DEVICECHECK_PRIVATE_KEY");
}

async function authToken(): Promise<string> {
  if (cached && Date.now() - cached.at < 45 * 60 * 1000) return cached.jwt;
  const key = await importPKCS8(env("DEVICECHECK_PRIVATE_KEY").replace(/\\n/g, "\n"), "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env("DEVICECHECK_KEY_ID") })
    .setIssuer(env("APNS_TEAM_ID"))
    .setIssuedAt()
    .sign(key);
  cached = { jwt, at: Date.now() };
  return jwt;
}

async function call(environment: DeviceEnvironment, path: string, body: Record<string, unknown>): Promise<Response> {
  const host = environment === "production" ? "api.devicecheck.apple.com" : "api.development.devicecheck.apple.com";
  return await fetch(`https://${host}/v1/${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${await authToken()}`, "content-type": "application/json" },
    body: JSON.stringify({ ...body, transaction_id: crypto.randomUUID(), timestamp: Date.now() }),
  });
}

/** The iPhone's bits. Never set: both false (Apple answers 200 "Failed to find bit state"). */
export async function queryBits(
  token: string,
  environment: DeviceEnvironment,
): Promise<{ bit0: boolean; bit1: boolean; lastUpdate?: string }> {
  const res = await call(environment, "query_two_bits", { device_token: token });
  const text = await res.text();
  if (!res.ok) throw new Error(`devicecheck query ${res.status}: ${text.slice(0, 200)}`);
  if (!text.trim().startsWith("{")) return { bit0: false, bit1: false };
  const bits = JSON.parse(text) as { bit0?: boolean; bit1?: boolean; last_update_time?: string };
  return { bit0: !!bits.bit0, bit1: !!bits.bit1, lastUpdate: bits.last_update_time };
}

/** Sets or clears one or both bits; a bit not given keeps its value. */
export async function updateBits(
  token: string,
  environment: DeviceEnvironment,
  change: { bit0?: boolean; bit1?: boolean },
): Promise<void> {
  const current = await queryBits(token, environment);
  const next = { bit0: change.bit0 ?? current.bit0, bit1: change.bit1 ?? current.bit1 };
  if (next.bit0 === current.bit0 && next.bit1 === current.bit1) return;
  const res = await call(environment, "update_two_bits", { device_token: token, ...next });
  if (!res.ok) throw new Error(`devicecheck update ${res.status}: ${(await res.text()).slice(0, 200)}`);
}
