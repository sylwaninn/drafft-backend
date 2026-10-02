// The demo people of scripts/demo-profiles.ts act towards one real account, to see its notifications and
// live screens: likes, super likes, matches, messages, replies, reactions, sessions. Staging only: demo/guard.ts
// stops it anywhere else.
//
//   deno run -A --env-file=supabase/functions/.env.staging scripts/demo-interact.ts staging <email> <action> [count]
//
// Actions (count defaults to 1):
//   likes [n]       n demo people like the account
//   superlikes [n]  n demo people super like it, with a note
//   matches [n]     n matches: first the demo people the account liked in the app answer, then others like it
//                   and the account's like is added for them
//   messages [n]    a demo person writes in n of the account's demo matches, most recent first
//   replies         every demo match where the account wrote last gets an answer
//   reactions       the demo person reacts to the account's last message in each demo match
//   sessions [n]    a demo person proposes a session in n demo matches
//   accept          the demo people accept the sessions the account proposed to them
//   scenario        a bit of everything, 20 seconds apart: likes, super like, match, message, session
//
// Database actions run as the demo person: the script sets their id as the JWT subject (auth.uid()) and calls
// the app's own RPCs (swipe, propose_session, respond_session), so every rule, event and push is the real one.
// Chat goes through Stream with the server secret, as the demo person, with Stream's own message push.
// Only the server's rules are applied: a demo person may like the account whatever their own preferences.
//
// Reads STREAM_* from the env file and never prints them.
import { StreamChat } from "npm:stream-chat@9";
import { guard } from "./demo/guard.ts";

// Exactly the accounts demo-profiles.ts writes (demo001 to demo999), never a look-alike.
const DEMO = String.raw`u.email ~ '^demo[0-9]{3}@drafft\.test$'`;
const ACTIONS = [
  "likes",
  "superlikes",
  "matches",
  "messages",
  "replies",
  "reactions",
  "sessions",
  "accept",
  "scenario",
] as const;
type Action = (typeof ACTIONS)[number];

const [target, email, action, countArg] = Deno.args as [string, string, Action, string?];
if (target !== "staging" || !email?.includes("@") || !ACTIONS.includes(action)) {
  console.error(
    `Usage: deno run -A --env-file=<env file> scripts/demo-interact.ts staging <email> ${ACTIONS.join("|")} [count]`,
  );
  Deno.exit(64);
}
const count = Number(countArg ?? 1);
if (!Number.isInteger(count) || count < 1 || count > 20) throw new Error("count must be 1 to 20");

// Never production: stops here unless the env file and the database are staging's.
await guard(target);

const env = (name: string) =>
  Deno.env.get(name) ?? (() => {
    throw new Error(`${name} is not set`);
  })();

// MARK: Database

async function supabase(args: string[]): Promise<string> {
  const { code, stdout, stderr } = await new Deno.Command("supabase", { args, stdout: "piped", stderr: "piped" })
    .output();
  if (code !== 0) {
    const reason = new TextDecoder().decode(stderr).split("\n").find((l) => l.includes("ERROR")) ?? `exit ${code}`;
    throw new Error(reason.trim());
  }
  return new TextDecoder().decode(stdout);
}

