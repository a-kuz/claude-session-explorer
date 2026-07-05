// Extracting human-readable text from message content and deciding which user
// messages are real prompts vs machinery. Port of Sources/Core/Content.swift.

import type { ContentPiece, ToolUse } from "./types";

const noisePrefixes = [
  "<task-notification>", "<local-command-caveat>", "<local-command-stdout>",
  "<command-name>", "<command-message>", "<command-args>",
  "<bash-stdout>", "<bash-stderr>", "<user-memory-input>",
  "<system-reminder>", "<<autonomous-loop", "Caveat: The messages below",
];

const noiseExact = new Set([
  "Continue from where you left off.",
  "[Request interrupted by user]",
  "(no content)",
]);

/** Flatten a content value (string | array of blocks) into plain text. */
export function contentToText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    if (typeof block === "string") { parts.push(block); continue; }
    if (typeof block !== "object" || block === null) continue;
    const b = block as Record<string, unknown>;
    switch (b.type) {
      case "text":
        if (typeof b.text === "string") parts.push(b.text);
        break;
      case "image": parts.push("[image]"); break;
      case "document": parts.push("[document]"); break;
      case "tool_use":
        parts.push(`[→ ${typeof b.name === "string" ? b.name : "tool"}]`);
        break;
      case "tool_result": {
        const inner = contentToText(b.content);
        parts.push(inner ? `[result] ${inner}` : "[result]");
        break;
      }
      case "thinking": break;
      default:
        if (typeof b.text === "string") parts.push(b.text);
    }
  }
  return parts.join("\n").trim();
}

/** Argument keys surfaced as the short tool summary, in priority order. */
const argKeys = [
  "file_path", "path", "command", "pattern", "query", "url",
  "prompt", "description", "old_string",
];

function summarizeToolInput(input: unknown): string {
  if (typeof input !== "object" || input === null) return "";
  const obj = input as Record<string, unknown>;
  for (const k of argKeys) {
    const v = obj[k];
    if (typeof v === "string" && v.trim()) return oneLine(v, 80);
  }
  for (const v of Object.values(obj)) {
    if (typeof v === "string" && v.trim()) return oneLine(v, 80);
  }
  return "";
}

function formatToolInput(input: unknown): string {
  if (input === undefined || input === null) return "";
  try {
    return JSON.stringify(input, null, 2) ?? "";
  } catch {
    return String(input);
  }
}

export interface ExtractedContent {
  bodyText: string;
  toolUses: ToolUse[];
  toolResults: string[];
  imageCount: number;
  pieces: ContentPiece[];
  /** base64 data-URLs of inline image blocks, in order. */
  images: string[];
  /** tool_use_id → result text carried by this (user) message. */
  resultsByID: Map<string, string>;
}

