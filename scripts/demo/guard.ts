// Keeps the demo scripts (demo-profiles.ts, demo-interact.ts) away from production. They write fake people,
// fake likes and chat messages: on production that would reach real members. Four independent checks, any
// one of which stops the script before it writes anything:
//
// 1. The target is "staging"; there is no production target at all.
// 2. The env file is staging's: R2_BUCKET is the staging bucket, and no variable mentions the production
//    project. So the R2 and Stream credentials in use are staging's.
// 3. Staging is reached by linking the CLI to the staging ref, hard-coded here.
// 4. The database itself is asked who it is: its `edge_functions_url` Vault secret (set once per project,
//    sync-vault.sh and docs/environments.md) must name the staging project, and never the production one.

export const STAGING_REF = "rjlghcuspdtrmbimyioe";
const PRODUCTION_REF = "wrcpgnqwjmnirjfxpcux";
const STAGING_BUCKET = "drafft-media-staging";

export type Target = "staging";

function stop(reason: string): never {
  console.error(`Stopped: ${reason}. The demo scripts only run on staging.`);
  Deno.exit(1);
}

async function cli(args: string[]): Promise<string> {
  const { code, stdout } = await new Deno.Command("supabase", { args, stdout: "piped", stderr: "inherit" }).output();
  if (code !== 0) stop(`supabase ${args[0]} failed`);
  return new TextDecoder().decode(stdout);
}

/** Runs every check; returns only when the script is on staging. Never prints a secret. */
export async function guard(target: string): Promise<Target> {
  if (target !== "staging") stop(`unknown target "${target}"`);

  if (Deno.env.get("R2_BUCKET") !== STAGING_BUCKET) stop(`R2_BUCKET isn't ${STAGING_BUCKET}`);
  for (const [name, value] of Object.entries(Deno.env.toObject())) {
    if (value.includes(PRODUCTION_REF)) stop(`${name} points at the production project`);
  }

  await cli(["link", "--project-ref", STAGING_REF]);

  const dir = await Deno.makeTempDir({ prefix: "demo-guard-" });
  try {
    const file = `${dir}/whoami.sql`;
    await Deno.writeTextFile(
      file,
      "select decrypted_secret as url from vault.decrypted_secrets where name = 'edge_functions_url';\n",
    );
    const out = await cli([
      "db",
      "query",
      "--linked",
      "--agent=no",
      "-o",
      "json",
      "-f",
      file,
    ]);
    const start = out.indexOf("[");
    const rows = start < 0 ? [] : JSON.parse(out.slice(start)) as { url?: string }[];
    const url = rows[0]?.url ?? "";
    if (url.includes(PRODUCTION_REF)) stop("the database is production");
    if (!url.includes(STAGING_REF)) stop(`the database doesn't say it is ${target}`);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
  return target;
}
