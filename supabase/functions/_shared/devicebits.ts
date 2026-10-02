// What both device services share: Apple DeviceCheck (devicecheck.ts, two bits per iPhone) and Google Play
// Integrity's Device recall (playintegrity.ts, three bits per Android device, two of them used). Same
// meaning on both: bit0 = an account was closed on this device, bit1 = an account is on hold on it
// (20260927000004_identity_marks.sql).

/** Apple's environment is the project's (DEVICECHECK_ENVIRONMENT); Android has none and is stored as production. */
export type DeviceEnvironment = "development" | "production";

export type DevicePlatform = "ios" | "android";

/** A device's two bits. */
export type DeviceBits = { bit0: boolean; bit1: boolean };

/** Bits to set or clear; a bit left out keeps its value. */
export type BitChange = Partial<DeviceBits>;

/** A row of `device_check_token` (the account's latest device record). */
export type DeviceTokenRow = {
  token: string;
  environment: DeviceEnvironment;
  platform: DevicePlatform;
  /** When device-check stored the token. */
  updated_at: string;
};

const held = (state: string | null | undefined) => state === "review" || state === "selfie";

/**
 * What a change of an account's moderation state does to its device's bits: closed sets bit0, a hold sets
 * bit1, and leaving either clears it. Nothing when neither moved.
 */
export function bitChange(state: string | null | undefined, previous: string | null | undefined): BitChange {
  const change: BitChange = {};
  if (state === "banned") change.bit0 = true;
  else if (previous === "banned") change.bit0 = false;
  if (held(state)) change.bit1 = true;
  else if (held(previous)) change.bit1 = false;
  return change;
}
