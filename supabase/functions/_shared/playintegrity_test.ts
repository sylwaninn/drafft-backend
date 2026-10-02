import { assertEquals } from "jsr:@std/assert@1";
import { judge, type Payload, requestHashFor } from "./playintegrity.ts";

const now = Date.UTC(2026, 9, 2, 12, 0, 0);
const expected = { packageName: "so.drafft.app", requestHash: "abc", now };

function payload(change: (p: Payload) => void = () => {}): Payload {
  const p: Payload = {
    requestDetails: { requestPackageName: "so.drafft.app", requestHash: "abc", timestampMillis: String(now - 5_000) },
    appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED" },
    deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY"] },
  };
  change(p);
  return p;
}

Deno.test("judge accepts a recent token for our app on a genuine device, and reads the bits", () => {
  assertEquals(judge(payload(), expected), { ok: true, bits: { bit0: false, bit1: false } });
  const recalled = payload((p) => {
    p.deviceIntegrity!.deviceRecall = { values: { bitFirst: true } };
  });
  assertEquals(judge(recalled, expected), { ok: true, bits: { bit0: true, bit1: false } });
});

Deno.test("judge refuses a token that isn't ours, bound to someone else, or too old", () => {
  const reason = (p: Payload) => {
    const verdict = judge(p, expected);
    return verdict.ok ? "ok" : verdict.reason;
  };
  assertEquals(reason(payload((p) => (p.requestDetails!.requestPackageName = "evil.app"))), "package");
  assertEquals(reason(payload((p) => (p.requestDetails!.requestHash = "other"))), "request_hash");
  assertEquals(reason(payload((p) => (p.requestDetails!.timestampMillis = String(now - 11 * 60 * 1000)))), "token_age");
  assertEquals(reason(payload((p) => (p.requestDetails!.timestampMillis = String(now + 5 * 60 * 1000)))), "token_age");
  assertEquals(reason(payload((p) => (p.requestDetails!.timestampMillis = undefined))), "token_age");
  assertEquals(reason({}), "package");
});

Deno.test("judge refuses an app Play doesn't recognise and a device that isn't genuine", () => {
  const reason = (p: Payload) => {
    const verdict = judge(p, expected);
    return verdict.ok ? "ok" : verdict.reason;
  };
  assertEquals(reason(payload((p) => (p.appIntegrity!.appRecognitionVerdict = "UNRECOGNIZED_VERSION"))), "app");
  assertEquals(reason(payload((p) => (p.deviceIntegrity!.deviceRecognitionVerdict = []))), "device");
  assertEquals(
    reason(payload((p) => (p.deviceIntegrity!.deviceRecognitionVerdict = ["MEETS_VIRTUAL_INTEGRITY"]))),
    "device",
  );
  assertEquals(
    reason(payload((p) => (p.deviceIntegrity!.deviceRecognitionVerdict = ["MEETS_STRONG_INTEGRITY"]))),
    "ok",
  );
});

Deno.test("requestHashFor is the lowercase hex SHA-256 of the account's id", async () => {
  const id = "0B6F1F5E-8F0C-4A5E-9D3B-2F8A1C7E4D10";
  const hash = await requestHashFor(id);
  assertEquals(hash.length, 64);
  assertEquals(hash, await requestHashFor(id.toLowerCase()));
  assertEquals(
    await requestHashFor("a"),
    "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
  );
});
