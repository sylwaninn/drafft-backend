// A member's data export (db-events `export.requested`): data.json, what the database keeps about them
// (export_data, 20260930000301) plus the messages and reactions they sent (Stream), and their own files (R2)
// under files/: profile photos, videos and posters, voice intro, and the photos, videos and voice messages they
// sent in chats.
//
// Storage takes one upload of 50 MiB at most (a project's default limit), so the export is split into parts, each a
// zip of at most EXPORT_MAX_BYTES (45 MiB by default): part 1 holds data.json and the first files, the next parts
// the files that follow, in order. data.json says which part holds each file. The parts are built and stored one
// after the other: one part at a time in memory, at most its files plus its archive (about twice
// EXPORT_MAX_BYTES).
//
// A file bigger than a part on its own can't go in any: it is listed in data.json with a note, and the team is
// told, to send it another way. With the default limit that can't happen: a file is 40 MiB at most (a video;
// media-upload-url signs the exact size of every upload, so R2 holds nothing bigger), and a part holds 45 MiB less
// a few hundred bytes of zip headers. A file listed in the database but missing from R2 is listed with a note too.
import { zipSync } from "npm:fflate@0.8.2";
import { optionalEnv } from "./env.ts";
import { chatMediaKeys } from "./erase.ts";
import { getObject, headObject } from "./r2.ts";
import { channelMessages, type StreamMessage } from "./stream.ts";
import { admin, must } from "./supabase.ts";

export type ExportData = {
  profile?: { voice_intro_key?: string | null } | null;
  media?: { key: string; posterKey?: string | null }[];
  matches?: { id: string }[];
  [section: string]: unknown;
};

/** The person's own objects, in order: each profile photo or video and a video's poster, the voice intro, then
 * what they sent in chats (their own objects only, `u/<id>/chat/…`). */
export function exportKeys(data: ExportData, sent: StreamMessage[] = []): string[] {
  const keys = (data.media ?? []).flatMap((m) => [m.key, m.posterKey]).filter((k): k is string => !!k);
  if (data.profile?.voice_intro_key) keys.push(data.profile.voice_intro_key);
  keys.push(...chatMediaKeys(sent));
  return [...new Set(keys)];
}

/** The messages a person sent in one chat. */
export function sentBy(userId: string, messages: StreamMessage[]): StreamMessage[] {
  return messages.filter((m) => m.user?.id === userId);
}

/** What the person wrote in a chat, as they sent it: text, attachments (objects by key), dates. */
export function ownMessages(matchId: string, sent: StreamMessage[]) {
  return sent.map((m) => ({
    match: matchId,
    id: m.id,
    text: m.text ?? "",
    attachments: (m.attachments ?? []).map((a) => ({ type: a.type, key: a.key, posterKey: a.poster_key })),
    quoted: m.quoted_message_id ?? null,
    createdAt: m.created_at,
    updatedAt: m.updated_at,
    deletedAt: m.deleted_at ?? null,
  }));
}

/** The reactions the person left in a chat, on anyone's message (the latest ones Stream returns per message). */
export function ownReactions(matchId: string, userId: string, messages: StreamMessage[]) {
  return messages.flatMap((m) =>
    (m.latest_reactions ?? []).filter((r) => (r.user?.id ?? r.user_id) === userId).map((r) => ({
      match: matchId,
      message: m.id,
      type: r.type,
      createdAt: r.created_at,
    }))
  );
}

/** EXPORT_MAX_BYTES, the most one part (one upload) may weigh: a positive whole number of bytes. */
export function partLimit(): number {
  const raw = optionalEnv("EXPORT_MAX_BYTES");
  if (raw === undefined || raw === "") return 45 * 1024 * 1024;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit <= 0) throw new Error(`EXPORT_MAX_BYTES must be a number of bytes: ${raw}`);
  return limit;
}

/** Where a key goes in the archive: `u/<user>/photos/x.jpg` → `files/photos/x.jpg`. */
export function archivePath(key: string): string {
  return `files/${key.split("/").slice(2).join("/")}`;
}

