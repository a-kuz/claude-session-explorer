// Plain-text (markdown) transcript of a dialog: prompts, Claude's prose,
// thinking and tool calls in their original order. DOM-free — used by the
// worker's text API. Image strings in the blocks are URLs, written as
// markdown image links.

import type { DialogBlock, ToolUse } from "./types";

/// How much of each tool call goes into the transcript.
export type ToolDetail = "none" | "brief" | "full";

export interface TranscriptHead {
  title: string;
  project: string;
  sessionId: string;
}

/// A Claude turn can run for an hour: its prose is stamped at the start and
/// again whenever at least this much time has passed since the last stamp.
const STAMP_INTERVAL_MS = 60_000;

function iso(ts: number): string {
  return new Date(ts).toISOString().replace(/\.\d+Z$/, "Z");
}

/** Code fence longer than any backtick run inside `text`. */
function fenced(text: string, lang = ""): string {
  let longest = 0;
  for (const run of text.match(/`+/g) ?? []) longest = Math.max(longest, run.length);
  const fence = "`".repeat(Math.max(3, longest + 1));
  return `${fence}${lang}\n${text}\n${fence}`;
}

function imageLinks(urls: string[], indent = ""): string {
  return urls.map((u) => `${indent}![image](${u})`).join("\n");
}

function toolLines(tool: ToolUse, detail: ToolDetail): string[] {
  const summary = tool.label || tool.arg;
  const head = summary ? `${tool.name}: ${summary}` : tool.name;
  if (detail === "brief") {
    const out = [`- ${head}`];
    if (tool.images.length) out.push(imageLinks(tool.images, "  "));
    return [out.join("\n")];
  }
  const out = [`### ${head}`];
  if (tool.input && tool.input !== "{}") out.push("Input:", fenced(tool.input, "json"));
  // An image-only result has just the "[image]" placeholder as its text.
  const output = tool.images.length ? tool.output.replaceAll("[image]", "").trim() : tool.output;
  if (output) out.push("Result:", fenced(output));
  if (tool.images.length) out.push(imageLinks(tool.images));
  return out;
}

/** Thinking as a markdown blockquote, so it reads apart from the reply. */
function thinkingQuote(text: string): string {
  return ["> Thinking:", ...text.split("\n").map((l) => (l ? `> ${l}` : ">"))].join("\n");
}

export function transcriptText(
  head: TranscriptHead,
  blocks: DialogBlock[],
  tools: ToolDetail,
  thinking: boolean,
): string {
  const parts: string[] = [`# ${head.title || head.sessionId}`];
  const info = [
    head.project ? `Project: ${head.project}` : "",
    `Session: ${head.sessionId}`,
  ].filter(Boolean);
  parts.push(info.join("\n"));

  for (const block of blocks) {
    for (const turn of block.turns) {
      if (turn.isUserPrompt) {
        parts.push(`## User${turn.timestamp === null ? "" : ` · ${iso(turn.timestamp)}`}`);
        const text = turn.bodyChunks.join("\n\n");
        if (text) parts.push(text);
        if (turn.images.length) parts.push(imageLinks(turn.images));
        continue;
      }
      const body: string[] = [];
      let lastStamp: number | null = null;
      // Consecutive brief tool lines form one list, without blank lines between.
      let run: string[] = [];
      const flushRun = () => {
        if (run.length) body.push(run.join("\n"));
        run = [];
      };
      for (const seg of turn.segments) {
        if (seg.kind === "prose") {
          flushRun();
          const ts = seg.timestamp;
          if (ts !== null && (lastStamp === null || ts - lastStamp >= STAMP_INTERVAL_MS)) {
            body.push(`[${iso(ts)}]`);
            lastStamp = ts;
          }
          body.push(seg.text);
        } else if (seg.kind === "thinking") {
          if (thinking) {
            flushRun();
            body.push(thinkingQuote(seg.text));
          }
        } else if (tools === "brief") {
          run.push(...toolLines(seg.tool, tools));
        } else if (tools === "full") {
          body.push(...toolLines(seg.tool, tools));
        }
      }
      flushRun();
      if (turn.images.length) body.push(imageLinks(turn.images));
      if (body.length) parts.push("## Claude", ...body);
    }
  }
  return parts.join("\n\n") + "\n";
}
