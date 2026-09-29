// A member's data export (db-events `export.requested`): one zip with data.json, everything the database keeps
// about them (export_data, 20260930000301) plus the messages they sent (Stream), and their own profile photos,
// videos and voice intro (R2) under files/. The archive must fit the Storage upload limit: files that would go
// over EXPORT_MAX_BYTES (45 MiB by default, under the 50 MiB of a project's default limit) are listed in
// data.json as not included, and the team is told, to send them another way.
import { zipSync } from "npm:fflate@0.8.2";
import { optionalEnv } from "./env.ts";
import { getObject } from "./r2.ts";
import { channelMessages } from "./stream.ts";
import { admin, must } from "./supabase.ts";

export type ExportData = {
  profile?: { voice_intro_key?: string | null } | null;
  media?: { key: string; posterKey?: string | null }[];
  matches?: { id: string }[];
  [section: string]: unknown;
};

/** The profile's own objects, in order: each photo or video and a video's poster, then the voice intro. */
export function exportKeys(data: ExportData): string[] {
  const keys = (data.media ?? []).flatMap((m) => [m.key, m.posterKey]).filter((k): k is string => !!k);
  if (data.profile?.voice_intro_key) keys.push(data.profile.voice_intro_key);
  return [...new Set(keys)];
}

/** What the person wrote in a chat, as they sent it: text, attachments (objects by key), dates. */
export function ownMessages(matchId: string, userId: string, messages: Awaited<ReturnType<typeof channelMessages>>) {
  return messages.filter((m) => m.user?.id === userId).map((m) => ({
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

export type Built = { archive: Uint8Array; omitted: string[] };

/** The archive of one account, or null when the account is gone. */
export async function buildExport(userId: string): Promise<Built | null> {
  const { data: raw, error } = await admin.rpc("export_data", { p_user: userId });
  if (error) throw new Error(`export data: ${error.message}`);
  if (!raw) return null;
  const data = raw as ExportData;

  const messages = [];
  for (const match of data.matches ?? []) {
    messages.push(...ownMessages(match.id, userId, await channelMessages(match.id)));
  }

  const budget = Number(optionalEnv("EXPORT_MAX_BYTES") ?? 45 * 1024 * 1024);
  const files: Record<string, [Uint8Array, { level: 0 }]> = {};
  const omitted: string[] = [];
  let size = 0;
  for (const key of exportKeys(data)) {
    const bytes = await getObject(key);
    if (!bytes) continue;
    if (size + bytes.length > budget) {
      omitted.push(key);
      continue;
    }
    size += bytes.length;
    // Already compressed (JPEG, HEIC, MP4, AAC): stored as they are.
    files[`files/${key.split("/").slice(2).join("/")}`] = [bytes, { level: 0 }];
  }

  const json = {
    exportedAt: new Date().toISOString(),
    ...data,
    messagesSent: messages,
    files: { included: Object.keys(files), notIncluded: omitted },
  };
  const archive = zipSync({ "data.json": new TextEncoder().encode(JSON.stringify(json, null, 2)), ...files });
  return { archive, omitted };
}

/** Stored in the private bucket, replacing a half-done earlier attempt. */
export async function storeExport(path: string, archive: Uint8Array): Promise<void> {
  const { error } = await admin.storage.from("data-exports").upload(path, archive, {
    contentType: "application/zip",
    upsert: true,
  });
  if (error) throw new Error(`store export ${path}: ${error.message}`);
}

/** The link emailed to the person: 7 days, downloaded under a readable name. */
export async function exportLink(path: string): Promise<string> {
  const signed = must(
    await admin.storage.from("data-exports").createSignedUrl(path, 7 * 24 * 3600, { download: "drafft-export.zip" }),
    "export link",
  );
  return signed.signedUrl;
}