/** Split a message's content into prose, tool calls, and tool results. */
export function extractContent(content: unknown): ExtractedContent {
  const out: ExtractedContent = {
    bodyText: "", toolUses: [], toolResults: [], imageCount: 0,
    pieces: [], images: [], resultsByID: new Map(),
  };
  if (typeof content === "string") {
    out.bodyText = content.trim();
    if (out.bodyText) out.pieces.push({ kind: "text", text: out.bodyText });
    return out;
  }
  if (!Array.isArray(content)) return out;

  const bodyParts: string[] = [];

  // Coalesce adjacent prose into one text piece so a tool between two
  // paragraphs splits them, but consecutive text stays one block.
  const pushText = (t: string) => {
    const last = out.pieces[out.pieces.length - 1];
    if (last && last.kind === "text") last.text += "\n" + t;
    else out.pieces.push({ kind: "text", text: t });
  };

  const handleText = (t: string) => {
    out.imageCount += imageFileRefs(t).length;
    const cleaned = stripImageRefs(t);
    if (cleaned) { bodyParts.push(cleaned); pushText(cleaned); }
  };

  for (const block of content) {
    if (typeof block === "string") { handleText(block); continue; }
    if (typeof block !== "object" || block === null) continue;
    const b = block as Record<string, unknown>;
    switch (b.type) {
      case "text":
        if (typeof b.text === "string") handleText(b.text);
        break;
      case "image": {
        out.imageCount += 1;
        const src = b.source as Record<string, unknown> | undefined;
        if (src && typeof src.data === "string" && typeof src.media_type === "string") {
          out.images.push(`data:${src.media_type};base64,${src.data}`);
        }
        break;
      }
      case "document":
        bodyParts.push("[document]"); pushText("[document]");
        break;
      case "tool_use": {
        const tool: ToolUse = {
          name: typeof b.name === "string" ? b.name : "tool",
          arg: summarizeToolInput(b.input),
          input: formatToolInput(b.input),
          toolUseID: typeof b.id === "string" ? b.id : "",
          output: "",
        };
        out.toolUses.push(tool);
        out.pieces.push({ kind: "tool", tool });
        break;
      }
      case "tool_result": {
        const txt = contentToText(b.content);
        out.toolResults.push(txt);
        if (typeof b.tool_use_id === "string") out.resultsByID.set(b.tool_use_id, txt);
        break;
      }
      case "thinking": break;
      default:
        if (typeof b.text === "string") handleText(b.text);
    }
  }
  out.bodyText = bodyParts.join("\n").trim();
  return out;
}

const imageRefRe = /\[Image: source: ([^\]]+)\]/g;

export function imageFileRefs(text: string): string[] {
  return [...text.matchAll(imageRefRe)].map((m) => m[1].trim());
}

export function stripImageRefs(text: string): string {
  return text.replace(imageRefRe, "").trim();
}

/** Does this content represent a tool_result / meta payload (not a typed prompt)? */
export function isToolResultContent(content: unknown): boolean {
  if (!Array.isArray(content)) return false;
  const blocks = content.filter((b) => typeof b === "object" && b !== null) as Record<string, unknown>[];
  if (blocks.length === 0) return false;
  return blocks.every((b) => b.type === "tool_result" || b.type === "image" || b.type === "document");
}

const noiseRemovals: RegExp[] = [
  /<local-command-caveat>[\s\S]*?<\/local-command-caveat>/g,
  /<command-name>[\s\S]*?<\/command-name>/g,
  /<command-message>[\s\S]*?<\/command-message>/g,
  /<command-args>[\s\S]*?<\/command-args>/g,
  /<local-command-stdout>[\s\S]*?<\/local-command-stdout>/g,
  /<bash-stdout>[\s\S]*?<\/bash-stdout>/g,
  /<bash-stderr>[\s\S]*?<\/bash-stderr>/g,
  /<system-reminder>[\s\S]*?<\/system-reminder>/g,
  /<user-memory-input>[\s\S]*?<\/user-memory-input>/g,
  /<task-notification>[\s\S]*?<\/task-notification>/g,
  /Caveat: The messages below[^\n]*/g,
  /\[Request interrupted by user[^\]]*\]/g,
  /<<autonomous-loop[^>]*>>/g,
  /\[Image #\d+\]/g,
  /\[Image: source: [^\]]+\]/g,
  /\[image\]/g,
  /\[document\]/g,
  /<\/?bash-input>/g,
];

/** Strip machinery wrappers so only the real typed prompt remains. */
export function stripNoise(text: string): string {
  let t = text;
  if (t.includes("<") || t.includes("[") || t.startsWith("Caveat: The messages below")) {
    for (const re of noiseRemovals) t = t.replace(re, "");
  }
  return t.replace(/\n{3,}/g, "\n\n").trim();
}

/** Is this text a real user prompt worth surfacing (not command/system noise)? */
export function isMeaningfulUserText(text: string): boolean {
  const t = text.trim();
  if (!t) return false;
  if (noiseExact.has(t)) return false;
  return !noisePrefixes.some((p) => t.startsWith(p));
}

/** Collapse whitespace and trim for single-line display. */
export function oneLine(text: string, max = 400): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  return collapsed.length > max ? collapsed.slice(0, max) : collapsed;
}
