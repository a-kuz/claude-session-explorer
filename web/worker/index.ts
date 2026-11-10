// Share API over Workers KV + static asset serving.
//
// Keys: share:<id>            — manifest JSON (session metas, owner token hash)
//       share:<id>:<n>        — gzipped jsonl body of session n
// Keys never expire; only the owner's DELETE removes them. Bodies are
// stored/served as opaque bytes; the client decompresses with DecompressionStream.
//
// Read API for scripts (session = index in the manifest, or its session id):
//   GET /api/share/<id>/text            — transcripts of every session
//   GET /api/share/<id>/<session>/text  — transcript of one session
//       ?tools=none|brief|full (default brief) — tool calls: omitted, one
//       line each, or with input and result
//       ?thinking=0 — leave Claude's thinking blocks out
//   GET /api/share/<id>/<session>/jsonl — the decompressed jsonl

import { DialogParser } from "../src/parser";
import { transcriptText, type ToolDetail } from "../src/transcript";
import { buildBlocks, buildTurns } from "../src/turns";

export interface Env {
  SHARES: KVNamespace;
  ASSETS: Fetcher;
}

const MAX_SESSIONS = 100;
const MAX_PART_BYTES = 24 * 1024 * 1024; // KV value limit is 25 MB
const MAX_TOTAL_BYTES = 100 * 1024 * 1024;

interface ManifestSession {
  name: string;
  title: string;
  project: string;
  messageCount: number;
  mtime: number;
  bytes: number;
}

interface Manifest {
  v: 1;
  createdAt: number;
  complete: boolean;
  tokenHash: string;
  sessions: ManifestSession[];
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function err(status: number, message: string): Response {
  return json({ error: message }, status);
}

async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function randomId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(22));
  let out = "";
  for (const b of bytes) out += B58[b % B58.length];
  return out;
}

function cleanStr(v: unknown, max: number): string {
  return typeof v === "string" ? v.slice(0, max) : "";
}

async function loadManifest(env: Env, id: string): Promise<Manifest | null> {
  if (!/^[1-9A-HJ-NP-Za-km-z]{10,40}$/.test(id)) return null;
  return await env.SHARES.get<Manifest>(`share:${id}`, "json");
}

async function requireOwner(env: Env, id: string, req: Request): Promise<Manifest | Response> {
  const manifest = await loadManifest(env, id);
  if (!manifest) return err(404, "share not found");
  const token = req.headers.get("X-Owner-Token") ?? "";
  if (!token || (await sha256Hex(token)) !== manifest.tokenHash) {
    return err(403, "bad owner token");
  }
  return manifest;
}

/** Manifest index of a session addressed by index or by session id / file name. */
function sessionIndex(manifest: Manifest, ref: string): number {
  if (/^\d+$/.test(ref)) {
    const n = Number(ref);
    return n < manifest.sessions.length ? n : -1;
  }
  return manifest.sessions.findIndex((s) => s.name === ref || s.name === `${ref}.jsonl`);
}

async function partTextStream(env: Env, id: string, n: number): Promise<ReadableStream<Uint8Array> | null> {
  const gz = await env.SHARES.get(`share:${id}:${n}`, "stream");
  if (!gz) return null;
  return gz.pipeThrough(new DecompressionStream("gzip")) as ReadableStream<Uint8Array>;
}

/** Transcript of one stored session, parsed line by line off the
 *  decompression stream (the jsonl is never held in memory whole). */
async function sessionTranscript(
  env: Env, id: string, manifest: Manifest, n: number, tools: ToolDetail, thinking: boolean,
): Promise<string | null> {
  const stream = await partTextStream(env, id, n);
  if (!stream) return null;
  const parser = new DialogParser(false);
  const decoder = new TextDecoder();
  let buf = "";
  let scanned = 0;
  const reader = stream.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    buf += done ? decoder.decode() : decoder.decode(value, { stream: true });
    let start = 0;
    for (;;) {
      const nl = buf.indexOf("\n", Math.max(start, scanned));
      if (nl < 0) break;
      parser.push(buf.slice(start, nl));
      start = nl + 1;
    }
    buf = buf.slice(start);
    scanned = buf.length;
    if (done) break;
  }
  parser.push(buf);
  const s = manifest.sessions[n];
  return transcriptText(
    { title: s.title, project: s.project, sessionId: s.name.replace(/\.jsonl$/, "") },
    buildBlocks(buildTurns(parser.finish())),
    tools,
    thinking,
  );
}

