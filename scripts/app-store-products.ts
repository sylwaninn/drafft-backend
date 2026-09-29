// Creates drafft's in-app products in App Store Connect, matching `store_products` and the app's
// catalogue. Idempotent: existing products are left as they are, so a wording change here reaches only new
// products: edit live ones in App Store Connect. Names and descriptions follow WORDING.md (boost, super like
// and drafft tempo in lowercase).
//
//   deno run -A scripts/app-store-products.ts plan    # read only: access check + price points
//   deno run -A scripts/app-store-products.ts apply   # create what's missing
//
// Needs ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID (defaults below match the drafft key).
import { importPKCS8, SignJWT } from "npm:jose@6";

const KEY_PATH = Deno.env.get("ASC_KEY_PATH") ??
  `${Deno.env.get("HOME")}/Secrets/drafft/app-store-connect-api/AuthKey_58P79YY35W.p8`;
const KEY_ID = Deno.env.get("ASC_KEY_ID") ?? "58P79YY35W";
const ISSUER_ID = Deno.env.get("ASC_ISSUER_ID") ?? "072b7c08-dd42-4792-87a9-6b029c17e258";
const BUNDLE_ID = "so.drafft.app";
const BASE_TERRITORY = "FRA";
const LOCALE = "en-US";

const GROUP = { referenceName: "drafft tempo", displayName: "drafft tempo" };
const SUBSCRIPTIONS = [
  { productId: "so.drafft.app.tempo.monthly", name: "drafft tempo 1 month", period: "ONE_MONTH", price: "12.99" },
  { productId: "so.drafft.app.tempo.sixmonths", name: "drafft tempo 6 months", period: "SIX_MONTHS", price: "44.99" },
  { productId: "so.drafft.app.tempo.yearly", name: "drafft tempo 12 months", period: "ONE_YEAR", price: "71.99" },
];
const SUBSCRIPTION_DESCRIPTION = "Unlimited likes and every drafft tempo perk"; // ≤ 55
const CONSUMABLES = [
  {
    productId: "so.drafft.app.boost.1",
    name: "1 boost",
    price: "4.99",
    description: "30 minutes up front for people near you",
  },
  {
    productId: "so.drafft.app.boost.5",
    name: "5 boosts",
    price: "17.99",
    description: "30 minutes up front for people near you",
  },
  {
    productId: "so.drafft.app.boost.10",
    name: "10 boosts",
    price: "29.99",
    description: "30 minutes up front for people near you",
  },
  {
    productId: "so.drafft.app.superlike.3",
    name: "3 super likes",
    price: "4.99",
    description: "They see you first, with your note",
  },
  {
    productId: "so.drafft.app.superlike.15",
    name: "15 super likes",
    price: "17.99",
    description: "They see you first, with your note",
  },
  {
    productId: "so.drafft.app.superlike.30",
    name: "30 super likes",
    price: "29.99",
    description: "They see you first, with your note",
  },
]; // IAP name ≤ 30, description ≤ 45

// MARK: API

let token: { jwt: string; at: number } | undefined;
async function jwt(): Promise<string> {
  if (token && Date.now() - token.at < 15 * 60 * 1000) return token.jwt;
  const key = await importPKCS8(await Deno.readTextFile(KEY_PATH), "ES256");
  const now = Math.floor(Date.now() / 1000);
  const signed = await new SignJWT({ iss: ISSUER_ID, iat: now, exp: now + 19 * 60, aud: "appstoreconnect-v1" })
    .setProtectedHeader({ alg: "ES256", kid: KEY_ID, typ: "JWT" })
    .sign(key);
  token = { jwt: signed, at: Date.now() };
  return signed;
}

// deno-lint-ignore no-explicit-any
type Json = any;