// A zip entry costs its bytes plus its name twice (local header, central directory) and 76 bytes of headers
// (30 + 46), stored as is; the archive ends with 22 bytes. Counted with room to spare.
const entryHeaders = 128;
const archiveEnd = 64;

function entryCost(path: string, bytes: number): number {
  return bytes + 2 * new TextEncoder().encode(path).length + entryHeaders;
}

export type ExportFile = { key: string; bytes: number };

/**
 * Files into parts, in order (a file never jumps ahead of another): a part is closed when the next file doesn't
 * fit. Part 1 starts with `first` bytes taken (data.json). A file that can't fit even in an empty part is left out.
 */
export function planParts(files: ExportFile[], limit: number, first: number) {
  const parts: ExportFile[][] = [[]];
  const tooLarge: ExportFile[] = [];
  let used = archiveEnd + first;
  for (const file of files) {
    const cost = entryCost(archivePath(file.key), file.bytes);
    if (archiveEnd + cost > limit) {
      tooLarge.push(file);
      continue;
    }
    if (used + cost > limit) {
      parts.push([]);
      used = archiveEnd;
    }
    parts[parts.length - 1].push(file);
    used += cost;
  }
  return { parts, tooLarge };
}

/** Next to a file too large for any part, in data.json. */
export const tooLargeNote = "Too large for one part of this export: not included, the team sends it another way.";
/** Next to a file the database lists but storage doesn't have. */
export const missingNote = "Not found in storage: not included.";

type Listed =
  | { path: string; bytes: number; part: number }
  | { path: string; bytes: number | null; part: null; note: typeof tooLargeNote | typeof missingNote };

function dataJson(base: Record<string, unknown>, parts: number, files: unknown[]): Uint8Array {
  return new TextEncoder().encode(JSON.stringify({ ...base, files: { parts, list: files } }, null, 2));
}

/** data.json as part 1 stores it (deflated), to count what it takes of part 1. */
function deflatedSize(json: Uint8Array): number {
  return zipSync({ "data.json": json }).length;
}

export type Built = { paths: string[]; tooLarge: string[]; missing: string[] };

/**
 * Builds the export of one account and hands each part, numbered from 1, to `store` as soon as it is zipped,
 * before the next one is read; `store` answers where it put it. Null when the account is gone (nothing stored).
 */
