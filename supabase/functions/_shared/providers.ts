// The outside services side effects depend on, and how their failures are told apart. Each has a circuit
// breaker in the database (private.provider_circuits, migration 20260928000121): a transient failure (the
// provider is down: 5xx, 429, a timeout, the network) counts towards opening it; a refusal of one request
// (4xx) doesn't, it's this event's problem, not the provider's.
//
// db-events runs each handler inside `trackProviders`, which collects the providers it reached: their
// successes close a half-open circuit, the failure that stopped the handler names its provider.
import { AsyncLocalStorage } from "node:async_hooks";

export type Provider = "stream" | "apns" | "resend" | "twilio" | "r2";

export class ProviderError extends Error {
  constructor(
    readonly provider: Provider,
    readonly transient: boolean,
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "ProviderError";
  }
}

/** 408, 425, 429 and 5xx: the provider, not the request. */
export function transientStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

/** Whether an error thrown by a client (fetch, an SDK) means the provider is unreachable or down. */
export function isTransient(error: unknown): boolean {
  if (error instanceof ProviderError) return error.transient;
  const e = error as { status?: unknown; response?: { status?: unknown }; name?: unknown; message?: unknown } | null;
  const status = typeof e?.status === "number"
    ? e.status
    : typeof e?.response?.status === "number"
    ? e.response.status
    : undefined;
  if (status !== undefined) return transientStatus(status);
  const name = String(e?.name ?? "");
  if (name === "TypeError" || name === "AbortError" || name === "TimeoutError") return true;
  return /network|timed? ?out|ECONN|ENOTFOUND|EAI_AGAIN|socket hang up|fetch failed|connection/i.test(
    String(e?.message ?? error),
  );
}

const reached = new AsyncLocalStorage<Set<Provider>>();

/** Runs `fn`, adding the providers it reaches successfully to `into` (kept when `fn` fails). */
export function trackProviders<T>(into: Set<Provider>, fn: () => Promise<T>): Promise<T> {
  return reached.run(into, fn);
}

/** Records a successful call to a provider. */
export function reachedProvider(provider: Provider) {
  reached.getStore()?.add(provider);
}

/** Calls a provider: its success is recorded, its failure becomes a ProviderError naming it. */
export async function viaProvider<T>(provider: Provider, fn: () => Promise<T>): Promise<T> {
  try {
    const result = await fn();
    reachedProvider(provider);
    return result;
  } catch (error) {
    if (error instanceof ProviderError) throw error;
    const message = error instanceof Error ? error.message : String(error);
    const status = (error as { status?: unknown } | null)?.status;
    throw new ProviderError(
      provider,
      isTransient(error),
      `${provider}: ${message}`,
      typeof status === "number" ? status : undefined,
    );
  }
}

/** Throws a ProviderError for a failed response; records the provider as reached otherwise. */
export async function checkResponse(provider: Provider, res: Response, what: string): Promise<Response> {
  if (res.ok) {
    reachedProvider(provider);
    return res;
  }
  const text = (await res.text().catch(() => "")).slice(0, 300);
  throw new ProviderError(provider, transientStatus(res.status), `${what} ${res.status}: ${text}`, res.status);
}
