// Parsing session jsonl text into metadata and dialog messages.
// Port of Sources/Core/Loader.swift (in-memory text instead of file I/O).

import {
  contentToText, extractContent, isMeaningfulUserText,
  isToolResultContent, oneLine, stripNoise,
} from "./content";
import type { DialogMessage, SessionMeta } from "./types";

function parseLine(line: string): Record<string, unknown> | null {
  if (!line) return null;
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

/** Fully parse jsonl text into an ordered list of dialog messages. */
export function parseDialog(text: string): DialogMessage[] {
  const messages: DialogMessage[] = [];
  const resultsByID = new Map<string, string>();
  let index = 0;

  for (const rawLine of text.split("\n")) {
    const rec = parseLine(rawLine.trim());
    if (!rec) continue;
    const type = rec.type;
    if (type !== "user" && type !== "assistant") continue;
    if (rec.isSidechain === true) continue;

    const msg = rec.message as Record<string, unknown> | undefined;
    const c = msg?.content;
    const msgText = contentToText(c).trim();
    const ex = extractContent(c);
    for (const [k, v] of ex.resultsByID) resultsByID.set(k, v);
    if (!msgText && ex.toolUses.length === 0 && ex.toolResults.length === 0 && ex.imageCount === 0) {
      continue;
    }

    const isToolOrMeta = type === "user" && (rec.isMeta === true || isToolResultContent(c));
    const recUUID = typeof rec.uuid === "string" ? rec.uuid : "";
    messages.push({
      id: recUUID || `msg-${index}`,
      uuid: recUUID,
      role: type,
      text: msgText,
      timestamp: parseDate(rec.timestamp),
      isToolOrMeta,
      toolUses: ex.toolUses,
      toolResults: ex.toolResults,
      bodyText: ex.bodyText,
      imageCount: ex.imageCount,
      pieces: ex.pieces,
      images: ex.images,
    });
    index += 1;
  }

  // Link each tool call to its result (results arrive in later messages).
  for (const m of messages) {
    for (const t of m.toolUses) {
      const out = t.toolUseID ? resultsByID.get(t.toolUseID) : undefined;
      if (out) t.output = out;
    }
  }
  return messages;
}