export async function buildExport(
  userId: string,
  store: (part: number, archive: Uint8Array) => Promise<string>,
): Promise<Built | null> {
  const limit = partLimit();
  const { data: raw, error } = await admin.rpc("export_data", { p_user: userId });
  if (error) throw new Error(`export data: ${error.message}`);
  if (!raw) return null;
  const data = raw as ExportData;

  const messages = [];
  const reactions = [];
  const sent: StreamMessage[] = [];
  for (const match of data.matches ?? []) {
    const all = await channelMessages(match.id) ?? [];
    const own = sentBy(userId, all);
    sent.push(...own);
    messages.push(...ownMessages(match.id, own));
    reactions.push(...ownReactions(match.id, userId, all));
  }

  // Sizes first (HEAD), so data.json can say where each file is before any part is built.
  const files: ExportFile[] = [];
  const missing: string[] = [];
  for (const key of exportKeys(data, sent)) {
    const bytes = await headObject(key);
    if (bytes === null) {
      console.warn(`export of ${userId}: ${key} is not in storage`);
      missing.push(key);
    } else {
      files.push({ key, bytes });
    }
  }

  const base = { exportedAt: new Date().toISOString(), ...data, messagesSent: messages, reactionsLeft: reactions };
  // What data.json takes of part 1, counted on its longest form (every file with the note and a 4-digit part),
  // plus 1 KiB: the real one only has shorter entries.
  const longest = [...files.map((f) => f.key), ...missing].map((key) => ({
    path: archivePath(key),
    bytes: Number.MAX_SAFE_INTEGER,
    part: 9999,
    note: tooLargeNote,
  }));
  const reserve = entryCost("data.json", deflatedSize(dataJson(base, 9999, longest))) + 1024;
  if (archiveEnd + reserve > limit) {
    throw new Error(`export of ${userId}: data.json alone (${reserve} bytes) is over EXPORT_MAX_BYTES (${limit})`);
  }
  const plan = planParts(files, limit, reserve);

  const partOf = new Map(plan.parts.flatMap((part, i) => part.map((f) => [f.key, i + 1] as const)));
  const listed: Listed[] = [
    ...files.map((f): Listed =>
      partOf.has(f.key)
        ? { path: archivePath(f.key), bytes: f.bytes, part: partOf.get(f.key)! }
        : { path: archivePath(f.key), bytes: f.bytes, part: null, note: tooLargeNote }
    ),
    ...missing.map((key): Listed => ({ path: archivePath(key), bytes: null, part: null, note: missingNote })),
  ];

  const paths: string[] = [];
  for (const [i, part] of plan.parts.entries()) {
    const entries: Record<string, Uint8Array | [Uint8Array, { level: 0 }]> = {};
    if (i === 0) entries["data.json"] = dataJson(base, plan.parts.length, listed);
    for (const file of part) {
      const bytes = await getObject(file.key);
      // Deleted or replaced since it was measured: data.json would be wrong. The retry measures again.
      if (!bytes || bytes.length !== file.bytes) throw new Error(`export: ${file.key} changed while building`);
      // Already compressed (JPEG, HEIC, MP4, AAC): stored as they are.
      entries[archivePath(file.key)] = [bytes, { level: 0 }];
    }
    const archive = zipSync(entries);
    if (archive.length > limit) throw new Error(`export part ${i + 1}: ${archive.length} bytes, over ${limit}`);
    paths.push(await store(i + 1, archive));
  }
  return { paths, tooLarge: plan.tooLarge.map((f) => f.key), missing };
}

/** A part in the private bucket: `<user id>/<request id>-<part>.zip`, all in the account's folder. */
export function partPath(userId: string, requestId: number, part: number): string {
  return `${userId}/${requestId}-${part}.zip`;
}

/** Stored in the private bucket, replacing a half-done earlier attempt. */
export async function storeExport(path: string, archive: Uint8Array): Promise<void> {
  const { error } = await admin.storage.from("data-exports").upload(path, archive, {
    contentType: "application/zip",
    upsert: true,
  });
  if (error) throw new Error(`store export ${path}: ${error.message}`);
}

/** Parts past `parts` left by an earlier attempt that split the export differently: deleted. */
export async function removeExtraParts(userId: string, requestId: number, parts: number): Promise<void> {
  const listed = await admin.storage.from("data-exports").list(userId, { limit: 1000, search: `${requestId}-` });
  if (listed.error) throw new Error(`list export parts: ${listed.error.message}`);
  const extra = listed.data.filter((f) => {
    const part = f.name.match(/^(\d+)-(\d+)\.zip$/);
    return part && part[1] === String(requestId) && Number(part[2]) > parts;
  }).map((f) => `${userId}/${f.name}`);
  if (extra.length === 0) return;
  const removed = await admin.storage.from("data-exports").remove(extra);
  if (removed.error) throw new Error(`delete extra export parts: ${removed.error.message}`);
}

/** Parts stored for a request that went meanwhile (its account erased): deleted at once. */
export async function removeParts(paths: string[]): Promise<void> {
  if (paths.length === 0) return;
  const removed = await admin.storage.from("data-exports").remove(paths);
  if (removed.error) throw new Error(`delete export parts: ${removed.error.message}`);
}

/** The link emailed to the person for one part: 7 days, downloaded under a readable, numbered name. */
export async function exportLink(path: string, part: number, parts: number): Promise<string> {
  const name = parts === 1 ? "drafft-export.zip" : `drafft-export-${part}-of-${parts}.zip`;
  const signed = must(
    await admin.storage.from("data-exports").createSignedUrl(path, 7 * 24 * 3600, { download: name }),
    "export link",
  );
  return signed.signedUrl;
}
