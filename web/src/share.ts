// Client side of the share API: gzip session bodies (CompressionStream),
// upload to the worker, and fetch/decompress shared sets back.

import type { SessionEntry } from "./types";
import { displayTitle } from "./autotitle";
import { VariantBuilder } from "./variants";

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

/// One stored chunk of a gzipped body (the worker's KV value cap).
const CHUNK_BYTES = 24 * 1024 * 1024;

async function apiError(res: Response): Promise<string> {
  try {
    const body = (await res.json()) as { error?: string };
    if (body.error) return body.error;
  } catch { /* non-JSON error body */ }
  return `HTTP ${res.status}`;
}

async function sha256Hex(data: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** fetch that repeats a request the network dropped (a thrown TypeError) or
 *  the server failed (5xx, 429). */
async function fetchRetrying(url: string, init: RequestInit): Promise<Response> {
  for (let attempt = 0; ; attempt++) {
    const last = attempt >= 4;
    try {
      const res = await fetch(url, init);
      if (last || (res.status < 500 && res.status !== 429)) return res;
    } catch (err) {
      if (last) throw err;
    }
    await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
  }
}

/// Unfinished uploads by session-set key, so a failed share continues with
/// the chunks the server already holds.
const PENDING_KEY = "se-pending-shares";

function pendingShares(): Record<string, { id: string; token: string }> {
  try {
    return JSON.parse(localStorage.getItem(PENDING_KEY) ?? "{}");
  } catch {
    return {};
  }
}

function setPending(key: string, value: { id: string; token: string } | null) {
  const all = pendingShares();
  if (value) all[key] = value;
  else delete all[key];
  localStorage.setItem(PENDING_KEY, JSON.stringify(all));
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
  const pendingKey = entries.map((e) => e.meta.fileName).join("\n");
  const pending = pendingShares()[pendingKey];
  const createRes = await fetch("/api/share", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(pending ? { "X-Owner-Token": pending.token } : {}),
    },
    body: JSON.stringify({
      resume: pending?.id,
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
  const { id, ownerToken, uploaded = {} } = (await createRes.json()) as {
    id: string; ownerToken: string; uploaded?: Record<string, string>;
  };
  rememberOwnerToken(id, ownerToken);
  setPending(pendingKey, { id, token: ownerToken });

  const chunks: number[] = [];
  const texts: string[][] = [];
  for (let n = 0; n < entries.length; n++) {
    onProgress(n, entries.length);
    const body = await gzip(entries[n].text);
    const count = Math.max(1, Math.ceil(body.byteLength / CHUNK_BYTES));
    for (let c = 0; c < count; c++) {
      const chunk = body.slice(c * CHUNK_BYTES, (c + 1) * CHUNK_BYTES);
      const sha = await sha256Hex(chunk);
      if (uploaded[`${n}:${c}`] === sha) continue;
      const putRes = await fetchRetrying(`/api/share/${id}/${n}?chunk=${c}`, {
        method: "PUT",
        headers: { "X-Owner-Token": ownerToken, "X-Chunk-SHA256": sha },
        body: chunk,
      });
      if (!putRes.ok) throw new Error(`${entries[n].meta.fileName}: ${await apiError(putRes)}`);
    }
    chunks.push(count);

    // Transcript variants for the text API, so the worker serves them as stored.
    const builder = new VariantBuilder(`${location.origin}/api/share/${id}/${n}/image`);
    for (const line of entries[n].text.split("\n")) builder.push(line);
    const variants = builder.finish({
      title: displayTitle(entries[n].meta),
      project: entries[n].meta.projectPath,
      sessionId: entries[n].meta.fileName.replace(/\.jsonl$/, ""),
    });
    const stored: string[] = [];
    for (const [key, text] of Object.entries(variants)) {
      const gz = await gzip(text);
      if (gz.byteLength > CHUNK_BYTES) continue;
      const putRes = await fetchRetrying(`/api/share/${id}/${n}?text=${key}`, {
        method: "PUT",
        headers: { "X-Owner-Token": ownerToken },
        body: gz,
      });
      if (!putRes.ok) throw new Error(`${entries[n].meta.fileName}: ${await apiError(putRes)}`);
      stored.push(key);
    }
    texts.push(stored);
  }
  onProgress(entries.length, entries.length);

  const doneRes = await fetch(`/api/share/${id}/complete`, {
    method: "POST",
    headers: { "X-Owner-Token": ownerToken, "Content-Type": "application/json" },
    body: JSON.stringify({ chunks, texts }),
  });
  if (!doneRes.ok) throw new Error(await apiError(doneRes));
  setPending(pendingKey, null);
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
