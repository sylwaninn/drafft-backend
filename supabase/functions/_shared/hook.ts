// Supabase Auth hooks (Send Email, Send SMS): signed with Standard Webhooks, answered with `{}` or
// `{ error: { http_code, message } }`, which Auth passes on to the app.
import { Webhook } from "npm:standardwebhooks@1.0.0";
import { env } from "./env.ts";

/** The verified payload, or null when the signature doesn't check out (logged). */
export async function verifyHook<T>(req: Request, secretName: string, name: string): Promise<T | null> {
  try {
    const secret = env(secretName).replace("v1,whsec_", "");
    return new Webhook(secret).verify(await req.text(), Object.fromEntries(req.headers)) as T;
  } catch (error) {
    console.error(`${name}: rejected`, error instanceof Error ? error.message : error);
    return null;
  }
}

export function hookOk(): Response {
  return new Response("{}", { headers: { "content-type": "application/json" } });
}

export function hookError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: { http_code: status, message } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
