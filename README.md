<img src="assets/icon.png" alt="Session Explorer icon" width="104" align="left" hspace="20" vspace="4">

### Session Explorer (macOS)

A native SwiftUI app for browsing your Claude Code sessions. It reads the JSONL
files under `~/.claude/projects`, lets you search across all of them, and opens
any session back up in your terminal.

<br clear="left">

![Session Explorer — sidebar, session list, conversation, and outline](assets/screenshoot-3.png)

Search runs over the full text of every session. Matches are highlighted in the
list and in the conversation.

![Full-text search across sessions](assets/screenshoot-search.png)

## Features

- A sidebar, a session list grouped by date, and the conversation view.
- Full-text search with AND across words and regex via `/pattern/`.
- Adjacent messages from one side are merged into a single reply. Tool calls
  collapse into a compact line and expand on click.
- Brief mode (⌘E) drops tool output and thinking, leaving just the replies.
- Open in terminal (⌘↩) runs `claude --resume <id>` in the project directory.
  Pick Ghostty, Terminal.app, or iTerm2 in Settings.
- The list and the open conversation update live as Claude Code writes to disk.
- Session titles come from `custom-title`, then `ai-title`, otherwise one is
  generated from the first prompt.
- Export as PDF (⌘⇧P) or Markdown — a styled transcript with prompts, tool
  calls, and inline images; works on a multi-selection of sessions.
- Share via link (⌘⇧S): upload a set of sessions to the web viewer and get a
  persistent public URL; your shares can be deleted later.
- Edit user prompts in place — hover a prompt and click the pencil (e.g. fix a
  typo before sharing). The change is written back into the session jsonl.
- Import / export sessions as files: export the raw jsonl as `.jsonl.gz`, and
  open any `.jsonl` / `.jsonl.gz` from disk (⌘O) — it shows up pinned at the
  top of the list, no matter where the file lives.

## Build

Needs [XcodeGen](https://github.com/yonyz/XcodeGen) and Xcode.

```sh
xcodegen generate
xcodebuild -project SessionExplorer.xcodeproj -scheme SessionExplorer -configuration Release build
# or open SessionExplorer.xcodeproj in Xcode and hit Run
```

The app runs unsandboxed: it reads `~/.claude` and uses Apple Events to drive
the terminal. On the first "Open in Terminal" allow Automation for your terminal
(System Settings → Privacy → Automation).

## Keyboard shortcuts

| Key | Action |
|---|---|
| `⌘↑` / `⌘↓` | previous / next session |
| `↑` / `↓` | navigate replies once the transcript is focused |
| `⌘F` | focus search |
| `Esc` | clear search |
| `⌘↩` | open session in terminal |
| `⌘O` | open a `.jsonl` / `.jsonl.gz` session file |
| `⌘⇧P` | export as PDF |
| `⌘⇧S` | share via link |
| `⌘⇧C` | copy resume command |
| `⌘E` | brief mode |
| `⌘B` | show / hide sidebar |
| `⌘⇧B` | show / hide outline |
| `⌘⇧L` | show / hide session list |
| `⌘G` / `⌘⇧G` | next / previous match |
| `[` / `]` (or `⌘[` / `⌘]`) | previous / next reply |
| `⌃⌘[` / `⌃⌘]` | first / last reply |
| `⌘D` | toggle favorite |
| `⌘⌫` | hide session · `⌃Z` undo hide |
| `⌘⇧R` | reveal in Finder |
| `⌘+` / `⌘-` / `⌘0` | zoom text in / out / reset |
| `⌘⇧T` | triage mode (reply to all in turn) |
| `⌘⌃F` | toggle full screen |

## Layout

- `Sources/Core/` — reading and parsing JSONL (`Loader`), text extraction
  (`Content`), search (`Search`), titles (`AutoTitle`), opening a terminal
  (`OpenSession`), and the FSEvents watcher (`FolderWatcher`).
- `Sources/Models/` — domain types and reply assembly.
- `Sources/AppModel.swift` — state, filters, search, and navigation.
- `Sources/Views/` — the SwiftUI views.
