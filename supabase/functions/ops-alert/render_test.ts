import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { renderOpsAlert } from "./render.ts";

Deno.test("an incident lists counts, events and providers", () => {
  const email = renderOpsAlert("incident", 7, {
    failed: 3,
    failedByEvent: { "match.created": 2, "support.reply": 1 },
    openCircuits: ["stream"],
    oldestFailedAt: "2026-09-28T10:00:00Z",
  });
  assertEquals(email.subject, "[outbox] incident #7");
  assertStringIncludes(email.text, "match.created: 2");
  assertStringIncludes(email.text, "Providers down:\nstream");
  assertStringIncludes(email.text, "2026-09-28 10:00 UTC");
});

Deno.test("nothing but known shapes reaches the email", () => {
  const email = renderOpsAlert("incident", 1, {
    failedByEvent: { "ana@example.com": 1, "profile 0b6f: boom": 1 },
    // deno-lint-ignore no-explicit-any
    openCircuits: ["stream", "someone@else.dev"] as any,
    // deno-lint-ignore no-explicit-any
    ...({ lastError: "resend 422: to lea@support.test invalid", payload: { userId: "x" } } as any),
  });
  assert(!email.text.includes("@"), email.text);
  assert(!email.html.includes("lea@support"), "no error text");
});

Deno.test("a reminder and a daily summary", () => {
  assertEquals(
    renderOpsAlert("reminder", 2, { openedAt: "2026-09-28T09:00:00Z" }).subject,
    "[outbox] incident #2 still open",
  );
  const daily = renderOpsAlert("daily", null, { delivered: 120, expired: 2, newlyFailed: 1 });
  assertEquals(daily.subject, "[outbox] daily summary");
  assertStringIncludes(daily.text, "Delivered: 120");
  assertStringIncludes(daily.text, "Dropped as stale: 2");
});
