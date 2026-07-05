// Lazy deterministic auto-title from the first prompt — port of
// Sources/Core/AutoTitle.swift. No network/LLM, memoized per session id.

import type { SessionMeta } from "./types";

const cache = new Map<string, string>();

const leadingFiller =
  /^(please|could you|can you|let's|lets|пожалуйста|плиз|можешь|нужно|надо|сделай|сделать|давай)\s+/i;

function clean(text: string): string {
  let t = text.replace(/\s+/g, " ").trim();
  t = t.replace(/\[Image #\d+\]/g, "");
  t = t.replace(/```[\s\S]*?```/g, " ").trim();
  t = t.replace(leadingFiller, "");
  return t.trim();
}

function firstClause(text: string, max = 60): string {
  const t = clean(text);
  if (!t) return "";
  let head = t;
  const m = t.match(/[.!?\n]/);
  if (m && m.index !== undefined && m.index > 8 && m.index <= max) {
    head = t.slice(0, m.index);
  }
  if (head.length > max) {
    const slice = head.slice(0, max);
    const lastSpace = slice.lastIndexOf(" ");
    head = lastSpace > max / 2 ? slice.slice(0, lastSpace) + "…" : slice + "…";
  }
  return head.trim();
}

/** Display title for a session — explicit if present, else generated. */
export function displayTitle(meta: SessionMeta): string {
  if (meta.title) return meta.title;
  const cached = cache.get(meta.id);
  if (cached) return cached;
  const source = meta.firstUserText || meta.lastUserText;
  const generated = source
    ? firstClause(source).replace(/^./, (c) => c.toUpperCase())
    : "(empty session)";
  cache.set(meta.id, generated);
  return generated;
}
