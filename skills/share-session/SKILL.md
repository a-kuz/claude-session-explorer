---
name: share-session
description: Share the current Claude Code session (or any sessions) by link — uploads the session jsonl to the session-explorer web viewer and returns a public /s/<id> URL. Use when the user asks to "share this session", "share session by link", "поделись сессией", "расшарь сессию", or wants a link to a session transcript.
---

# Share Session by Link

Uploads Claude Code session jsonl files to the session-explorer share server
(Cloudflare Workers + KV) and prints a public link. Each run creates a new
independent snapshot link; links expire in 30 days. The viewer renders the
full transcript — prompts, replies, and collapsed tool calls — and works on
mobile.

## Usage

Run the bundled script with Bash:

```sh
python3 "$SKILL_DIR/share.py"                 # share the CURRENT session
python3 "$SKILL_DIR/share.py" <session-uuid>… # share specific sessions by id
python3 "$SKILL_DIR/share.py" /path/to/file.jsonl…
python3 "$SKILL_DIR/share.py" --last 3        # 3 newest sessions of this project
python3 "$SKILL_DIR/share.py" --delete <share-url>
```

`$SKILL_DIR` is this skill's directory (where SKILL.md lives). The current
session is resolved exactly via the `CLAUDE_CODE_SESSION_ID` env var that
Claude Code sets for every Bash command — no newest-file guessing.

The script prints the share URL on the last line. Give that URL to the user.
Owner tokens are stored in `~/.claude/share-tokens.json`, so a share created
on this machine can later be revoked with `--delete`.

## Notes

- The share is a snapshot: content appended to the session after sharing is
  NOT visible by the old link; share again for a fresh snapshot (new URL).
- Server: `https://claude-sessions.a-kuz.online` by default; override
  with the `SESSION_EXPLORER_URL` env var to point at your own deployment
  (the worker source lives in `web/` of this repository).
- Limits: 24 MB gzipped per session, 100 sessions / 100 MB per share.
- The transcript is uploaded as-is — remind the user that anyone with the
  link can read it, including tool inputs/outputs.
