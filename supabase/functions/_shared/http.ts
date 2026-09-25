/** Error the client can act on: `code` is stable, the app switches on it. */
export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message = code) {
    super(message);
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Wraps a handler: HttpError becomes its status and code, anything else a logged 500. */
export function serve(handler: (req: Request) => Promise<Response>) {
  Deno.serve(async (req) => {
    try {
      return await handler(req);
    } catch (error) {
      if (error instanceof HttpError) {
        return json({ code: error.code, message: error.message }, error.status);
      }
      console.error(error);
      return json({ code: "internal", message: "Something went wrong" }, 500);
    }
  });
}

export async function readJson<T>(req: Request): Promise<T> {
  if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
  try {
    return await req.json() as T;
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}

/** Constant-time comparison for shared secrets. */
export function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}
