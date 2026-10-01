// Demo people around Lyon, to try the app with a full Discover: complete, onboarded profiles with photos,
// sports, prompts and a location. Staging and local only: demo/guard.ts stops it anywhere else.
//
//   deno run -A --env-file=supabase/functions/.env.staging scripts/demo-profiles.ts staging seed [count]
//   deno run -A --env-file=supabase/functions/.env.staging scripts/demo-profiles.ts staging refresh
//   deno run -A --env-file=supabase/functions/.env.staging scripts/demo-profiles.ts staging purge
//   deno run -A --env-file=supabase/functions/.env.staging scripts/demo-profiles.ts staging thumbhash
//   deno run -A --env-file=supabase/functions/.env scripts/demo-profiles.ts local seed
//
// seed: creates the missing demo people (100 by default, from scripts/demo/personas.ts); run it again and it
// only adds who is missing. refresh: marks them active again (Discover hides people inactive for 30 days).
// purge: deletes them all, their photos with them. thumbhash: gives the demo photos inserted without a
// ThumbHash (before seed computed it) theirs, read from the files in R2; run it again and it changes nothing.
//
// How: each person is written straight into the database, as onboarding would leave them, through the
// Management API (`supabase db query --linked`, the CLI's own login, no Supabase key). Accounts are
// `demoNNN@drafft.test` (a reserved domain: the mailer never writes to it) with a confirmed email and a
// confirmed fictional phone number (ARCEP's +33 6 39 98 range), and no password: nobody signs in as them.
// Photos are a few free pictures (Picsum, Unsplash licence) reused across everyone, uploaded to R2 under
// `u/<id>/demo/` (the folder media_key_shape keeps for demo accounts) and inserted approved, so no
// moderation runs. Each photo carries the ThumbHash the app would compute (the placeholder of cards and of
// blurred likes), from the same file: decoded (jpeg-js), scaled down to 100 px, encoded (thumbhash), so the
// same picture always gets the same hash. Locations are spread over Lyon and its suburbs, weighted like where people live.
//
// Reads R2_* from the env file and never prints them.
import { AwsClient } from "npm:aws4fetch@1";
import jpeg from "npm:jpeg-js@0.4.4";
import { rgbaToThumbHash } from "npm:thumbhash@0.1.1";
import { personas } from "./demo/personas.ts";
import { guard } from "./demo/guard.ts";

const TERMS_VERSION = "2026-09-29";
const DOMAIN = "drafft.test";
// Picsum ids (landscapes and outdoor scenes), cropped to the app's 4:5 portrait.
const PHOTOS = [1015, 1018, 1036, 1039, 1043];
const WIDTH = 1080, HEIGHT = 1350;
const USERS_PER_QUERY = 20;

// [name, lat, lng, radius km, weight]: Lyon's arrondissements, Villeurbanne and the suburbs around.
const ZONES: [string, number, number, number, number][] = [
  ["Lyon 1", 45.770, 4.830, 0.6, 6],
  ["Lyon 2", 45.750, 4.827, 0.9, 7],
  ["Lyon 3", 45.759, 4.860, 1.1, 10],
  ["Lyon 4", 45.779, 4.827, 0.7, 6],
  ["Lyon 5", 45.758, 4.803, 0.9, 5],
  ["Lyon 6", 45.770, 4.852, 0.8, 8],
  ["Lyon 7", 45.740, 4.840, 1.2, 10],
  ["Lyon 8", 45.735, 4.870, 1.1, 6],
  ["Lyon 9", 45.775, 4.805, 1.1, 5],
  ["Villeurbanne", 45.771, 4.890, 1.6, 10],
  ["Caluire", 45.796, 4.846, 1.1, 4],
  ["Écully", 45.775, 4.777, 0.9, 3],
  ["Tassin", 45.762, 4.762, 0.9, 3],
  ["Sainte-Foy", 45.734, 4.802, 0.7, 3],
  ["Oullins", 45.714, 4.807, 0.8, 3],
  ["Bron", 45.738, 4.913, 1.1, 3],
  ["Vénissieux", 45.697, 4.886, 1.2, 3],
  ["Vaulx-en-Velin", 45.778, 4.920, 1.1, 2],
  ["Décines", 45.769, 4.959, 1.1, 2],
  ["Villefranche", 45.990, 4.719, 1.5, 1],
  ["Vienne", 45.525, 4.874, 1.5, 1],
];

