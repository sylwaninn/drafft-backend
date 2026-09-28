import { createClient } from "npm:@supabase/supabase-js@2";
import { env, optionalEnv } from "./env.ts";
import { HttpError } from "./http.ts";

/**
 * The key that bypasses RLS: the `sb_secret_…` key Supabase injects (SUPABASE_SECRET_KEYS, JSON by key
 * name). The legacy service_role key is disabled on both projects; locally, `supabase start` still has it.
 */
export function secretKey(): string {
  const injected = optionalEnv("SUPABASE_SECRET_KEYS");
  if (injected) {
    const keys = JSON.parse(injected) as Record<string, string>;
    const key = keys.default ?? Object.values(keys)[0];
    if (key) return key;
  }
  return env("SUPABASE_SERVICE_ROLE_KEY");
}

/** Service-role client: bypasses RLS. Server-side only. */
export const admin = createClient(env("SUPABASE_URL"), secretKey(), {
  auth: { persistSession: false, autoRefreshToken: false },
});

/** The signed-in caller, from the Authorization header. */
export async function requireUser(req: Request): Promise<{ id: string }> {
  const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) throw new HttpError(401, "unauthenticated");
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data.user) throw new HttpError(401, "unauthenticated");
  return { id: data.user.id };
}

/** Returns the data of a read, throwing on an error or a missing row. */
export function must<T>(result: { data: T; error: { message: string } | null }, what: string): NonNullable<T> {
  check(result, what);
  if (result.data === null || result.data === undefined) throw new Error(`${what}: not found`);
  return result.data;
}

/** Throws on the error of a write. */
export function check(result: { error: { message: string } | null }, what: string): void {
  if (result.error) throw new Error(`${what}: ${result.error.message}`);
}
