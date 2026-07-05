#!/usr/bin/env python3
"""Share Claude Code sessions by link via the session-explorer web viewer.

Protocol (see web/worker/index.ts in the session-explorer repo):
  POST /api/share {sessions:[meta…]}        -> {id, ownerToken}
  PUT  /api/share/<id>/<n>  (gzipped jsonl, X-Owner-Token)
  POST /api/share/<id>/complete
  DELETE /api/share/<id>    (X-Owner-Token)

Usage:
  share.py                    share the current session ($CLAUDE_CODE_SESSION_ID)
  share.py <uuid|path>…       share specific sessions
  share.py --last N           N newest sessions of the current project
  share.py --delete <url|id>  revoke a share created on this machine
"""

import glob
import gzip
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_SERVER = "https://claude-sessions.a-kuz.online"
MAX_PART = 24 * 1024 * 1024  # server-side KV value cap, gzipped


def server() -> str:
    return os.environ.get("SESSION_EXPLORER_URL", DEFAULT_SERVER).rstrip("/")


def config_dir() -> str:
    d = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    return os.path.expanduser(d) if d else os.path.expanduser("~/.claude")


def tokens_path() -> str:
    return os.path.join(config_dir(), "share-tokens.json")


def load_tokens() -> dict:
    try:
        with open(tokens_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_token(share_id: str, token: str) -> None:
    tokens = load_tokens()
    tokens[share_id] = token
    with open(tokens_path(), "w") as f:
        json.dump(tokens, f, indent=2)


def api(method: str, path: str, body: bytes | None = None,
        headers: dict | None = None) -> dict:
    # Cloudflare's bot protection 403s the default Python-urllib user agent.
    hdrs = {"User-Agent": "session-explorer-share-skill/1.0"}
    hdrs.update(headers or {})
    req = urllib.request.Request(f"{server()}/{path}", data=body, method=method,
                                 headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        try:
            msg = json.load(e).get("error", "")
        except ValueError:
            msg = ""
        sys.exit(f"error: {msg or e} ({method} /{path})")
    except urllib.error.URLError as e:
        sys.exit(f"error: {e.reason} ({server()})")


def session_meta(path: str) -> dict:
    """One cheap pass over the jsonl: title records + message counts."""
    custom = ai = None
    messages = 0
    with open(path, "rb") as f:
        for raw in f:
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            t = rec.get("type")
            if t == "custom-title":
                custom = rec.get("customTitle") or custom
            elif t == "ai-title":
                ai = rec.get("aiTitle") or ai
            elif t in ("user", "assistant") and not rec.get("isSidechain"):
                messages += 1
    st = os.stat(path)
    return {
        "name": os.path.basename(path),
        "title": custom or ai or os.path.basename(path).removesuffix(".jsonl"),
        "project": decode_project_dir(os.path.basename(os.path.dirname(path))),
        "messageCount": messages,
        "mtime": int(st.st_mtime * 1000),
        "bytes": st.st_size,
    }


def decode_project_dir(name: str) -> str:
    if name.startswith("-"):
        name = "/" + name[1:]
    return name.replace("-", "/")


def encode_project_dir(path: str) -> str:
    return path.replace("/", "-").replace(".", "-")


def find_by_id(session_id: str) -> str:
    hits = glob.glob(os.path.join(config_dir(), "projects", "*", f"{session_id}.jsonl"))
    if not hits:
        sys.exit(f"error: session {session_id} not found under {config_dir()}/projects")
    return hits[0]


def resolve_targets(args: list[str]) -> list[str]:
    if args and args[0] == "--last":
        n = int(args[1]) if len(args) > 1 else 1
        proj = os.path.join(config_dir(), "projects", encode_project_dir(os.getcwd()))
        files = sorted(glob.glob(os.path.join(proj, "*.jsonl")),
                       key=os.path.getmtime, reverse=True)
        if not files:
            sys.exit(f"error: no sessions found in {proj}")
        return files[:n]
    if args:
        return [a if os.path.sep in a and os.path.exists(a) else find_by_id(a)
                for a in args]
    current = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if not current:
        sys.exit("error: CLAUDE_CODE_SESSION_ID is not set — pass a session uuid or path")
    return [find_by_id(current)]


def delete_share(ref: str) -> None:
    share_id = ref.rstrip("/").rsplit("/", 1)[-1]
    token = load_tokens().get(share_id)
    if not token:
        sys.exit(f"error: no owner token for {share_id} in {tokens_path()}")
    api("DELETE", f"api/share/{share_id}", headers={"X-Owner-Token": token})
    print(f"deleted {server()}/s/{share_id}")


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] == "--delete":
        if len(args) < 2:
            sys.exit("usage: share.py --delete <share-url-or-id>")
        delete_share(args[1])
        return

    files = resolve_targets(args)
    metas = [session_meta(p) for p in files]

    created = api("POST", "api/share",
                  body=json.dumps({"sessions": metas}).encode(),
                  headers={"Content-Type": "application/json"})
    share_id, token = created["id"], created["ownerToken"]

    for n, path in enumerate(files):
        with open(path, "rb") as f:
            body = gzip.compress(f.read(), 9)
        if len(body) > MAX_PART:
            sys.exit(f"error: {os.path.basename(path)} is {len(body) // 1_000_000} MB "
                     f"gzipped (max {MAX_PART // 1_000_000} MB)")
        api("PUT", f"api/share/{share_id}/{n}", body=body,
            headers={"X-Owner-Token": token})
        print(f"uploaded {n + 1}/{len(files)}: {metas[n]['title']}", file=sys.stderr)

    api("POST", f"api/share/{share_id}/complete", body=b"",
        headers={"X-Owner-Token": token})
    save_token(share_id, token)
    print(f"{server()}/s/{share_id}")


if __name__ == "__main__":
    main()