type Target = "staging" | "local";
const [target, command, countArg] = Deno.args as [Target, string, string?];
if (
  !["staging", "local"].includes(target) ||
  !["seed", "refresh", "purge", "thumbhash"].includes(command)
) {
  console.error(
    "Usage: deno run -A --env-file=<env file> scripts/demo-profiles.ts staging|local seed [count]|refresh|purge|thumbhash",
  );
  Deno.exit(64);
}

const env = (name: string) =>
  Deno.env.get(name) ?? (() => {
    throw new Error(`${name} is not set`);
  })();

// Never production: stops here unless the env file and the database are staging's (or local).
await guard(target);

// MARK: Database

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

const dir = await Deno.makeTempDir({ prefix: "demo-profiles-" });
let queries = 0;
/** Runs SQL, returns the CSV rows after the header. */
async function query(sql: string): Promise<string[][]> {
  const file = `${dir}/${queries++}.sql`;
  await Deno.writeTextFile(file, sql);
  const csv = await supabase([
    "db",
    "query",
    target === "staging" ? "--linked" : "--local",
    "--agent=no",
    "-o",
    "csv",
    "-f",
    file,
  ]);
  return csv.trim().split("\n").slice(1).filter(Boolean).map((line) => line.split(","));
}

const literal = (s: string) => `'${s.replaceAll("'", "''")}'`;
const json = (v: unknown) => `${literal(JSON.stringify(v))}::jsonb`;

// MARK: R2

const r2 = new AwsClient({
  accessKeyId: env("R2_ACCESS_KEY_ID"),
  secretAccessKey: env("R2_SECRET_ACCESS_KEY"),
  service: "s3",
  region: Deno.env.get("R2_REGION") ?? "auto",
});
// Locally the endpoint is the one the functions' container sees: from this machine, it is localhost.
const endpoint = (Deno.env.get("R2_ENDPOINT") ??
  `https://${env("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com`)
  .replace("host.docker.internal", "127.0.0.1");
const bucket = `${endpoint}/${env("R2_BUCKET")}`;

async function r2Get(key: string): Promise<ArrayBuffer> {
  for (let attempt = 1;; attempt++) {
    const res = await r2.fetch(`${bucket}/${key}`);
    if (res.ok) return await res.arrayBuffer();
    await res.body?.cancel();
    if (attempt === 3 || res.status < 500) {
      throw new Error(`R2 GET ${key}: ${res.status}`);
    }
  }
}

async function r2Request(
  method: "PUT" | "DELETE",
  key: string,
  body?: ArrayBuffer,
) {
  for (let attempt = 1;; attempt++) {
    const res = await r2.fetch(`${bucket}/${key}`, {
      method,
      body,
      headers: body ? { "content-type": "image/jpeg" } : undefined,
    });
    await res.body?.cancel();
    if (res.ok || (method === "DELETE" && res.status === 404)) return;
    if (attempt === 3 || res.status < 500) {
      throw new Error(`R2 ${method} ${key}: ${res.status}`);
    }
  }
}

/** Runs `work` over `items`, `limit` at a time. */
async function pool<T>(
  items: T[],
  limit: number,
  work: (item: T) => Promise<void>,
) {
  const queue = [...items];
  await Promise.all(Array.from({ length: limit }, async () => {
    for (let item = queue.shift(); item !== undefined; item = queue.shift()) {
      await work(item);
    }
  }));
}

// MARK: ThumbHash

