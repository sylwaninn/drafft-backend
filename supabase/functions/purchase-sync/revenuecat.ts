// Reads one customer's purchases from RevenueCat's REST API v2, as the state apply_purchase_sync applies.
// Consumables are keyed by their App Store transaction (store_purchase_identifier), like the webhook's
// transaction_id; premium is the drafft_tempo entitlement's expiry, when it is active in this environment.

const API = "https://api.revenuecat.com";
const PREMIUM_ENTITLEMENT = "drafft_tempo";
const MAX_PAGES = 10;

export type Fetch = typeof fetch;

export interface SyncState {
  purchases: { transaction_id: string; product_id: string; status: string; environment: string }[];
  premium_expires_at: string | null;
}

/** RevenueCat didn't answer as expected: the caller answers 503 and the webhook still credits later. */
export class RevenueCatError extends Error {}

interface List<T> {
  items: T[];
  next_page?: string | null;
}

export async function readState(
  fetcher: Fetch,
  secretKey: string,
  projectId: string,
  userId: string,
  environment: string,
): Promise<SyncState> {
  const project = `/v2/projects/${encodeURIComponent(projectId)}`;
  const customer = `${project}/customers/${encodeURIComponent(userId.toLowerCase())}`;

  async function list<T>(path: string, optional = false): Promise<T[]> {
    const items: T[] = [];
    let next: string | null | undefined = path;
    for (let page = 0; next && page < MAX_PAGES; page++) {
      const res: Response = await fetcher(`${API}${next}`, {
        headers: { authorization: `Bearer ${secretKey}`, accept: "application/json" },
      });
      // A person who never opened the store is not a RevenueCat customer yet.
      if (res.status === 404 && optional) {
        await res.body?.cancel();
        return [];
      }
      if (!res.ok) {
        const retry = res.headers.get("retry-after");
        throw new RevenueCatError(`GET ${next.split("?")[0]}: ${res.status}${retry ? ` retry-after ${retry}` : ""}`);
      }
      const body = await res.json() as List<T>;
      items.push(...(body.items ?? []));
      next = body.next_page;
    }
    return items;
  }

  const [purchases, active, subscriptions, products, entitlements] = await Promise.all([
    list<{ product_id: string; store_purchase_identifier?: string; status?: string; environment?: string }>(
      `${customer}/purchases?limit=100`,
      true,
    ),
    list<{ entitlement_id: string; expires_at?: number | null }>(`${customer}/active_entitlements?limit=100`, true),
    list<{ environment?: string; gives_access?: boolean }>(`${customer}/subscriptions?limit=100`, true),
    list<{ id: string; store_identifier?: string }>(`${project}/products?limit=100`),
    list<{ id: string; lookup_key?: string }>(`${project}/entitlements?limit=100`),
  ]);

  const storeId = new Map(products.map((p) => [p.id, p.store_identifier]));
  const env = environment.toLowerCase();

  const premiumId = entitlements.find((e) => e.lookup_key === PREMIUM_ENTITLEMENT)?.id;
  const expires = active.find((e) => e.entitlement_id === premiumId)?.expires_at;
  const inEnvironment = subscriptions.some((s) => s.gives_access && s.environment?.toLowerCase() === env);

  return {
    purchases: purchases.flatMap((p) => {
      const product = storeId.get(p.product_id);
      if (!product || !p.store_purchase_identifier || !p.status || !p.environment) return [];
      return [{
        transaction_id: p.store_purchase_identifier,
        product_id: product,
        status: p.status,
        environment: p.environment,
      }];
    }),
    premium_expires_at: premiumId && expires && inEnvironment ? new Date(expires).toISOString() : null,
  };
}
