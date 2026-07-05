// Share API over Workers KV + static asset serving.
//
// Keys: share:<id>            — manifest JSON (session metas, owner token hash)
//       share:<id>:<n>        — gzipped jsonl body of session n
// All keys carry a 30-day expirationTtl. Bodies are stored/served as opaque
// bytes; the client decompresses with DecompressionStream.

export interface Env {
  SHARES: KVNamespace;
  ASSETS: Fetcher;
}

const TTL_SECONDS = 30 * 24 * 3600;
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
    await env.SHARES.put(`share:${id}`, JSON.stringify(manifest), { expirationTtl: TTL_SECONDS });
    return json({ id, ownerToken, ttlDays: TTL_SECONDS / 86400 });
  }

  const m = path.match(/^\/api\/share\/([^/]+)(?:\/([^/]+))?$/);
  if (!m) return err(404, "no such endpoint");
  const id = m[1];
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
    await env.SHARES.put(`share:${id}:${n}`, data, { expirationTtl: TTL_SECONDS });
    return json({ ok: true });
  }

  // POST /api/share/:id/complete — mark all parts uploaded.
  if (sub === "complete" && req.method === "POST") {
    const owner = await requireOwner(env, id, req);
    if (owner instanceof Response) return owner;
    owner.complete = true;
    await env.SHARES.put(`share:${id}`, JSON.stringify(owner), { expirationTtl: TTL_SECONDS });
    return json({ ok: true });
  }

  // GET /api/share/:id — public manifest (without the token hash).
  if (sub === undefined && req.method === "GET") {
    const manifest = await loadManifest(env, id);
    if (!manifest) return err(404, "share not found or expired");
    return json({
      createdAt: manifest.createdAt,
      complete: manifest.complete,
      sessions: manifest.sessions,
    });
  }

  // GET /api/share/:id/:n — gzipped session body (opaque bytes).
  if (sub !== undefined && req.method === "GET") {
    const data = await env.SHARES.get(`share:${id}:${sub}`, "arrayBuffer");
    if (!data) return err(404, "part not found or expired");
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