function plainText(body: string): Response {
  return new Response(body, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

async function handleRead(
  req: Request, env: Env, id: string, ref: string | undefined, kind: string,
): Promise<Response> {
  const manifest = await loadManifest(env, id);
  if (!manifest) return err(404, "share not found");

  if (kind === "jsonl") {
    const n = sessionIndex(manifest, ref ?? "");
    if (n < 0) return err(404, "session not found");
    const stream = await partTextStream(env, id, n);
    if (!stream) return err(404, "part not found");
    return new Response(stream, {
      headers: { "Content-Type": "application/x-ndjson; charset=utf-8" },
    });
  }

  const params = new URL(req.url).searchParams;
  const tools = params.get("tools") ?? "brief";
  if (tools !== "none" && tools !== "brief" && tools !== "full") {
    return err(400, "tools must be none, brief or full");
  }
  const thinkingParam = params.get("thinking") ?? "1";
  if (thinkingParam !== "0" && thinkingParam !== "1") {
    return err(400, "thinking must be 0 or 1");
  }
  const thinking = thinkingParam === "1";
  let indexes: number[];
  if (ref === undefined) {
    indexes = manifest.sessions.map((_, n) => n);
  } else {
    const n = sessionIndex(manifest, ref);
    if (n < 0) return err(404, "session not found");
    indexes = [n];
  }
  const texts: string[] = [];
  for (const n of indexes) {
    const text = await sessionTranscript(env, id, manifest, n, tools, thinking);
    if (text === null) return err(404, "part not found");
    texts.push(text);
  }
  return plainText(texts.join("\n"));
}

async function handleApi(req: Request, env: Env, path: string): Promise<Response> {
  // POST /api/share — create a share: manifest with session metas, complete:false.
  if (path === "/api/share" && req.method === "POST") {
    let body: { sessions?: unknown };
    try {
      body = await req.json();
    } catch {
      return err(400, "invalid JSON");
    }
    if (!Array.isArray(body.sessions) || body.sessions.length === 0) {
      return err(400, "sessions array required");
    }
    if (body.sessions.length > MAX_SESSIONS) {
      return err(400, `too many sessions (max ${MAX_SESSIONS})`);
    }
    const sessions: ManifestSession[] = body.sessions.map((s: any) => ({
      name: cleanStr(s?.name, 200),
      title: cleanStr(s?.title, 300),
      project: cleanStr(s?.project, 500),
      messageCount: Number(s?.messageCount) || 0,
      mtime: Number(s?.mtime) || 0,
      bytes: Number(s?.bytes) || 0,
    }));
    const total = sessions.reduce((acc, s) => acc + s.bytes, 0);
    if (total > MAX_TOTAL_BYTES) {
      return err(400, `share too large (${Math.round(total / 1e6)} MB, max ${MAX_TOTAL_BYTES / 1e6} MB)`);
    }
    const id = randomId();
    const ownerToken = randomId() + randomId();
    const manifest: Manifest = {
      v: 1,
      createdAt: Date.now(),
      complete: false,
      tokenHash: await sha256Hex(ownerToken),
      sessions,
    };
    await env.SHARES.put(`share:${id}`, JSON.stringify(manifest));
    return json({ id, ownerToken });
  }

  const m = path.match(/^\/api\/share\/([^/]+)(?:\/([^/]+))?(?:\/([^/]+))?$/);
  if (!m) return err(404, "no such endpoint");
  const id = m[1];

  // Text read API: /text for the whole share, /<session>/text|jsonl for one.
  if (m[3] !== undefined || m[2] === "text") {
    const kind = m[3] ?? "text";
    if (kind !== "text" && kind !== "jsonl") return err(404, "no such endpoint");
    if (req.method !== "GET") return err(405, "method not allowed");
    return handleRead(req, env, id, m[3] === undefined ? undefined : m[2], kind);
  }
  const sub = m[2];

  // PUT /api/share/:id/:n — upload one gzipped session body.
  if (sub !== undefined && sub !== "complete" && req.method === "PUT") {
    const n = Number(sub);
    const owner = await requireOwner(env, id, req);
    if (owner instanceof Response) return owner;
    if (!Number.isInteger(n) || n < 0 || n >= owner.sessions.length) {
      return err(400, "part index out of range");
    }
    const data = await req.arrayBuffer();
    if (data.byteLength === 0) return err(400, "empty body");
    if (data.byteLength > MAX_PART_BYTES) {
      return err(413, `session too large gzipped (${Math.round(data.byteLength / 1e6)} MB, max ${MAX_PART_BYTES / 1e6} MB)`);
    }
    await env.SHARES.put(`share:${id}:${n}`, data);
    return json({ ok: true });
  }

  // POST /api/share/:id/complete — mark all parts uploaded.
  if (sub === "complete" && req.method === "POST") {
    const owner = await requireOwner(env, id, req);
    if (owner instanceof Response) return owner;
    owner.complete = true;
    await env.SHARES.put(`share:${id}`, JSON.stringify(owner));
    return json({ ok: true });
  }

  // GET /api/share/:id — public manifest (without the token hash).
  if (sub === undefined && req.method === "GET") {
    const manifest = await loadManifest(env, id);
    if (!manifest) return err(404, "share not found");
    return json({
      createdAt: manifest.createdAt,
      complete: manifest.complete,
      sessions: manifest.sessions,
    });
  }

  // GET /api/share/:id/:n — gzipped session body (opaque bytes).
  if (sub !== undefined && req.method === "GET") {
    const data = await env.SHARES.get(`share:${id}:${sub}`, "arrayBuffer");
    if (!data) return err(404, "part not found");
    return new Response(data, {
      headers: {
        "Content-Type": "application/octet-stream",
        "Cache-Control": "private, max-age=3600",
      },
    });
  }

  // DELETE /api/share/:id — remove the manifest and every part.
  if (sub === undefined && req.method === "DELETE") {
    const owner = await requireOwner(env, id, req);
    if (owner instanceof Response) return owner;
    await Promise.all([
      env.SHARES.delete(`share:${id}`),
      ...owner.sessions.map((_, n) => env.SHARES.delete(`share:${id}:${n}`)),
    ]);
    return json({ ok: true });
  }

  return err(405, "method not allowed");
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname.startsWith("/api/")) {
      return handleApi(req, env, url.pathname);
    }
    return env.ASSETS.fetch(req);
  },
} satisfies ExportedHandler<Env>;
