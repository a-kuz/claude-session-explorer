// Domain types — port of Sources/Models/Models.swift.

export interface ToolUse {
  name: string;
  /// Short single-line summary of the most salient argument.
  arg: string;
  /// Human-readable label — the tool's `description` input, when present.
  label: string;
  /// Pretty-printed input, shown when the tool is expanded.
  input: string;
  /// Structured input object (when the input was an object) — rendered
  /// field-by-field instead of a raw JSON dump.
  inputObj: Record<string, unknown> | null;
  /// jsonl tool_use id — links this call to its tool_result.
  toolUseID: string;
  /// Result text of the call (filled by linking tool_result later).
  output: string;
}

export type ContentPiece =
  | { kind: "text"; text: string }
  | { kind: "tool"; tool: ToolUse };

export type Role = "user" | "assistant";

export interface DialogMessage {
  id: string;
  uuid: string;
  role: Role;
  text: string;
  timestamp: number | null;
  /// tool_result-only / meta message (absorbed into the assistant turn).
  isToolOrMeta: boolean;
  toolUses: ToolUse[];
  toolResults: string[];
  bodyText: string;
  imageCount: number;
  pieces: ContentPiece[];
  /// base64 data-URLs of inline image blocks, in content order.
  images: string[];
}

export interface SessionMeta {
  id: string;
  fileName: string;
  projectPath: string;
  projectLabel: string;
  title: string | null;
  titleIsCustom: boolean;
  lastUserText: string;
  firstUserText: string;
  /// Display/sort time (ms since epoch): last activity, else file order.
  mtime: number;
  firstActivity: number | null;
  lastActivity: number | null;
  messageCount: number;
  byteSize: number;
  userTurnCount: number;
  model: string | null;
}

export interface SessionEntry {
  meta: SessionMeta;
  /// Raw jsonl text (dialog is parsed lazily from it).
  text: string;
  readOnly: boolean;
}

/// One ordered segment of a turn: prose html or a tool call, in sequence.
export type TurnSegment =
  | { kind: "prose"; id: string; text: string }
  | { kind: "tool"; tool: ToolUse };

export interface DialogTurn {
  id: string;
  role: Role;
  timestamp: number | null;
  bodyChunks: string[];
  toolUses: ToolUse[];
  isUserPrompt: boolean;
  segments: TurnSegment[];
  images: string[];
}

/// One user prompt plus Claude's responses to it — the unit of scroll/outline.
export interface DialogBlock {
  id: string;
  turns: DialogTurn[];
  hasPrompt: boolean;
}
