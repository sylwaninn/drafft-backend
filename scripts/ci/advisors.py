#!/usr/bin/env python3
"""Supabase's security and performance advisors, as a gate.

Reads `supabase db advisors -o json` output on stdin (the local database built from the migrations,
or --linked for a real project) and fails on any finding that isn't accepted in
supabase/advisors-baseline.json, with a reason. Existing, deliberate findings stay accepted; a new
table without RLS, a new unindexed foreign key or a new exposed SECURITY DEFINER function fails.

    supabase db advisors --local --level info -o json | python3 scripts/ci/advisors.py
    python3 scripts/ci/advisors.py --write-baseline < advisors.json   # after reviewing each one
"""
import json
import pathlib
import sys

BASELINE = pathlib.Path(__file__).resolve().parents[2] / "supabase/advisors-baseline.json"
# INFO-level findings that still matter: scalability and access control.
WATCHED_INFO = {
    "unindexed_foreign_keys",
    "duplicate_index",
    "multiple_permissive_policies",
    "rls_enabled_no_policy",
    "no_primary_key",
}
# Depend on traffic or hosted settings, not on the schema: meaningless on a fresh database.
IGNORED = {"unused_index", "auth_db_connections_absolute", "auth_leaked_password_protection"}


def findings(text: str) -> list[dict]:
    start = text.find("[")
    if start < 0:
        return []
    items = json.loads(text[start:])
    return [
        f for f in items
        if f["name"] not in IGNORED and (f["level"] in ("WARN", "ERROR") or f["name"] in WATCHED_INFO)
    ]


def main() -> int:
    current = findings(sys.stdin.read())
    if "--write-baseline" in sys.argv:
        old = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
        baseline = {
            f["cache_key"]: old.get(f["cache_key"], "TODO: why this is acceptable")
            for f in sorted(current, key=lambda f: f["cache_key"])
        }
        BASELINE.write_text(json.dumps(baseline, indent=2) + "\n")
        print(f"advisors: wrote {len(baseline)} accepted finding(s) to {BASELINE.name}")
        return 0

    accepted = json.loads(BASELINE.read_text())
    new = [f for f in current if f["cache_key"] not in accepted]
    for f in new:
        print(f"error: [{f['level']}] {f['name']}: {f['detail']}\n  fix: {f['remediation']}")
    gone = sorted(set(accepted) - {f["cache_key"] for f in current})
    for key in gone:
        print(f"note: fixed, remove it from {BASELINE.name}: {key}")
    print(f"advisors: {len(current)} finding(s), {len(new)} new.")
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