const dir = await Deno.makeTempDir({ prefix: "demo-interact-" });
let queries = 0;
/** Runs one SQL statement, returns its rows as objects. */
async function query<T = Record<string, string>>(sql: string): Promise<T[]> {
  const file = `${dir}/${queries++}.sql`;
  await Deno.writeTextFile(file, sql);
  const out = await supabase([
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
  return start < 0 ? [] : JSON.parse(out.slice(start)) as T[];
}

const literal = (s: string) => `'${s.replaceAll("'", "''")}'`;

/** Calls `call` (SQL) as the demo person `as`: auth.uid() is theirs for that statement. */
function asUser(as: string, call: string): Promise<Record<string, string>[]> {
  return query(`
with jwt as materialized (
  select set_config('request.jwt.claims', ${literal(JSON.stringify({ sub: as, role: "authenticated" }))}, true)
)
select (${call})::text as result from jwt;`);
}

const [me] = await query<{ id: string; name: string; gender: string }>(
  `select p.id, p.name, p.gender from public.profiles p join auth.users u on u.id = p.id
   where lower(u.email) = lower(${literal(email)}) and p.onboarded_at is not null;`,
);
if (!me) throw new Error(`no onboarded account for ${email} in ${target}`);

interface Demo {
  id: string;
  name: string;
  sport: string;
}

/** Demo people who can still like the account (the swipe rule: it wants to see their gender), shuffled.
 * `unswiped`: also none the account swiped, so the like added for it in `matches` is the one that counts. */
function likers(n: number, unswiped = false): Promise<Demo[]> {
  return query<Demo>(`
select p.id, p.name, p.sport_ids[1] as sport from public.profiles p join auth.users u on u.id = p.id
where ${DEMO} and p.onboarded_at is not null
  and not exists (select 1 from public.swipes s where s.swiper = p.id and s.target = '${me.id}')
  ${unswiped ? `and not exists (select 1 from public.swipes s where s.swiper = '${me.id}' and s.target = p.id)` : ""}
  and not exists (select 1 from public.matches m where (m.user_a, m.user_b) = (least(p.id, '${me.id}'::uuid), greatest(p.id, '${me.id}'::uuid)))
  and (select cardinality(interested_in) = 0 or p.gender = any (interested_in) from public.profiles where id = '${me.id}')
order by random() limit ${n};`);
}

interface Match {
  match: string;
  id: string;
  name: string;
  sport: string;
}

/** The account's live matches with demo people, most recent first. */
function demoMatches(): Promise<Match[]> {
  return query<Match>(`
select m.id as match, p.id, p.name, p.sport_ids[1] as sport from public.matches m
join public.profiles p on p.id = case when m.user_a = '${me.id}' then m.user_b else m.user_a end
join auth.users u on u.id = p.id
where '${me.id}' in (m.user_a, m.user_b) and m.ended_at is null and ${DEMO}
order by m.created_at desc;`);
}

// MARK: Chat

let streamClient: StreamChat | undefined;
const stream = () => streamClient ??= StreamChat.getInstance(env("STREAM_API_KEY"), env("STREAM_API_SECRET"));

/** The match's channel, once db-events has opened it (right after the match, a few seconds). */
async function channelOf(matchId: string) {
  for (let attempt = 0; attempt < 15; attempt++) {
    const [found] = await stream().queryChannels({ type: "messaging", id: { $eq: matchId } }, {}, {
      user_id: me.id,
      message_limit: 20,
    });
    if (found) return found;
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error(`no chat yet for match ${matchId}`);
}

/** A message someone typed: not a server card (opener, super like note, session), which carries `drafft`. */
const written = (msg: { type?: string; text?: string; drafft?: unknown }) =>
  msg.type === "regular" && !msg.drafft && !!msg.text?.trim();

const pick = <T>(list: T[]) => list[Math.floor(Math.random() * list.length)];

const OPENERS = [
  "Salut ! Ton profil m'a fait sourire, tu cours où d'habitude ?",
  "Hello ! Partant pour une séance cette semaine ?",
  "Coucou, on a des sports en commun on dirait 😄",
  "Salut ! Tu prépares une course en ce moment ?",
  "Hey ! J'ai vu ton spot préféré, j'y vais souvent aussi",
];
const REPLIES = [
  "Haha carrément 😄",
  "Avec plaisir ! Plutôt le matin ou le soir pour toi ?",
  "Ah oui ? Raconte-moi ça",
  "Je suis dispo jeudi soir si ça te va",
  "Trop bien ! Moi aussi j'adore",
  "Ok ça marche, on se dit ça 👍",
  "Haha je ne m'attendais pas à ça",
  "Grave, on devrait tester ensemble",
];
const NOTES = [
  "Ton profil m'a donné envie d'aller courir 😄",
  "On a clairement le même spot préféré",
  "Partant pour une séance quand tu veux",
  "Ta réponse sur le dimanche idéal m'a convaincu",
];
const REACTIONS = ["❤️", "🔥", "😂", "👏", "😮", "💪"];

// MARK: Actions

async function likes(n: number, superlike = false) {
  const people = await likers(n);
  if (people.length === 0) console.log("No demo person left who can like this account.");
  for (const d of people) {
    const note = superlike ? literal(pick(NOTES)) : "null";
    await asUser(d.id, `public.swipe('${me.id}', '${superlike ? "superlike" : "like"}', null, ${note})`);
    console.log(`${d.name} ${superlike ? "super liked" : "liked"} ${me.name}`);
  }
}

async function matches(n: number) {
  // Demo people the account liked first: answering is what happens in real life.
  const liked = await query<Demo>(`
select p.id, p.name, p.sport_ids[1] as sport from public.swipes s join public.profiles p on p.id = s.target
join auth.users u on u.id = p.id
where s.swiper = '${me.id}' and s.action <> 'pass' and ${DEMO}
  and not exists (select 1 from public.swipes b where b.swiper = p.id and b.target = '${me.id}')
order by s.created_at desc limit ${n};`);
  const others = liked.length < n ? await likers(n - liked.length, true) : [];
  for (const d of others) {
    // The account's like, as if it had swiped them in Discover.
    await query(
      `insert into public.swipes (swiper, target, action) values ('${me.id}', '${d.id}', 'like') on conflict do nothing returning 1;`,
    );
  }
  for (const d of [...liked, ...others]) {
    const [res] = await asUser(d.id, `public.swipe('${me.id}', 'like')`);
    console.log(`${d.name} matched with ${me.name} ${JSON.parse(res.result).matched ? "" : "(no match: check)"}`);
  }
}

async function messages(n: number) {
  const list = (await demoMatches()).slice(0, n);
  if (list.length === 0) console.log("No demo match yet: run matches first.");
  for (const m of list) {
    const channel = await channelOf(m.match);
    await channel.sendMessage({ text: pick(OPENERS), user_id: m.id });
    console.log(`${m.name} wrote to ${me.name}`);
  }
}

async function replies() {
  let answered = 0;
  for (const m of await demoMatches()) {
    const channel = await channelOf(m.match);
    const last = channel.state.messages.filter(written).at(-1);
    if (last?.user?.id !== me.id) continue;
    await channel.sendMessage({ text: pick(REPLIES), user_id: m.id });
    console.log(`${m.name} answered "${last.text?.slice(0, 40)}"`);
    answered++;
  }
  if (answered === 0) console.log("No demo chat where the account wrote last.");
}

async function reactions() {
  let reacted = 0;
  for (const m of await demoMatches()) {
    const channel = await channelOf(m.match);
    const last = channel.state.messages.filter((msg) => written(msg) && msg.user?.id === me.id).at(-1);
    if (!last) continue;
    const emoji = pick(REACTIONS);
    await channel.sendReaction(last.id, { type: emoji, user_id: m.id });
    console.log(`${m.name} reacted ${emoji} to "${last.text?.slice(0, 40)}"`);
    reacted++;
  }
  if (reacted === 0) console.log("No message from the account in a demo chat.");
}

/** In `days` days at a given Paris time, with Paris' offset that day (the server stores the instant). */
function parisAt(days: number, hour: number, minute = 0): string {
  const d = new Date(Date.now() + days * 86_400_000);
  const ymd = d.toLocaleDateString("en-CA", { timeZone: "Europe/Paris" });
  const offset = new Intl.DateTimeFormat("en", { timeZone: "Europe/Paris", timeZoneName: "longOffset" })
    .formatToParts(d).find((part) => part.type === "timeZoneName")!.value.replace("GMT", "");
  return `${ymd}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:00${offset}`;
}

async function sessions(n: number) {
  const list = (await demoMatches()).slice(0, n);
  if (list.length === 0) console.log("No demo match yet: run matches first.");
  for (const m of list) {
    const proposal = {
      sport: m.sport,
      options: [parisAt(1, 18, 30), parisAt(2, 7, 30), parisAt(3, 12, 15)],
      title: "",
      note: "Ça te dit ? Je connais un super parcours",
      tags: [],
    };
    await asUser(m.id, `(public.propose_session('${m.match}', ${literal(JSON.stringify(proposal))}::jsonb)).id`);
    console.log(`${m.name} proposed a ${m.sport} session to ${me.name}`);
  }
}

async function accept() {
  const pending = await query<{ session: string; proposer: string; name: string; first: string }>(`
select s.id as session, p.id as proposer, p.name, s.options[1]::text as first from public.sessions s
join public.matches m on m.id = s.match_id
join public.profiles p on p.id = case when m.user_a = '${me.id}' then m.user_b else m.user_a end
join auth.users u on u.id = p.id
where s.proposer_id = '${me.id}' and s.status = 'pending' and ${DEMO} and s.options[1] > now();`);
  if (pending.length === 0) console.log("No session from the account waiting for a demo person.");
  for (const s of pending) {
    await asUser(s.proposer, `public.respond_session('${s.session}', true, ${literal(s.first)}::timestamptz)`);
    console.log(`${s.name} accepted the session of ${s.first}`);
  }
}

async function scenario() {
  const steps: [string, () => Promise<void>][] = [
    ["likes", () => likes(2)],
    ["super like", () => likes(1, true)],
    ["match", () => matches(1)],
    ["message", () => messages(1)],
    ["session", () => sessions(1)],
  ];
  for (const [i, [name, step]] of steps.entries()) {
    if (i > 0) await new Promise((r) => setTimeout(r, 20_000));
    console.log(`- ${name}`);
    await step();
  }
}

try {
  await ({
    likes: () => likes(count),
    superlikes: () => likes(count, true),
    matches: () => matches(count),
    messages: () => messages(count),
    replies,
    reactions,
    sessions: () => sessions(count),
    accept,
    scenario,
  })[action]();
} finally {
  await Deno.remove(dir, { recursive: true });
}