async function api(method: string, path: string, body?: Json): Promise<Json> {
  const url = path.startsWith("http") ? path : `https://api.appstoreconnect.apple.com${path}`;
  // Apple's API answers intermittent 500s: retry with backoff. A retried POST that did go through
  // fails with a 409 on the unique product id instead of creating a duplicate.
  let res: Response;
  for (let attempt = 1;; attempt++) {
    res = await fetch(url, {
      method,
      headers: { authorization: `Bearer ${await jwt()}`, "content-type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status < 500 || attempt === 5) break;
    await res.body?.cancel();
    await new Promise((r) => setTimeout(r, 2000 * attempt));
  }
  const text = await res.text();
  if (!res.ok) {
    const errors = (JSON.parse(text || "{}").errors ?? []).map((e: Json) => `${e.title}: ${e.detail}`).join(" | ");
    throw new Error(`${method} ${path} → ${res.status} ${errors || text.slice(0, 300)}`);
  }
  return text ? JSON.parse(text) : {};
}

async function all(path: string): Promise<Json[]> {
  const out: Json[] = [];
  let next: string | undefined = path;
  while (next) {
    const page: Json = await api("GET", next);
    out.push(...page.data);
    next = page.links?.next;
  }
  return out;
}

/** Exact price point for the base territory, or the nearest one. */
async function pricePoint(path: string, price: string): Promise<{ id: string; price: string; exact: boolean }> {
  const points = await all(`${path}?filter[territory]=${BASE_TERRITORY}&limit=200`);
  const target = Number(price);
  let best = points[0];
  for (const p of points) {
    if (
      Math.abs(Number(p.attributes.customerPrice) - target) < Math.abs(Number(best.attributes.customerPrice) - target)
    ) {
      best = p;
    }
  }
  return { id: best.id, price: best.attributes.customerPrice, exact: Number(best.attributes.customerPrice) === target };
}

// MARK: Run

const mode = Deno.args[0] ?? "plan";
const [app] = (await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)).data;
if (!app) throw new Error(`No app with bundle id ${BUNDLE_ID}`);
console.log(`App: ${app.attributes.name} (${app.id})`);

const existingIaps = await all(`/v1/apps/${app.id}/inAppPurchasesV2`);
const groups = await all(`/v1/apps/${app.id}/subscriptionGroups?include=subscriptions&limit=200`);
const existingSubs = new Set<string>();
for (const g of groups) {
  for (const s of await all(`/v1/subscriptionGroups/${g.id}/subscriptions?limit=200`)) {
    existingSubs.add(s.attributes.productId);
  }
}
const iapIds = new Set(existingIaps.map((i: Json) => i.attributes.productId));

if (mode === "plan") {
  console.log(
    `Existing: ${groups.length} subscription group(s), ${existingSubs.size} subscription(s), ${iapIds.size} in-app purchase(s)`,
  );
  // Price points are per product, so check against an existing product if there is one; otherwise
  // report the grid from the app-level endpoint for consumables.
  const grid = await all(`/v1/apps/${app.id}/appPricePoints?filter[territory]=${BASE_TERRITORY}&limit=200`);
  const prices = new Set(grid.map((p: Json) => p.attributes.customerPrice));
  for (const item of [...SUBSCRIPTIONS, ...CONSUMABLES]) {
    const status = iapIds.has(item.productId) || existingSubs.has(item.productId) ? "exists" : "to create";
    console.log(
      `  ${item.productId.padEnd(32)} €${item.price.padEnd(6)} ${
        prices.has(item.price) ? "price OK" : "PRICE NOT ON APPLE'S GRID"
      }  ${status}`,
    );
  }
  Deno.exit(0);
}

if (mode !== "apply") throw new Error(`Unknown mode ${mode}`);

const territories = (await all(`/v1/territories?limit=200`)).map((t: Json) => ({ type: "territories", id: t.id }));

// Consumables: product, localization, availability everywhere, price in France (Apple derives the rest).
for (const c of CONSUMABLES) {
  if (iapIds.has(c.productId)) {
    console.log(`= ${c.productId} exists`);
    continue;
  }
  const iap = (await api("POST", "/v2/inAppPurchases", {
    data: {
      type: "inAppPurchases",
      attributes: { name: c.name, productId: c.productId, inAppPurchaseType: "CONSUMABLE" },
      relationships: { app: { data: { type: "apps", id: app.id } } },
    },
  })).data;
  await api("POST", "/v1/inAppPurchaseLocalizations", {
    data: {
      type: "inAppPurchaseLocalizations",
      attributes: { locale: LOCALE, name: c.name, description: c.description },
      relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap.id } } },
    },
  });
  await api("POST", "/v1/inAppPurchaseAvailabilities", {
    data: {
      type: "inAppPurchaseAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id: iap.id } },
        availableTerritories: { data: territories },
      },
    },
  });
  const point = await pricePoint(`/v2/inAppPurchases/${iap.id}/pricePoints`, c.price);
  await api("POST", "/v1/inAppPurchasePriceSchedules", {
    data: {
      type: "inAppPurchasePriceSchedules",
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id: iap.id } },
        baseTerritory: { data: { type: "territories", id: BASE_TERRITORY } },
        manualPrices: { data: [{ type: "inAppPurchasePrices", id: "${price}" }] },
      },
    },
    included: [{
      type: "inAppPurchasePrices",
      id: "${price}",
      attributes: { startDate: null },
      relationships: { inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point.id } } },
    }],
  });
  console.log(`+ ${c.productId} €${point.price}${point.exact ? "" : ` (nearest to €${c.price})`}`);
}

