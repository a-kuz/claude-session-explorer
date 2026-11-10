// Share API over Workers KV + static asset serving.
//
// Keys: share:<id>            — manifest JSON (session metas, owner token hash)
//       share:<id>:<n>        — gzipped jsonl body of session n, chunk 0
//       share:<id>:<n>:<c>    — chunk c ≥ 1 of the same gzip stream (a body
//                               over one KV value is split by the uploader)
//       share:<id>:<n>:t:<v>  — gzipped transcript of session n, variant v
//                               (see ../src/variants.ts), built by the uploader
// Keys never expire; only the owner's DELETE removes them. Bodies are
// stored/served as opaque bytes; the client decompresses with DecompressionStream.
//
// Read API for scripts (session = index in the manifest, or its session id):
//   GET /api/share/<id>/text            — transcripts of every session
//   GET /api/share/<id>/<session>/text  — transcript of one session
//       ?tools=none|brief|full (default brief) — tool calls: omitted, one
//       line each, or with input and result
//       ?thinking=0 — leave Claude's thinking blocks out
//       Images appear as markdown links to the image endpoint below.
//   GET /api/share/<id>/<session>/image/<k> — the session's k-th inline
//       image (0-based, file order), decoded
//   GET /api/share/<id>/<session>/jsonl — the decompressed jsonl

import { DialogParser } from "../src/parser";
import { transcriptText, type ToolDetail } from "../src/transcript";
import { buildBlocks, buildTurns } from "../src/turns";
import { VARIANT_KEYS, variantKey } from "../src/variants";

export interface Env {
  SHARES: KVNamespace;
  ASSETS: Fetcher;
}

const MAX_SESSIONS = 100;
const MAX_CHUNK_BYTES = 24 * 1024 * 1024; // KV value limit is 25 MB
const MAX_CHUNKS = 64; // per session
const MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024; // raw jsonl bytes of one share

interface ManifestSession {
  name: string;
  title: string;
  project: string;
  messageCount: number;
  mtime: number;
  bytes: number;
  /** Number of stored chunks of the gzipped body; absent means 1. */
  chunks?: number;
  /** Variant keys of the transcripts stored for this session. */
  texts?: string[];
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

function chunkKey(id: string, n: number, c: number): string {
  return c === 0 ? `share:${id}:${n}` : `share:${id}:${n}:${c}`;
}

function textKey(id: string, n: number, variant: string): string {
  return `share:${id}:${n}:t:${variant}`;
}

type ByteStream = ReadableStream<Uint8Array>;

/** `count` streams read one after another, each opened when the previous one
 *  ends; `separator` goes between them. Null when the first does not exist. */
async function concatStreams(
  count: number, open: (i: number) => Promise<ByteStream | null>, separator?: Uint8Array,
): Promise<ByteStream | null> {
  const first = await open(0);
  if (!first) return null;
  if (count === 1) return first;
  let i = 0;
  let reader = first.getReader();
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      for (;;) {
        const { done, value } = await reader.read();
        if (!done) {
          controller.enqueue(value);
          return;
        }
        i++;
        if (i >= count) {
          controller.close();
          return;
        }
        const next = await open(i);
        if (!next) {
          controller.error(new Error(`stream ${i} of ${count} missing`));
          return;
        }
        reader = next.getReader();
        if (separator) {
          controller.enqueue(separator);
          return;
        }
      }
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
}

/** The gzipped body of session n: its chunks read one after another. */
function partGzStream(
  env: Env, id: string, manifest: Manifest, n: number,
): Promise<ByteStream | null> {
  return concatStreams(
    manifest.sessions[n]?.chunks ?? 1,
    async (c) => (await env.SHARES.get(chunkKey(id, n, c), "stream")) as ByteStream | null,
  );
}

/** The stored transcripts of `indexes` in one variant, joined the way the
 *  computed ones are. Null unless every one of the sessions has that variant. */
function storedTranscripts(
  env: Env, id: string, manifest: Manifest, indexes: number[], variant: string,
): Promise<ByteStream | null> {
  if (!indexes.every((n) => manifest.sessions[n].texts?.includes(variant))) {
    return Promise.resolve(null);
  }
  return concatStreams(
    indexes.length,
    async (i) => {
      const gz = await env.SHARES.get(textKey(id, indexes[i], variant), "stream");
      return gz ? (gz.pipeThrough(new DecompressionStream("gzip")) as ByteStream) : null;
    },
    new TextEncoder().encode("\n"),
  );
}

async function partTextStream(
  env: Env, id: string, manifest: Manifest, n: number,
): Promise<ReadableStream<Uint8Array> | null> {
  const gz = await partGzStream(env, id, manifest, n);
  if (!gz) return null;
  return gz.pipeThrough(new DecompressionStream("gzip")) as ReadableStream<Uint8Array>;
}

/** Feed a stored session's jsonl to `onLine` line by line off the
 *  decompression stream (the jsonl is never held in memory whole). `onLine`
 *  returning true stops the read. False when the part does not exist. */
async function eachLine(
  env: Env, id: string, manifest: Manifest, n: number, onLine: (line: string) => boolean | void,
): Promise<boolean> {
  const stream = await partTextStream(env, id, manifest, n);
  if (!stream) return false;
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
      if (onLine(buf.slice(start, nl))) {
        await reader.cancel();
        return true;
      }
      start = nl + 1;
    }
    buf = buf.slice(start);
    scanned = buf.length;
    if (done) break;
  }
  onLine(buf);
  return true;
}

