// Search over loaded sessions: AND across words, /pattern/ switches to regex.
// The uploaded set is small (vs the app's full ~/.claude scan), so a single
// synchronous pass over titles + raw jsonl text is fast enough.

import { displayTitle } from "./autotitle";
import type { SessionEntry } from "./types";

export function matchesQuery(entry: SessionEntry, query: string): boolean {
  const q = query.trim();
  if (!q) return true;
  const haystackMeta = `${displayTitle(entry.meta)}\n${entry.meta.projectLabel}\n${entry.meta.projectPath}\n${entry.meta.lastUserText}`.toLowerCase();

  const regexForm = q.match(/^\/(.+)\/$/);
  if (regexForm) {
    let re: RegExp;
    try {
      re = new RegExp(regexForm[1], "i");
    } catch {
      return false;
    }
    return re.test(haystackMeta) || re.test(entry.text);
  }

  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  const deep = entry.text.toLowerCase();
  return words.every((w) => haystackMeta.includes(w) || deep.includes(w));
}
