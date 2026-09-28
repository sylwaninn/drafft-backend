import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { type Fetch, readState, RevenueCatError } from "./revenuecat.ts";

const me = "0B6F1F5E-8F0C-4A5E-9D3B-2F8A1C7E4D10";
const expires = Date.UTC(2030, 0, 1);

function fake(routes: Record<string, unknown>, calls: string[] = []): Fetch {
  return ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push(url);
    assertEquals(new Headers(init?.headers).get("authorization"), "Bearer sk_test");
    const path = new URL(url).pathname + new URL(url).search;
    if (!(path in routes)) return Promise.resolve(new Response("{}", { status: 404 }));
    const body = routes[path];
    if (typeof body === "number") {
      return Promise.resolve(new Response("{}", { status: body, headers: { "retry-after": "3" } }));
    }
    return Promise.resolve(Response.json(body));
  }) as Fetch;
}

const project = "/v2/projects/proj1";
const customer = `${project}/customers/${me.toLowerCase()}`;
const catalog = {
  [`${project}/products?limit=100`]: {
    items: [{ id: "prod_sl3", store_identifier: "so.drafft.app.superlike.3" }, {
      id: "prod_m",
      store_identifier: "so.drafft.app.tempo.monthly",
    }],
  },
  [`${project}/entitlements?limit=100`]: {
    items: [{ id: "entl_other", lookup_key: "other" }, { id: "entl_t", lookup_key: "drafft_tempo" }],
  },
};

Deno.test("readState maps purchases to store ids and copies the drafft_tempo expiry", async () => {
  const calls: string[] = [];
  const state = await readState(
    fake({
      ...catalog,
      [`${customer}/purchases?limit=100`]: {
        items: [{
          product_id: "prod_sl3",
          store_purchase_identifier: "2000001",
          status: "owned",
          environment: "production",
        }],
        next_page: `${customer}/purchases?limit=100&starting_after=p1`,
      },
      [`${customer}/purchases?limit=100&starting_after=p1`]: {
        items: [
          {
            product_id: "prod_sl3",
            store_purchase_identifier: "2000002",
            status: "refunded",
            environment: "production",
          },
          {
            product_id: "prod_unknown",
            store_purchase_identifier: "2000003",
            status: "owned",
            environment: "production",
          },
        ],
      },
      [`${customer}/active_entitlements?limit=100`]: { items: [{ entitlement_id: "entl_t", expires_at: expires }] },
      [`${customer}/subscriptions?limit=100`]: { items: [{ environment: "production", gives_access: true }] },
    }, calls),
    "sk_test",
    "proj1",
    me,
    "PRODUCTION",
  );
  assertEquals(state, {
    purchases: [
      {
        transaction_id: "2000001",
        product_id: "so.drafft.app.superlike.3",
        status: "owned",
        environment: "production",
      },
      {
        transaction_id: "2000002",
        product_id: "so.drafft.app.superlike.3",
        status: "refunded",
        environment: "production",
      },
    ],
    premium_expires_at: new Date(expires).toISOString(),
  });
  assertEquals(calls.every((c) => c.startsWith("https://api.revenuecat.com/v2/")), true);
});

Deno.test("readState gives no premium from another environment's subscription", async () => {
  const state = await readState(
    fake({
      ...catalog,
      [`${customer}/active_entitlements?limit=100`]: { items: [{ entitlement_id: "entl_t", expires_at: expires }] },
      [`${customer}/subscriptions?limit=100`]: { items: [{ environment: "sandbox", gives_access: true }] },
    }),
    "sk_test",
    "proj1",
    me,
    "PRODUCTION",
  );
  assertEquals(state.premium_expires_at, null);
});

Deno.test("readState treats an unknown customer as no purchases", async () => {
  assertEquals(await readState(fake(catalog), "sk_test", "proj1", me, "PRODUCTION"), {
    purchases: [],
    premium_expires_at: null,
  });
});

Deno.test("readState fails on a RevenueCat error", async () => {
  await assertRejects(
    () =>
      readState(
        fake({ ...catalog, [`${customer}/purchases?limit=100`]: 429 }),
        "sk_test",
        "proj1",
        me,
        "PRODUCTION",
      ),
    RevenueCatError,
    "429 retry-after 3",
  );
});