/** Transcript of one stored session; images become links to `imageBase/<k>`. */
async function sessionTranscript(
  env: Env, id: string, manifest: Manifest, n: number, tools: ToolDetail, thinking: boolean,
  imageBase: string,
): Promise<string | null> {
  let imageIndex = 0;
  const parser = new DialogParser(() => `${imageBase}/${imageIndex++}`);
  if (!(await eachLine(env, id, manifest, n, (line) => parser.push(line)))) return null;
  const s = manifest.sessions[n];
  return transcriptText(
    { title: s.title, project: s.project, sessionId: s.name.replace(/\.jsonl$/, "") },
    buildBlocks(buildTurns(parser.finish())),
    tools,
    thinking,
  );
}

/// Media types served as-is; any other inline image goes out as a download.
const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

async function sessionImage(
  env: Env, id: string, manifest: Manifest, n: number, k: number,
): Promise<Response> {
  let imageIndex = 0;
  let found: { mediaType: string; data: string } | null = null;
  const parser = new DialogParser((mediaType, data) => {
    if (imageIndex++ === k) found = { mediaType, data };
    return "";
  });
  const exists = await eachLine(env, id, manifest, n, (line) => {
    parser.push(line);
    return found !== null;
  });
  if (!exists) return err(404, "part not found");
  const hit = found as { mediaType: string; data: string } | null;
  if (!hit) return err(404, "image not found");
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(hit.data), (c) => c.charCodeAt(0));
  } catch {
    return err(404, "image not found");
  }
  return new Response(bytes, {
    headers: {
      "Content-Type": IMAGE_TYPES.has(hit.mediaType) ? hit.mediaType : "application/octet-stream",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "private, max-age=3600",
    },
  });
}

