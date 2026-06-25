# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS application (SwiftUI, macOS 26+, Swift 5) for navigating Claude Code
sessions — `~/.claude/projects/*.jsonl`. A port of the `session-explorer-2` TUI.
Unsandboxed (it needs access to `~/.claude` and Apple Events for terminal integration).

### Claude Code references

The jsonl format is closed and unspecified — its behavior is determined from these
sources (use them as reference; do not make edits there):

- `~/ws/Claude-code` — the unpacked source of the official CLI (`QueryEngine.ts`,
  `Tool.ts`, `cli/`, …): which records and fields Claude Code writes to jsonl.
- `~/ws/openclaude` — an open-source implementation ([github.com/Gitlawb/openclaude](https://github.com/Gitlawb/openclaude)),
  a second perspective on the same format and protocol.

## Build and run

The project is generated from `project.yml` via XcodeGen — the `.xcodeproj` is not
edited by hand. After changing the file list/settings, regenerate the project:

```sh
xcodegen generate
xcodebuild -project SessionExplorer.xcodeproj -scheme SessionExplorer -configuration Release build
# or open SessionExplorer.xcodeproj in Xcode and Run (Debug)
```

There are no tests in the project.

## Session format (jsonl)

One `<session-id>.jsonl` file per session, append-only, one record per line. The file
name = `sessionId`. The `~/.claude/projects/<encoded-cwd>/` directory encodes the
project path, replacing `/` and `.` with `-` (lossy — the real `cwd` is taken from the
records themselves, see `Loader.decodeProjectDirName`). The record discriminator is the
`type` field.

**Dialog records** (`type: "user"` | `"assistant"`) carry a common envelope:
`uuid` (the stable record id — the basis of message identity), `parentUuid`
(the `uuid` of the parent record in the reply tree — see branch below), `sessionId`,
`timestamp`, `cwd`, `gitBranch`, `version`, `userType`, `entrypoint`; optionally
`forkedFrom`, `isSidechain` (see "Concepts" below).
The content is in `message` (Anthropic Messages API form):

- `message.content` — either a string or an array of blocks with a `type`:
  - assistant: `text` (`{text}`), `thinking` (`{thinking, signature}`),
    `tool_use` (`{id, name, input, caller}`);
  - user: `text` (`{text}`), `image` (`{source}`), `tool_result`
    (`{tool_use_id, content}` — linked to a `tool_use` by id).
- assistant records also carry `requestId` and `message.model`; tool_result records
  carry `toolUseResult`, `promptId`, `sourceToolAssistantUUID`.

**Service records** (no `message`, a light envelope `{sessionId, type, …}`):
`custom-title` (`{customTitle}` — the user-set name), `ai-title`
(`{aiTitle}` — generated), `last-prompt` (`{lastPrompt, leafUuid}`),
`permission-mode` (`{permissionMode}`), `mode`, `queue-operation`,
`attachment` (`{attachment}` — attachments), `file-history-snapshot`
(`{messageId, snapshot, isSnapshotUpdate}`), `system`, `pr-link`, `slug`.

### Concepts

- **session-id** — the session UUID. Always matches the file name (invariant:
  in every record `sessionId` == the basename without `.jsonl`), appears in
  `claude --resume <id>`. Don't confuse it with the order in the list: sessions are
  sorted by `mtime` (the time of the user's last prompt, `metaSchemaVersion v2`).
- **session-name** (the title) — priority `customTitle` (`type:"custom-title"`,
  set by the user) → `aiTitle` (`type:"ai-title"`, auto). If neither is present,
  `AutoTitle` deterministically derives a title from the first prompt.
  These three records overwrite one another: the LAST one in the file is used
  (`Loader` reads them exactly that way). `titleIsCustom` distinguishes a
  user-set title from an auto one.
- **slug** — a human-readable session identifier (`humble-snuggling-beacon`),
  stable within a session; used by the CLI for worktree/tmux names. This is NOT
  the UI title.
  Three DIFFERENT branching mechanisms (easy to confuse — their purposes differ):

- **`/branch`** — creates a SEPARATE session jsonl in `projects/<cwd>/` with a
  `forkedFrom: {sessionId, messageUuid}` field on the first record: the new file is
  branched off the `messageUuid` record of the source session `sessionId`. A full
  standalone session (its own `sessionId` = its own file name), `--resume`-able; the
  UI shows it as a separate row. A single logical conversation can be spread across a
  chain of files linked by `forkedFrom`. A very common case, not an anomaly.
- **`/fork`** — NOT a separate session, but a subagent. Written to
  `<session>/subagents/agent-<agentId>.jsonl` (+ a `.meta.json` with
  `{agentType:"fork", isFork:true, description, name}`). The first record is
  `fork-context-ref` (`{agentId, parentSessionId, parentLastUuid, contextLength}`):
  the subagent starts with a copy of the parent's context at the `parentLastUuid`
  record. Its replies have `isSidechain: true` and CARRY the PARENT's `sessionId`
  (not their own); there is NO `forkedFrom` field here. So `/fork` is a kind of
  sidechain (see below), not a new session in the list.
- **in-file tree** — within a single jsonl, records are linked into a tree via
  `parentUuid` (the parent's `uuid`), and a parent can have multiple children
  (rewinding/editing a prompt appends diverging replies to the same file).
  The "current" line is the path from the root to the active leaf; `last-prompt`
  (`{lastPrompt, leafUuid}`) points to that leaf. Linear sessions are a special case
  (each parent has a single child). Currently `Loader` reads records LINEARLY in file
  order and does not use `parentUuid`/`leafUuid` — under such branching, replies from
  different branches will be mixed; if you fix this, reconstruct the active line from
  `leafUuid`.

  None of this should be confused with `gitBranch` — that is the git branch of `cwd`
  at the time of the record, a separate field with no relation to session/dialog
  branching.
- **sidechain** (`isSidechain: true`) — records of a side branch (a subagent dialog:
  `AgentTool` or `/fork`), not the main transcript. They carry the parent's `sessionId`.
  The official CLI excludes them from the main view and statistics
  (`!isSidechain`); do the same.
- **system-reminder** — a `<system-reminder>…</system-reminder>` block INSIDE the
  message text (service instructions injected by the harness — caveats, malware
  reminders, etc.), not a separate `type`. `Content.swift` filters such noise out of
  the displayed text; when adding parsing, keep in mind this is not the user.

Parsing is resilient to unfamiliar `type`s/fields (Claude Code adds them over time):
`Content.swift` extracts text and filters out service noise, unknown records are
ignored. Establish the truth about the format from the references above and from real
files in `~/.claude/projects`, not from guesses.

## Architecture

Data flow: jsonl on disk → `Loader` (parsing) → `Store` (SwiftData cache) →
`AppModel` (state) → `Views`.

### Data layer (`Sources/Core/`)

- **`Loader.swift`** — scans `~/.claude/projects`, parses jsonl. Each line is parsed
  exactly once for the lifetime of the cache: unchanged files are skipped by mtime,
  changed ones are read only from the saved `parsedOffset` (jsonl is append-only).
  `parseSessionMeta` reads the file once and keeps only the light fields (no
  transcript). The full dialog is loaded lazily and cached in memory (LRU);
  `loadDialogTail` reads only the tail of the open session.
- **`Store.swift`** — a persistent cache on SwiftData (SQLite) in
  `Application Support/SessionExplorer/cache.store`. Stores **metadata only**
  (`SessionRecord`). On schema incompatibility the store is deleted and recreated.
  `AppModel.metaSchemaVersion` forces recomputation of stale rows.
- **`Content.swift`** — extracting text from the `message.content` forms, filtering
  out noise (`<command-*>`, caveats, reminders).
- **`Search.swift`** — a two-level cancellable search: cheap (instant, over
  titles/last replies, on the main actor) + deep (incremental over the whole dialog,
  off-thread, 250ms debounce, chunks of 40). AND across words, regex via `/pattern/`.
- **`AutoTitle.swift`** — a lazy deterministic title from the first request
  (no network/LLM), when there is no `custom-title`/`ai-title`.
- **`OpenSession.swift`** — open a session in the terminal (Ghostty / Terminal.app /
  iTerm2) via AppleScript: `claude --resume <id>` in the project directory. For Ghostty
  it focuses an already-open tab for the session (matched by title) or creates a new one.
- **`FolderWatcher.swift`** — FSEvents directory watching; the list and the open dialog
  update in realtime.

### Model (`Sources/Models/Models.swift`)

Domain types and the dialog render hierarchy:
`DialogMessage` (a raw message) → `DialogTurn` (adjacent messages from the same side
are merged; the tool ping-pong is collapsed) → `DialogBlock` (a user prompt plus
Claude's responses to it). **A block is the unit of scrolling, navigation, and the
outline.** `ContentPiece` (prose/tool in original order — tools are rendered in place).
Messages have stable ids from the jsonl `uuid`, so that when reading the tail their
identity is not lost and SwiftUI re-renders only what is new.

### State (`Sources/AppModel.swift`)

`@MainActor ObservableObject` — the single source of truth. Key invariants:

- **Two independent filters**: `scope` (single-select: all/favorites/today/
  last24h/last2d/week) and `selectedProjectPaths` (multi-select of projects), applied
  together.
- **Coalescing of list updates**: background writes (including the active session
  itself) must NOT jostle the list while scrolling — list updates are debounced
  (~1.2s), applied on idle and only if the visible state's `signature()` changed;
  they wait for scrolling to finish (`listIsScrolling`). The open dialog updates
  immediately and separately (append-only via `refreshOpenDialog`).
- **Triage mode** ("Reply to everyone in turn") — a separate full-screen mode
  (`triageMode`, not a sidebar filter), going through `attentionSessions` (needs a
  reply + not hidden + passes the project filter).
- **UI state is persisted** in UserDefaults (`persistUIState`/`restoreUIState`); column
  widths are committed only at the end of a drag (`commitWidths`) — a synchronous write
  on every delta frame caused jitter.

### Views (`Sources/Views/`)

`RootView` (three-to-four columns), `SidebarView`, `SessionListView`, `DetailView`,
`MessageView` (replies + compact tools), `OutlineView` (a prompt outline),
`TriageView`, `InspectorView`, `Toolbar`, `HotkeyHelpView`. `Commands.swift` —
menus/hotkeys (`AppCommands`). `Theme.swift`, `Markdown.swift`, `Format.swift`,
`FlowLayout.swift`, `Scaling.swift` — styling and utilities.

## Conventions

- **Don't simplify.** Don't throw out invariants, edge-case handling,
  debounces/coalescing, off-thread logic, or identity checks under the guise of
  "simplification" — each such piece here stands for a concrete pain (list jitter,
  races when switching sessions, branching/reading the jsonl tail). Change exactly
  what was asked; if the code seems redundant — ask first.
- Render terminology: turn / block / piece (see Models). Use these terms, don't invent
  your own.
- Any session I/O operation (parsing, deep search, loading the dialog/images) runs
  off-thread via `Task.detached`; the result is applied on the `MainActor` with a check
  that `selectedID` is still the same.
- The transcript is never persisted to the DB — only lazily from jsonl.
