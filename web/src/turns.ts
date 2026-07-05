// DialogMessage → DialogTurn → DialogBlock. Port of the build logic in
// Sources/Models/Models.swift: adjacent messages from one speaker merge into a
// turn (the Claude↔tool ping-pong collapses into one Claude turn); a block is
// one user prompt plus the run of Claude turns it produced.

import { stripNoise } from "./content";
import type { DialogBlock, DialogMessage, DialogTurn, TurnSegment } from "./types";

/** A user message that carries a genuine typed prompt (not tool plumbing). */
export function isRealUserPrompt(m: DialogMessage): boolean {
  if (m.role !== "user" || m.isToolOrMeta) return false;
  return stripNoise(m.bodyText).length > 0;
}

export function buildTurns(messages: DialogMessage[]): DialogTurn[] {
  const turns: DialogTurn[] = [];
  let i = 0;
  while (i < messages.length) {
    const starter = messages[i];
    const asUser = isRealUserPrompt(starter);

    const chunks: string[] = [];
    const tools: DialogTurn["toolUses"] = [];
    const images: string[] = [];
    let firstTimestamp: number | null = starter.timestamp;
    let lastProseTimestamp: number | null = null;
    const orderedPieces: DialogMessage["pieces"] = [];

    const absorb = (m: DialogMessage) => {
      const body = stripNoise(m.bodyText);
      if (body) {
        chunks.push(body);
        if (m.timestamp !== null) lastProseTimestamp = m.timestamp;
      }
      tools.push(...m.toolUses);
      for (const p of m.pieces) {
        if (p.kind === "text") {
          const s = stripNoise(p.text);
          if (s) orderedPieces.push({ kind: "text", text: s });
        } else {
          orderedPieces.push(p);
        }
      }
      images.push(...m.images);
      if (firstTimestamp === null) firstTimestamp = m.timestamp;
    };

    if (asUser) {
      absorb(starter);
      i += 1;
    } else {
      // Assistant turn: swallow everything up to the next real prompt.
      while (i < messages.length && !isRealUserPrompt(messages[i])) {
        absorb(messages[i]);
        i += 1;
      }
    }

    // Contiguous text runs become one prose segment; tools stay in place.
    const segments: TurnSegment[] = [];
    let pendingText: string[] = [];
    let proseCounter = 0;
    const flushProse = () => {
      if (pendingText.length === 0) return;
      segments.push({
        kind: "prose",
        id: `${starter.id}-${proseCounter}`,
        text: pendingText.join("\n\n"),
      });
      proseCounter += 1;
      pendingText = [];
    };
    for (const p of orderedPieces) {
      if (p.kind === "text") pendingText.push(p.text);
      else { flushProse(); segments.push({ kind: "tool", tool: p.tool }); }
    }
    flushProse();

    if (chunks.length > 0 || tools.length > 0 || images.length > 0) {
      turns.push({
        id: starter.id,
        role: asUser ? "user" : "assistant",
        // User: send time. Assistant: time of the final reply text.
        timestamp: asUser ? firstTimestamp : (lastProseTimestamp ?? firstTimestamp),
        bodyChunks: chunks,
        toolUses: tools,
        isUserPrompt: asUser,
        segments,
        images,
      });
    }
  }
  return turns;
}

export function buildBlocks(turns: DialogTurn[]): DialogBlock[] {
  const blocks: DialogBlock[] = [];
  let current: DialogTurn[] = [];
  let leadIsPrompt = false;
  const flush = () => {
    if (current.length === 0) return;
    blocks.push({ id: current[0].id, turns: current, hasPrompt: leadIsPrompt });
    current = [];
  };
  for (const t of turns) {
    if (t.isUserPrompt) {
      flush();
      leadIsPrompt = true;
      current = [t];
    } else {
      if (current.length === 0) leadIsPrompt = false;
      current.push(t);
    }
  }
  flush();
  return blocks;
}
