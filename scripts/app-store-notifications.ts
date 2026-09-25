// Points the App Store Server Notifications (V2) of so.drafft.app at RevenueCat: production
// notifications to the "drafft" project, sandbox ones to "drafft staging". Apple keeps one URL per
// environment, so production TestFlight builds (sandbox) get no server notifications; their SDK still
// syncs on launch.
//
//   deno run -A scripts/app-store-notifications.ts plan
//   PRODUCTION_URL=… SANDBOX_URL=… deno run -A scripts/app-store-notifications.ts apply
//
// Each URL is RevenueCat's "Apple Server to Server notification endpoint", in the App Store app's
// settings of the matching project. Same App Store Connect key as app-store-products.ts.
import { importPKCS8, SignJWT } from "npm:jose@6";

const KEY_PATH = Deno.env.get("ASC_KEY_PATH") ??
  `${Deno.env.get("HOME")}/Secrets/drafft/app-store-connect-api/AuthKey_58P79YY35W.p8`;
const KEY_ID = Deno.env.get("ASC_KEY_ID") ?? "58P79YY35W";
const ISSUER_ID = Deno.env.get("ASC_ISSUER_ID") ?? "072b7c08-dd42-4792-87a9-6b029c17e258";
const BUNDLE_ID = "so.drafft.app";
const mode = Deno.args[0] ?? "plan";

async function jwt(): Promise<string> {
  const key = await importPKCS8(await Deno.readTextFile(KEY_PATH), "ES256");
  const now = Math.floor(Date.now() / 1000);
  return await new SignJWT({ iss: ISSUER_ID, iat: now, exp: now + 10 * 60, aud: "appstoreconnect-v1" })
    .setProtectedHeader({ alg: "ES256", kid: KEY_ID, typ: "JWT" })
    .sign(key);
}

// deno-lint-ignore no-explicit-any
async function api(method: string, path: string, body?: unknown): Promise<any> {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { authorization: `Bearer ${await jwt()}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${text.slice(0, 400)}`);
  return text ? JSON.parse(text) : {};
}

const fields =
  "subscriptionStatusUrl,subscriptionStatusUrlVersion,subscriptionStatusUrlForSandbox,subscriptionStatusUrlVersionForSandbox";
const [found] = (await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)).data;
if (!found) throw new Error(`No app ${BUNDLE_ID}`);
// The filtered list leaves these attributes out: read the app itself.
const app = (await api("GET", `/v1/apps/${found.id}?fields[apps]=${fields}`)).data;
const a = app.attributes;
console.log(`now:  production ${a.subscriptionStatusUrl ?? "(none)"} ${a.subscriptionStatusUrlVersion ?? ""}`);
console.log(
  `now:  sandbox    ${a.subscriptionStatusUrlForSandbox ?? "(none)"} ${a.subscriptionStatusUrlVersionForSandbox ?? ""}`,
);

if (mode === "apply") {
  const production = Deno.env.get("PRODUCTION_URL");
  const sandbox = Deno.env.get("SANDBOX_URL");
  if (!production || !sandbox) throw new Error("Set PRODUCTION_URL and SANDBOX_URL");
  if (production === sandbox) throw new Error("PRODUCTION_URL and SANDBOX_URL must be the two different projects");
  await api("PATCH", `/v1/apps/${app.id}`, {
    data: {
      type: "apps",
      id: app.id,
      attributes: {
        subscriptionStatusUrl: production,
        subscriptionStatusUrlVersion: "V2",
        subscriptionStatusUrlForSandbox: sandbox,
        subscriptionStatusUrlVersionForSandbox: "V2",
      },
    },
  });
  console.log(`set:  production ${production} V2`);
  console.log(`set:  sandbox    ${sandbox} V2`);
}