// Subscriptions: group (+ localization), then each subscription with localization, availability and a
// price in every territory, equalized from the French price like the website does.
let group = groups.find((g: Json) => g.attributes.referenceName === GROUP.referenceName);
if (!group) {
  group = (await api("POST", "/v1/subscriptionGroups", {
    data: {
      type: "subscriptionGroups",
      attributes: { referenceName: GROUP.referenceName },
      relationships: { app: { data: { type: "apps", id: app.id } } },
    },
  })).data;
  await api("POST", "/v1/subscriptionGroupLocalizations", {
    data: {
      type: "subscriptionGroupLocalizations",
      attributes: { locale: LOCALE, name: GROUP.displayName },
      relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: group.id } } },
    },
  });
  console.log(`+ subscription group ${GROUP.referenceName}`);
}

for (const s of SUBSCRIPTIONS) {
  if (existingSubs.has(s.productId)) {
    console.log(`= ${s.productId} exists`);
    continue;
  }
  const sub = (await api("POST", "/v1/subscriptions", {
    data: {
      type: "subscriptions",
      attributes: {
        name: s.name,
        productId: s.productId,
        subscriptionPeriod: s.period,
        groupLevel: 1,
        familySharable: false,
      },
      relationships: { group: { data: { type: "subscriptionGroups", id: group.id } } },
    },
  })).data;
  await api("POST", "/v1/subscriptionLocalizations", {
    data: {
      type: "subscriptionLocalizations",
      attributes: { locale: LOCALE, name: s.name, description: SUBSCRIPTION_DESCRIPTION },
      relationships: { subscription: { data: { type: "subscriptions", id: sub.id } } },
    },
  });
  await api("POST", "/v1/subscriptionAvailabilities", {
    data: {
      type: "subscriptionAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        subscription: { data: { type: "subscriptions", id: sub.id } },
        availableTerritories: { data: territories },
      },
    },
  });
  const point = await pricePoint(`/v1/subscriptions/${sub.id}/pricePoints`, s.price);
  const equalized = await all(`/v1/subscriptionPricePoints/${point.id}/equalizations?limit=200`);
  let priced = 0;
  for (
    const p of [
      { id: point.id, territory: BASE_TERRITORY },
      ...equalized.map((e: Json) => ({ id: e.id, territory: e.relationships?.territory?.data?.id })),
    ]
  ) {
    await api("POST", "/v1/subscriptionPrices", {
      data: {
        type: "subscriptionPrices",
        attributes: { startDate: null, preserveCurrentPrice: false },
        relationships: {
          subscription: { data: { type: "subscriptions", id: sub.id } },
          subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: p.id } },
          ...(p.territory ? { territory: { data: { type: "territories", id: p.territory } } } : {}),
        },
      },
    });
    priced++;
  }
  console.log(
    `+ ${s.productId} €${point.price}${
      point.exact ? "" : ` (nearest to €${s.price})`
    }, priced in ${priced} territories`,
  );
}

console.log("Done. Screenshots for review are added on the website before the first submission.");
