// Plain-text (markdown) transcript of a dialog: prompts, Claude's prose and
// tool calls in their original order. DOM-free — used by the worker's text API.

import type { DialogBlock, ToolUse } from "./types";

/// How much of each tool call goes into the transcript.
export type ToolDetail = "none" | "brief" | "full";

export interface TranscriptHead {
  title: string;
  project: string;
  sessionId: string;
}

function stamp(ts: number | null): string {
  return ts === null ? "" : ` · ${new Date(ts).toISOString().replace(/\.\d+Z$/, "Z")}`;
}

/** Code fence longer than any backtick run inside `text`. */
function fenced(text: string, lang = ""): string {
  let longest = 0;
  for (const run of text.match(/`+/g) ?? []) longest = Math.max(longest, run.length);
  const fence = "`".repeat(Math.max(3, longest + 1));
  return `${fence}${lang}\n${text}\n${fence}`;
}

function imagesLine(count: number): string {
  return count === 1 ? "[image]" : `[${count} images]`;
}

function toolLines(tool: ToolUse, detail: ToolDetail): string[] {
  const summary = tool.label || tool.arg;
  const head = summary ? `${tool.name}: ${summary}` : tool.name;
  if (detail === "brief") {
    return [`- ${head}${tool.images.length ? ` ${imagesLine(tool.images.length)}` : ""}`];
  }
  const out = [`### ${head}`];
  if (tool.input && tool.input !== "{}") out.push("Input:", fenced(tool.input, "json"));
  if (tool.output) out.push("Result:", fenced(tool.output));
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
        parts.push(`## User${stamp(turn.timestamp)}`);
        const text = turn.bodyChunks.join("\n\n");
        if (text) parts.push(text);
        if (turn.images.length) parts.push(imagesLine(turn.images.length));
        continue;
      }
      const body: string[] = [];
      // Consecutive brief tool lines form one list, without blank lines between.
      let run: string[] = [];
      const flushRun = () => {
        if (run.length) body.push(run.join("\n"));
        run = [];
      };
      for (const seg of turn.segments) {
        if (seg.kind === "prose") {
          flushRun();
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
      if (turn.images.length) body.push(imagesLine(turn.images.length));
      if (body.length) parts.push(`## Claude${stamp(turn.timestamp)}`, ...body);
    }
  }
  return parts.join("\n\n") + "\n";
}