function plainText(body: string | ByteStream): Response {
  return new Response(body, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

async function handleRead(
  req: Request, env: Env, id: string, ref: string | undefined, kind: string, arg?: string,
): Promise<Response> {
  const manifest = await loadManifest(env, id);
  if (!manifest) return err(404, "share not found");

  if (kind === "image") {
    const n = sessionIndex(manifest, ref ?? "");
    if (n < 0) return err(404, "session not found");
    if (arg === undefined || !/^\d{1,6}$/.test(arg)) return err(404, "image not found");
    return sessionImage(env, id, manifest, n, Number(arg));
  }

  if (kind === "jsonl") {
    const n = sessionIndex(manifest, ref ?? "");
    if (n < 0) return err(404, "session not found");
    const stream = await partTextStream(env, id, manifest, n);
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
  const stored = await storedTranscripts(env, id, manifest, indexes, variantKey(tools, thinking));
  if (stored) return plainText(stored);
  const texts: string[] = [];
  for (const n of indexes) {
    const imageBase = `${new URL(req.url).origin}/api/share/${id}/${n}/image`;
    const text = await sessionTranscript(env, id, manifest, n, tools, thinking, imageBase);
    if (text === null) return err(404, "part not found");
    texts.push(text);
  }
  return plainText(texts.join("\n"));
}

/** SHA-256 (as sent by the uploader) of every stored body chunk of a share,
 *  keyed "<session>:<chunk>". */
async function uploadedChunks(env: Env, id: string): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  const prefix = `share:${id}:`;
  let cursor: string | undefined;
  do {
    const page = await env.SHARES.list<{ sha?: string }>({ prefix, cursor });
    for (const k of page.keys) {
      const m = k.name.slice(prefix.length).match(/^(\d+)(?::(\d+))?$/);
      if (m && k.metadata?.sha) out[`${m[1]}:${m[2] ?? "0"}`] = k.metadata.sha;
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return out;
}

async function handleApi(req: Request, env: Env, path: string): Promise<Response> {
  // POST /api/share — create a share: manifest with session metas, complete:false.
  // With {resume: <id>} and that share's owner token, an unfinished share of
  // the same sessions is continued instead: the response repeats its id and
  // lists the chunks it already holds.
  if (path === "/api/share" && req.method === "POST") {
    let body: { sessions?: unknown; resume?: unknown };
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
      return err(400, `share too large (${Math.round(total / 1e6)} MB, max ${Math.round(MAX_TOTAL_BYTES / 1e6)} MB)`);
    }
    if (typeof body.resume === "string") {
      const prev = await loadManifest(env, body.resume);
      const token = req.headers.get("X-Owner-Token") ?? "";
      if (prev && !prev.complete && token && (await sha256Hex(token)) === prev.tokenHash
        && prev.sessions.length === sessions.length
        && prev.sessions.every((s, n) => s.name === sessions[n].name)) {
        prev.sessions = sessions;
        await env.SHARES.put(`share:${body.resume}`, JSON.stringify(prev));
        return json({
          id: body.resume, ownerToken: token, uploaded: await uploadedChunks(env, body.resume),
        });
      }
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

  const m = path.match(/^\/api\/share\/([^/]+)(?:\/([^/]+))?(?:\/([^/]+))?(?:\/([^/]+))?$/);
  if (!m) return err(404, "no such endpoint");
  const id = m[1];

  // Read API: /text for the whole share, /<session>/text|jsonl|image/<k> for one.
  if (m[3] !== undefined || m[2] === "text") {
    const kind = m[3] ?? "text";
    const known = kind === "image" ? m[4] !== undefined : m[4] === undefined
      && (kind === "text" || kind === "jsonl");
    if (!known) return err(404, "no such endpoint");
    if (req.method !== "GET") return err(405, "method not allowed");
    return handleRead(req, env, id, m[3] === undefined ? undefined : m[2], kind, m[4]);
  }
  const sub = m[2];

  // PUT /api/share/:id/:n[?chunk=c] — upload one chunk of a gzipped session
  // body (chunk 0 when the parameter is absent). The X-Chunk-SHA256 header is
  // kept with the chunk for resumed uploads.
  if (sub !== undefined && sub !== "complete" && req.method === "PUT") {
    const n = Number(sub);
    const owner = await requireOwner(env, id, req);
    if (owner instanceof Response) return owner;
    if (!Number.isInteger(n) || n < 0 || n >= owner.sessions.length) {
      return err(400, "part index out of range");
    }
    const params = new URL(req.url).searchParams;
    // The body goes to KV as a stream: buffering 24 MB in the worker costs
    // CPU time the free plan does not have.
    const length = Number(req.headers.get("Content-Length") ?? "");
    const variant = params.get("text");
    if (variant !== null) {
      // PUT /api/share/:id/:n?text=<variant> — a gzipped transcript variant.
      if (!VARIANT_KEYS.includes(variant)) return err(400, "unknown transcript variant");
      if (!req.body || !(length > 0)) return err(400, "empty body");
      if (length > MAX_CHUNK_BYTES) return err(413, "transcript too large");
      await env.SHARES.put(textKey(id, n, variant), req.body);
      return json({ ok: true });
    }
    const chunkParam = params.get("chunk") ?? "0";
    const c = /^\d{1,3}$/.test(chunkParam) ? Number(chunkParam) : -1;
    if (c < 0 || c >= MAX_CHUNKS) return err(400, "chunk index out of range");
    if (!req.body || !(length > 0)) return err(400, "empty body");
    if (length > MAX_CHUNK_BYTES) {
      return err(413, `chunk too large (${Math.round(length / 1e6)} MB, max ${Math.round(MAX_CHUNK_BYTES / 1e6)} MB)`);
    }
    const sha = req.headers.get("X-Chunk-SHA256") ?? "";
    await env.SHARES.put(
      chunkKey(id, n, c), req.body,
      /^[0-9a-f]{64}$/.test(sha) ? { metadata: { sha } } : undefined,
    );
    return json({ ok: true });
  }

  // POST /api/share/:id/complete — mark all parts uploaded. An optional
  // {chunks: number[], texts: string[][]} body gives, per session, the chunk
  // count and the variant keys of the uploaded transcripts.
  if (sub === "complete" && req.method === "POST") {
    const owner = await requireOwner(env, id, req);
    if (owner instanceof Response) return owner;
    const raw = await req.text();
    if (raw !== "") {
      let chunks: unknown;
      let texts: unknown;
      try {
        const body = JSON.parse(raw) as { chunks?: unknown; texts?: unknown };
        chunks = body?.chunks;
        texts = body?.texts;
      } catch {
        return err(400, "invalid JSON");
      }
      if (texts !== undefined) {
        if (!Array.isArray(texts) || texts.length !== owner.sessions.length
          || !texts.every((t) => Array.isArray(t) && t.every((v) => VARIANT_KEYS.includes(v)))) {
          return err(400, "texts must list variant keys per session");
        }
        owner.sessions.forEach((s, n) => {
          s.texts = texts[n];
        });
      }
      if (chunks !== undefined) {
        if (!Array.isArray(chunks) || chunks.length !== owner.sessions.length
          || !chunks.every((c) => Number.isInteger(c) && c >= 1 && c <= MAX_CHUNKS)) {
          return err(400, "chunks must list a count per session");
        }
        owner.sessions.forEach((s, n) => {
          s.chunks = chunks[n];
        });
      }
    }
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
    const manifest = await loadManifest(env, id);
    if (!manifest) return err(404, "share not found");
    const n = /^\d+$/.test(sub) ? Number(sub) : -1;
    if (n < 0 || n >= manifest.sessions.length) return err(404, "part not found");
    const data = await partGzStream(env, id, manifest, n);
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
    let cursor: string | undefined;
    do {
      const page = await env.SHARES.list({ prefix: `share:${id}:`, cursor });
      await Promise.all(page.keys.map((k) => env.SHARES.delete(k.name)));
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
    await env.SHARES.delete(`share:${id}`);
    return json({ ok: true });
  }

  return err(405, "method not allowed");
}

/** The viewer page of a share with a link to its plain-text transcript in
 *  the markup itself, so it is there for readers that do not run the script. */
async function sharePage(env: Env, url: URL, id: string): Promise<Response> {
  const page = await env.ASSETS.fetch(new Request(new URL("/", url)));
  const href = `/api/share/${id}/text`;
  return new HTMLRewriter()
    .on("head", {
      element(el) {
        el.append(`<link rel="alternate" type="text/plain" href="${href}" title="Transcript" />`, { html: true });
      },
    })
    .on("#toolbar-spacer", {
      element(el) {
        el.after(`<a id="transcript-link" href="${href}">Transcript</a>`, { html: true });
      },
    })
    .transform(page);
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname.startsWith("/api/")) {
      return handleApi(req, env, url.pathname);
    }
    const shared = url.pathname.match(/^\/s\/([1-9A-HJ-NP-Za-km-z]{10,40})\/?$/);
    if (shared && req.method === "GET") {
      return sharePage(env, url, shared[1]);
    }
    return env.ASSETS.fetch(req);
  },
} satisfies ExportedHandler<Env>;