/** The ThumbHash of a JPEG, base64 like the app sends it (add_profile_media's p_thumbhash). */
function thumbhashOf(file: ArrayBuffer): string {
  const image = jpeg.decode(new Uint8Array(file), {
    useTArray: true,
    formatAsRGBA: true,
  });
  // ThumbHash takes at most 100 x 100: a box filter down to that, keeping the aspect ratio.
  const scale = Math.min(1, 100 / Math.max(image.width, image.height));
  const w = Math.max(1, Math.round(image.width * scale)),
    h = Math.max(1, Math.round(image.height * scale));
  const rgba = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const y0 = Math.floor((y * image.height) / h),
      y1 = Math.max(y0 + 1, Math.floor(((y + 1) * image.height) / h));
    for (let x = 0; x < w; x++) {
      const x0 = Math.floor((x * image.width) / w),
        x1 = Math.max(x0 + 1, Math.floor(((x + 1) * image.width) / w));
      const sum = [0, 0, 0, 0];
      for (let sy = y0; sy < y1; sy++) {
        for (let sx = x0; sx < x1; sx++) {
          const i = (sy * image.width + sx) * 4;
          for (let c = 0; c < 4; c++) sum[c] += image.data[i + c];
        }
      }
      const n = (y1 - y0) * (x1 - x0);
      for (let c = 0; c < 4; c++) {
        rgba[(y * w + x) * 4 + c] = Math.round(sum[c] / n);
      }
    }
  }
  return btoa(String.fromCharCode(...rgbaToThumbHash(w, h, rgba)));
}

// MARK: People

