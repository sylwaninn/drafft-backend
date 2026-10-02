// Loads the areas of France into private.areas, for area_at (migration 20260930000701): every commune, with
// Paris, Lyon and Marseille split into their arrondissements ("Paris 11", "Lyon 4", "Marseille 1").
//
//   deno run -A scripts/load-areas.ts staging
//   deno run -A scripts/load-areas.ts production
//
// deploy.sh runs it after the migrations (with --yes): it loads only when the database differs from the source
// (codes and names), so a deploy costs one download and one query. Bump YEAR once a year, when communes merge.
// Rows are upserted by INSEE code, and codes gone from the source are removed at the end.
// Source (Licence Ouverte): Etalab's boundaries of communes and arrondissements, simplified to 100 m.
// The database is reached through the Management API (`supabase db query --linked`); the CLI is linked back to
// staging on the way out, as in deploy.sh.

const YEAR = 2025;
const COMMUNES_URL =
  `https://etalab-datasets.geo.data.gouv.fr/contours-administratifs/${YEAR}/geojson/communes-100m.geojson.gz`;
// Paris, Lyon, Marseille: their arrondissements' codes follow the city's, numbered from 1.
const PLM: Record<string, { city: string; first: number }> = {
  "75056": { city: "Paris", first: 75101 },
  "69123": { city: "Lyon", first: 69381 },
  "13055": { city: "Marseille", first: 13201 },
};
const PRODUCTION_REF = "wrcpgnqwjmnirjfxpcux";
const STAGING_REF = "rjlghcuspdtrmbimyioe";
// Rows per statement: each file sent stays around 500 KB, small next to request size limits.
const CHUNK = 500;

interface Feature {
  properties: Record<string, unknown>;
  geometry: { type: string; coordinates: unknown };
}
interface Row {
  code: string;
  name: string;
  city: string;
  geometry: Feature["geometry"];
}

async function download(): Promise<Feature[]> {
  const res = await fetch(COMMUNES_URL);
  if (!res.ok || !res.body) {
    throw new Error(`${COMMUNES_URL}: HTTP ${res.status}`);
  }
  const body = res.body.pipeThrough(new DecompressionStream("gzip"));
  return (await new Response(body).json()).features as Feature[];
}

// The source lists Paris, Lyon and Marseille twice: whole ("Paris") and by arrondissement ("Paris 11e
// Arrondissement", its city in `commune`). Only the arrondissements are kept, named the app's way.
function rows(features: Feature[]): Row[] {
  const out: Row[] = [];
  for (const f of features) {
    const code = String(f.properties.code);
    if (PLM[code]) continue;
    const plm = PLM[String(f.properties.commune ?? "")];
    const name = plm ? `${plm.city} ${Number(code) - plm.first + 1}` : String(f.properties.nom);
    out.push({ code, name, city: plm?.city ?? name, geometry: f.geometry });
  }
  return out;
}

function literal(s: string): string {
  return `'${s.replaceAll("'", "''")}'`;
}

// Made valid, kept as polygons only: simplified boundaries can cross themselves.
function upsert(chunk: Row[]): string {
  const values = chunk.map((r) =>
    `(${literal(r.code)}, ${literal(r.name)}, ${
      literal(r.city)
    }, extensions.st_multi(extensions.st_collectionextract(` +
    `extensions.st_makevalid(extensions.st_setsrid(extensions.st_geomfromgeojson(${
      literal(JSON.stringify(r.geometry))
    }), 4326)), 3)))`
  );
  return `insert into private.areas (code, name, city, geom) values\n${values.join(",\n")}\n` +
    "on conflict (code) do update set name = excluded.name, city = excluded.city, geom = excluded.geom;\n";
}

// Runs the CLI; returns what it printed (the query's CSV).
async function supabase(args: string[]): Promise<string> {
  const { code, stdout } = await new Deno.Command("supabase", {
    args,
    stdout: "piped",
    stderr: "inherit",
  }).output();
  if (code !== 0) {
    throw new Error(`supabase ${args.join(" ")} failed (${code})`);
  }
  return new TextDecoder().decode(stdout);
}

// What is loaded, codes and names in code order: the same in the database and in the source means nothing to do.
const FINGERPRINT = "string_agg(code || ':' || name, ',' order by code collate \"C\")";

async function fingerprint(all: Row[]): Promise<string> {
  const text = [...all].sort((a, b) => a.code < b.code ? -1 : 1).map((r) => `${r.code}:${r.name}`).join(",");
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(text),
  );
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const [env, ...flags] = Deno.args;
const ref = env === "production" ? PRODUCTION_REF : env === "staging" ? STAGING_REF : undefined;
if (ref === undefined) {
  console.error(
    "Usage: deno run -A scripts/load-areas.ts staging|production [--yes]",
  );
  Deno.exit(64);
}
// --yes: deploy.sh, which has asked already.
if (
  env === "production" && !flags.includes("--yes") &&
  prompt(`Load areas into PRODUCTION (${ref})? Type 'production' to go on:`) !==
    "production"
) {
  console.log("Stopped.");
  Deno.exit(1);
}

const all = rows(await download());
if (all.length < 30_000) {
  throw new Error(`only ${all.length} areas downloaded: stopped`);
}
const dir = await Deno.makeTempDir({ prefix: "areas-" });
const query = (file: string) => supabase(["db", "query", "--linked", "--agent=no", "-o", "csv", "-f", file]);
try {
  await supabase(["link", "--project-ref", ref]);
  const check = `${dir}/check.sql`;
  await Deno.writeTextFile(
    check,
    `select encode(extensions.digest(coalesce(${FINGERPRINT}, ''), 'sha256'), 'hex') as fingerprint from private.areas;\n`,
  );
  if ((await query(check)).includes(await fingerprint(all))) {
    console.log(`Areas already up to date in ${env}.`);
  } else {
    for (let i = 0; i < all.length; i += CHUNK) {
      const file = `${dir}/${i}.sql`;
      await Deno.writeTextFile(file, upsert(all.slice(i, i + CHUNK)));
      await query(file);
      console.log(`${Math.min(i + CHUNK, all.length)} / ${all.length}`);
    }
    const file = `${dir}/stale.sql`;
    await Deno.writeTextFile(
      file,
      `delete from private.areas where code <> all (array[${all.map((r) => literal(r.code)).join(",")}]);\n`,
    );
    await query(file);
    console.log(`Loaded ${all.length} areas into ${env}.`);
  }
} finally {
  await Deno.remove(dir, { recursive: true });
  if (ref !== STAGING_REF) {
    await supabase(["link", "--project-ref", STAGING_REF]).catch(() =>
      console.error(
        `warning: couldn't link the CLI back to staging: run supabase link --project-ref ${STAGING_REF}`,
      )
    );
  }
}
