// The stored transcript variants of a shared session: every combination of
// tool detail and thinking the text API offers, built from one parse.

import { DialogParser } from "./parser";
import { transcriptText, type ToolDetail, type TranscriptHead } from "./transcript";
import { buildBlocks, buildTurns } from "./turns";

const TOOL_DETAILS: ToolDetail[] = ["none", "brief", "full"];

/** Key of one variant: tool detail followed by 1 (with thinking) or 0. */
export function variantKey(tools: ToolDetail, thinking: boolean): string {
  return `${tools}${thinking ? 1 : 0}`;
}

export const VARIANT_KEYS: string[] = TOOL_DETAILS.flatMap((t) => [variantKey(t, false), variantKey(t, true)]);

/** Fed a session's jsonl line by line; images become links `imageBase/<k>`
 *  (k = index of the inline image in file order). */
export class VariantBuilder {
  private imageIndex = 0;
  private parser: DialogParser;

  constructor(imageBase: string) {
    this.parser = new DialogParser(() => `${imageBase}/${this.imageIndex++}`);
  }

  push(line: string) {
    this.parser.push(line);
  }

  /** Transcript text by variant key. */
  finish(head: TranscriptHead): Record<string, string> {
    const blocks = buildBlocks(buildTurns(this.parser.finish()));
    const out: Record<string, string> = {};
    for (const tools of TOOL_DETAILS) {
      for (const thinking of [false, true]) {
        out[variantKey(tools, thinking)] = transcriptText(head, blocks, tools, thinking);
      }
    }
    return out;
  }
}