// Seeded, so a person gets the same photos, place and dates on every run.
function random(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** A stable id per demo number, so R2 keys are known before the account exists. */
async function demoId(n: number): Promise<string> {
  const hash = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`drafft-demo-${n}`),
    ),
  );
  hash[6] = (hash[6] & 0x0f) | 0x40;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  const hex = [...hash.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

const pad = (n: number) => String(n).padStart(3, "0");
const email = (n: number) => `demo${pad(n)}@${DOMAIN}`;
// Exactly the accounts seed writes (demo001 to demo999), never a look-alike: purge deletes by this filter.
const DEMO_EMAILS = String.raw`email ~ '^demo[0-9]{3}@drafft\.test$'`;

interface Demo {
  n: number;
  id: string;
  persona: (typeof personas)[number];
  lat: number;
  lng: number;
  birthdate: string;
  activeHoursAgo: number;
  photos: { key: string; picsum: number }[];
}

async function demo(n: number): Promise<Demo> {
  const rand = random(n * 7919);
  const id = await demoId(n);
  const persona = personas[n - 1];

  const total = ZONES.reduce((sum, z) => sum + z[4], 0);
  let pick = rand() * total;
  const zone = ZONES.find((z) => (pick -= z[4]) < 0) ?? ZONES[0];
  // Uniform in a disc; set_location snaps to 0.01° like the app's own writes.
  const r = zone[3] * Math.sqrt(rand()), angle = rand() * 2 * Math.PI;
  const lat = zone[1] + (r / 111.32) * Math.cos(angle);
  const lng = zone[2] +
    (r / (111.32 * Math.cos(zone[1] * Math.PI / 180))) * Math.sin(angle);

  const born = new Date();
  born.setUTCFullYear(born.getUTCFullYear() - persona.age);
  born.setUTCDate(born.getUTCDate() - 1 - Math.floor(rand() * 360));

  const count = 2 + Math.floor(rand() * 4);
  const order = [...PHOTOS].sort(() => rand() - 0.5).slice(0, count);
  return {
    n,
    id,
    persona,
    lat: Math.round(lat * 100) / 100,
    lng: Math.round(lng * 100) / 100,
    birthdate: born.toISOString().slice(0, 10),
    activeHoursAgo: Math.floor(rand() * 72),
    photos: order.map((picsum, i) => ({
      key: `u/${id}/demo/p${i}-${picsum}.jpg`,
      picsum,
    })),
  };
}

function insertSql(d: Demo, hashes: Map<number, string>): string {
  const p = d.persona;
  const [chronotype, diet, drinks, smokes] = p.lifestyle;
  const genders = (g: string[]) => `array[${g.map(literal).join(",")}]::public.gender[]`;
  const point = `extensions.st_setsrid(extensions.st_makepoint(${d.lng}, ${d.lat}), 4326)::extensions.geography`;
  const phone = `3363998${pad(d.n).padStart(4, "0")}`;
  return `
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, phone,
  phone_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token,
  recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change,
  phone_change_token, reauthentication_token)
values ('00000000-0000-0000-0000-000000000000', '${d.id}', 'authenticated', 'authenticated', ${
    literal(email(d.n))
  }, '', now(), '${phone}', now(), '{"provider":"email","providers":["email"]}', '{"language":"fr","demo":true}',
  now(), now(), '', '', '', '', '', '', '', '');
insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
values ('${d.id}', '${d.id}', ${
    json({
      sub: d.id,
      email: email(d.n),
      email_verified: true,
      phone_verified: true,
    })
  }, 'email', now(), now());
update public.profiles set
  name = ${literal(p.name)}, birthdate = '${d.birthdate}', gender = '${p.gender}', interested_in = ${
    genders(p.interestedIn)
  },
  neighborhood = coalesce(public.area_at(${d.lat}, ${d.lng}) ->> 'name', 'Lyon'),
  bio = ${literal(p.bio)}, goal = ${literal(p.goal)}, favorite_spot = ${literal(p.spot)},
  chronotype = ${literal(chronotype)}, diet = ${literal(diet)}, drinks = ${literal(drinks)}, smokes = ${
    literal(smokes)
  },
  icebreaker = ${p.icebreaker ? json(p.icebreaker) : "null"}, language = 'fr',
  terms_version = '${TERMS_VERSION}', terms_accepted_at = now(), sensitive_consent_at = now()
where id = '${d.id}';
insert into public.profile_sports (user_id, sport_id, per_week, position) values ${
    p.sports.map(([sport, perWeek], i) => `('${d.id}', ${literal(sport)}, ${perWeek}, ${i})`).join(", ")
  };
insert into public.profile_prompts (user_id, position, question, answer) values ${
    p.prompts.map(([q, a], i) => `('${d.id}', ${i}, ${literal(q)}, ${literal(a)})`).join(", ")
  };
insert into public.profile_media (user_id, kind, key, position, width, height, thumbhash, status) values ${
    d.photos.map((ph, i) =>
      `('${d.id}', 'photo', ${literal(ph.key)}, ${i}, ${WIDTH}, ${HEIGHT}, ${
        literal(hashes.get(ph.picsum)!)
      }, 'approved')`
    ).join(", ")
  };
insert into private.locations (user_id, geo) values ('${d.id}', ${point});
update public.wallets set super_likes = 5 where user_id = '${d.id}';
update public.profiles set onboarded_at = now(), last_active_at = now() - interval '${d.activeHoursAgo} hours'
where id = '${d.id}';
`;
}

// MARK: Commands

async function seed() {
  const count = Number(countArg ?? 100);
  if (!Number.isInteger(count) || count < 1 || count > personas.length) {
    throw new Error(`count must be 1 to ${personas.length}`);
  }
  const existing = new Set(
    (await query(`select email from auth.users where ${DEMO_EMAILS};`)).map((
      r,
    ) => r[0]),
  );
  const missing = await Promise.all(
    Array.from({ length: count }, (_, i) => i + 1).filter((n) => !existing.has(email(n))).map(demo),
  );
  if (missing.length === 0) {
    console.log(`The ${count} demo people already exist in ${target}.`);
    return;
  }

  const images = new Map<number, ArrayBuffer>();
  for (const id of PHOTOS) {
    const res = await fetch(
      `https://picsum.photos/id/${id}/${WIDTH}/${HEIGHT}.jpg`,
    );
    if (!res.ok) throw new Error(`picsum ${id}: HTTP ${res.status}`);
    images.set(id, await res.arrayBuffer());
  }
  const hashes = new Map(
    [...images].map(([id, file]) => [id, thumbhashOf(file)]),
  );
  const uploads = missing.flatMap((d) => d.photos);
  await pool(
    uploads,
    8,
    (ph) => r2Request("PUT", ph.key, images.get(ph.picsum)),
  );
  console.log(`${uploads.length} photos uploaded.`);

  for (let i = 0; i < missing.length; i += USERS_PER_QUERY) {
    const batch = missing.slice(i, i + USERS_PER_QUERY);
    // One statement (the local API prepares it), one transaction: a batch lands whole or not at all.
    await query(
      `do $demo$ begin\n${batch.map((d) => insertSql(d, hashes)).join("")}\nend $demo$;\n`,
    );
    console.log(
      `${Math.min(i + USERS_PER_QUERY, missing.length)} / ${missing.length} people created`,
    );
  }

  // What Discover needs to show someone (private.eligible): onboarded, a portrait, a location.
  const [[visible]] = await query(`
select count(*) from public.profiles p join auth.users u on u.id = p.id
where u.${DEMO_EMAILS} and p.onboarded_at is not null and p.photo_count > 0 and not p.paused
  and private.portrait(p.id) is not null and exists (select 1 from private.locations l where l.user_id = p.id);`);
  console.log(`${visible} demo people visible in Discover in ${target}.`);
}

async function refresh() {
  await query(`
update public.profiles set last_active_at = now() - random() * interval '3 days'
where id in (select id from auth.users where ${DEMO_EMAILS});`);
  console.log(`Demo people active again in ${target}.`);
}

async function purge() {
  const keys = (await query(
    `select m.key from public.profile_media m join auth.users u on u.id = m.user_id where u.${DEMO_EMAILS};`,
  )).map((r) => r[0]);
  // Their matches end first, as an account erasure does (retention_purges): the other person's apps drop the
  // chat live (match_ended) and upcoming sessions are cancelled. A cascade delete alone would leave the chat
  // on screen until the next reload.
  await query(`
update public.matches m set ended_at = now(), ended_by = u.id from auth.users u
where u.${DEMO_EMAILS} and u.id in (m.user_a, m.user_b) and m.ended_at is null;`);
  // Deleting the account removes every row (cascade); db-events then deletes each photo, done here as well
  // so nothing stays in the bucket if an event is lost.
  const [[deleted]] = await query(
    `with gone as (delete from auth.users where ${DEMO_EMAILS} returning 1) select count(*) from gone;`,
  );
  await pool(keys, 8, (key) => r2Request("DELETE", key));
  console.log(
    `${deleted} demo people and ${keys.length} photos deleted from ${target}.`,
  );
}

async function thumbhash() {
  const rows = await query(`
select m.key from public.profile_media m join auth.users u on u.id = m.user_id
where u.${DEMO_EMAILS} and m.kind = 'photo' and m.thumbhash is null;`);
  if (rows.length === 0) {
    console.log(`Every demo photo in ${target} has its ThumbHash.`);
    return;
  }
  // Demo photos are a few pictures reused by everyone (p<position>-<picsum id>.jpg): one file read per picture,
  // from R2, so the hash is the one of what the bucket serves.
  const byPicture = new Map<string, string[]>();
  for (const [key] of rows) {
    const picture = /\/demo\/p\d+-(\d+)\.jpg$/.exec(key)?.[1];
    if (!picture) throw new Error(`unexpected demo photo key ${key}`);
    byPicture.set(picture, [...(byPicture.get(picture) ?? []), key]);
  }
  const values: string[] = [];
  for (const keys of byPicture.values()) {
    const hash = thumbhashOf(await r2Get(keys[0]));
    values.push(...keys.map((k) => `(${literal(k)}, ${literal(hash)})`));
  }
  // Each updated row rebuilds its person's card (profile_media_card trigger): the card's media carries the
  // hash and its version moves on, so apps and liked_me pick it up.
  const [[updated]] = await query(`
with done as (
  update public.profile_media m set thumbhash = v.hash
  from (values ${values.join(", ")}) as v(key, hash)
  where m.key = v.key and m.thumbhash is null
  returning 1)
select count(*) from done;`);
  console.log(`${updated} demo photos given their ThumbHash in ${target}.`);
}

try {
  await ({ seed, refresh, purge, thumbhash })
    [command as "seed" | "refresh" | "purge" | "thumbhash"]();
} finally {
  await Deno.remove(dir, { recursive: true });
}
