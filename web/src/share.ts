// Client side of the share API: gzip session bodies (CompressionStream),
// upload to the worker, and fetch/decompress shared sets back.

import type { SessionEntry } from "./types";
import { displayTitle } from "./autotitle";

export interface ShareManifest {
  createdAt: number;
  complete: boolean;
  sessions: {
    name: string;
    title: string;
    project: string;
    messageCount: number;
    mtime: number;
    bytes: number;
  }[];
}

async function gzip(text: string): Promise<ArrayBuffer> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return await new Response(stream).arrayBuffer();
}

async function gunzip(data: ArrayBuffer): Promise<string> {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("gzip"));
  return await new Response(stream).text();
}

async function apiError(res: Response): Promise<string> {
  try {
    const body = (await res.json()) as { error?: string };
    if (body.error) return body.error;
  } catch { /* non-JSON error body */ }
  return `HTTP ${res.status}`;
}

const OWNER_KEY = "se-owner-tokens";

function ownerTokens(): Record<string, string> {
  try {
    return JSON.parse(localStorage.getItem(OWNER_KEY) ?? "{}");
  } catch {
    return {};
  }
}

export function ownerTokenFor(id: string): string | null {
  return ownerTokens()[id] ?? null;
}

function rememberOwnerToken(id: string, token: string) {
  const all = ownerTokens();
  all[id] = token;
  localStorage.setItem(OWNER_KEY, JSON.stringify(all));
}

/** Upload the selected sessions and return the share id. */
export async function createShare(
  entries: SessionEntry[],
  onProgress: (done: number, total: number) => void,
): Promise<string> {
  const createRes = await fetch("/api/share", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      sessions: entries.map((e) => ({
        name: e.meta.fileName,
        title: displayTitle(e.meta),
        project: e.meta.projectPath,
        messageCount: e.meta.messageCount,
        mtime: e.meta.mtime,
        bytes: e.meta.byteSize,
      })),
    }),
  });
  if (!createRes.ok) throw new Error(await apiError(createRes));
  const { id, ownerToken } = (await createRes.json()) as { id: string; ownerToken: string };
  rememberOwnerToken(id, ownerToken);

  for (let n = 0; n < entries.length; n++) {
    onProgress(n, entries.length);
    const body = await gzip(entries[n].text);
    const putRes = await fetch(`/api/share/${id}/${n}`, {
      method: "PUT",
      headers: { "X-Owner-Token": ownerToken },
      body,
    });
    if (!putRes.ok) throw new Error(`${entries[n].meta.fileName}: ${await apiError(putRes)}`);
  }
  onProgress(entries.length, entries.length);

  const doneRes = await fetch(`/api/share/${id}/complete`, {
    method: "POST",
    headers: { "X-Owner-Token": ownerToken },
  });
  if (!doneRes.ok) throw new Error(await apiError(doneRes));
  return id;
}

export async function fetchManifest(id: string): Promise<ShareManifest> {
  const res = await fetch(`/api/share/${id}`);
  if (!res.ok) throw new Error(await apiError(res));
  return (await res.json()) as ShareManifest;
}

export async function fetchPart(id: string, n: number): Promise<string> {
  const res = await fetch(`/api/share/${id}/${n}`);
  if (!res.ok) throw new Error(await apiError(res));
  return await gunzip(await res.arrayBuffer());
}

export async function deleteShare(id: string): Promise<void> {
  const token = ownerTokenFor(id);
  if (!token) throw new Error("no owner token for this share");
  const res = await fetch(`/api/share/${id}`, {
    method: "DELETE",
    headers: { "X-Owner-Token": token },
  });
  if (!res.ok) throw new Error(await apiError(res));
}
