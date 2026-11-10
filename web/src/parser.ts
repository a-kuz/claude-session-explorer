// Parsing session jsonl text into metadata and dialog messages.
// Port of Sources/Core/Loader.swift (in-memory text instead of file I/O).

import {
  contentToText, extractContent, isMeaningfulUserText,
  isToolResultContent, oneLine, queuedPrompt, stripNoise,
} from "./content";
import type { DialogMessage, SessionMeta } from "./types";

function parseLine(line: string): Record<string, unknown> | null {
  if (!line) return null;
  // API request logs: multi-megabyte lines that carry no transcript records.
  if (line.startsWith('{"type":"api-request')) return null;
  try {
    const v = JSON.parse(line);
    return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function parseDate(s: unknown): number | null {
  if (typeof s !== "string") return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : t;
}

/** Claude encodes the project path into the dir name by replacing "/" and "."
 *  with "-". Lossy — jsonl carries the real cwd; this is a fallback. */
export function decodeProjectDirName(name: string): string {
  let n = name;
  if (n.startsWith("-")) n = "/" + n.slice(1);
  return n.replaceAll("-", "/");
}

function projectLabel(path: string): string {
  const parts = path.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? path;
}

/** Parse a session's jsonl text into list metadata (no transcript retained). */
export function parseSessionMeta(
  text: string,
  fileName: string,
  projectHint?: string,
): SessionMeta | null {
  const id = fileName.replace(/\.jsonl$/, "");
  let customTitle: string | null = null;
  let aiTitle: string | null = null;
  let cwd: string | null = null;
  let firstUserText = "";
  let lastUserText = "";
  let firstTs: number | null = null;
  let lastTs: number | null = null;
  let lastUserTs: number | null = null;
  let messageCount = 0;
  let userTurnCount = 0;
  let model: string | null = null;

  for (const rawLine of text.split("\n")) {
    const rec = parseLine(rawLine.trim());
    if (!rec) continue;
    const type = rec.type;
    switch (type) {
      case "custom-title":
        if (typeof rec.customTitle === "string") customTitle = rec.customTitle;
        break;
      case "ai-title":
        if (typeof rec.aiTitle === "string") aiTitle = rec.aiTitle;
        break;
      case "user":
      case "assistant": {
        if (rec.isSidechain === true) break;
        messageCount += 1;
        const ts = parseDate(rec.timestamp);
        if (ts !== null) {
          lastTs = ts;
          if (firstTs === null) firstTs = ts;
        }
        const msg = rec.message as Record<string, unknown> | undefined;
        if (type === "assistant" && model === null && typeof msg?.model === "string") {
          model = msg.model;
        }
        if (type === "user") {
          const c = msg?.content;
          if (rec.isMeta === true || isToolResultContent(c)) {
            if (cwd === null && typeof rec.cwd === "string") cwd = rec.cwd;
            break;
          }
          const line = oneLine(stripNoise(contentToText(c)));
          if (isMeaningfulUserText(line)) {
            userTurnCount += 1;
            if (!firstUserText) firstUserText = line;
            lastUserText = line;
            if (ts !== null) lastUserTs = ts;
          }
        }
        if (cwd === null && typeof rec.cwd === "string") cwd = rec.cwd;
        break;
      }
      case "attachment": {
        // Mid-turn user prompt (queued_command) — counts as a user turn.
        const att = rec.isSidechain === true ? null : queuedPrompt(rec);
        if (att) {
          messageCount += 1;
          const ts = parseDate(att.timestamp ?? rec.timestamp);
          if (ts !== null) {
            lastTs = ts;
            if (firstTs === null) firstTs = ts;
          }
          const line = oneLine(stripNoise(contentToText(att.prompt)));
          if (isMeaningfulUserText(line)) {
            userTurnCount += 1;
            if (!firstUserText) firstUserText = line;
            lastUserText = line;
            if (ts !== null) lastUserTs = ts;
          }
        }
        if (cwd === null && typeof rec.cwd === "string") cwd = rec.cwd;
        break;
      }
      default:
        if (cwd === null && typeof rec.cwd === "string") cwd = rec.cwd;
    }
  }

  if (!firstUserText && !lastUserText && messageCount === 0) return null;
  const projectPath = cwd ?? projectHint ?? "";
  return {
    id,
    fileName,
    projectPath,
    projectLabel: projectPath ? projectLabel(projectPath) : "",
    title: customTitle ?? aiTitle,
    titleIsCustom: customTitle !== null,
    lastUserText: lastUserText || firstUserText,
    firstUserText: firstUserText || lastUserText,
    mtime: lastUserTs ?? lastTs ?? Date.now(),
    firstActivity: firstTs,
    lastActivity: lastTs,
    messageCount,
    byteSize: new Blob([text]).size,
    userTurnCount,
    model,
  };
}

/** Incremental jsonl → dialog messages: feed lines in file order, then
 *  `finish()`. With `keepImages` false image payloads are dropped (see
 *  `extractContent`). */
export class DialogParser {
  private messages: DialogMessage[] = [];
  private resultsByID = new Map<string, string>();
  private resultImagesByID = new Map<string, string[]>();
  private index = 0;

  constructor(private keepImages = true) {}

  push(rawLine: string) {
    const rec = parseLine(rawLine.trim());
    if (!rec) return;
    if (rec.isSidechain === true) return;
    const type = rec.type;

    let c: unknown;
    let role: "user" | "assistant";
    let timestamp = rec.timestamp;
    if (type === "user" || type === "assistant") {
      c = (rec.message as Record<string, unknown> | undefined)?.content;
      role = type;
    } else {
      // A prompt sent mid-turn exists only as this attachment record.
      const att = queuedPrompt(rec);
      if (!att) return;
      c = att.prompt;
      role = "user";
      if (typeof att.timestamp === "string") timestamp = att.timestamp;
    }

    const msgText = contentToText(c).trim();
    const ex = extractContent(c, this.keepImages);
    for (const [k, v] of ex.resultsByID) this.resultsByID.set(k, v);
    for (const [k, v] of ex.resultImagesByID) this.resultImagesByID.set(k, v);
    if (!msgText && ex.toolUses.length === 0 && ex.toolResults.length === 0
      && ex.imageCount === 0 && ex.pieces.length === 0) {
      return;
    }

    const isToolOrMeta = type === "user" && (rec.isMeta === true || isToolResultContent(c));
    const recUUID = typeof rec.uuid === "string" ? rec.uuid : "";
    this.messages.push({
      id: recUUID || `msg-${this.index}`,
      uuid: recUUID,
      role,
      text: msgText,
      timestamp: parseDate(timestamp),
      isToolOrMeta,
      toolUses: ex.toolUses,
      toolResults: ex.toolResults,
      bodyText: ex.bodyText,
      imageCount: ex.imageCount,
      pieces: ex.pieces,
      images: ex.images,
    });
    this.index += 1;
  }

  finish(): DialogMessage[] {
    // Link each tool call to its result (results arrive in later messages).
    for (const m of this.messages) {
      for (const t of m.toolUses) {
        if (!t.toolUseID) continue;
        const out = this.resultsByID.get(t.toolUseID);
        if (out) t.output = out;
        const imgs = this.resultImagesByID.get(t.toolUseID);
        if (imgs) t.images = imgs;
      }
    }
    return this.messages;
  }
}

/** Fully parse jsonl text into an ordered list of dialog messages. */
export function parseDialog(text: string): DialogMessage[] {
  const parser = new DialogParser();
  for (const rawLine of text.split("\n")) parser.push(rawLine);
  return parser.finish();
}
