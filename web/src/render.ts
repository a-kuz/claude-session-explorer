// DOM rendering of the dialog (blocks → turns → segments) and the outline.

import DOMPurify from "dompurify";
import { marked } from "marked";
import { displayTitle } from "./autotitle";
import { oneLine } from "./content";
import type { DialogBlock, SessionEntry, ToolUse } from "./types";

marked.setOptions({ gfm: true, breaks: true });

/// Display cap per prose/tool block — 1M-char walls of text would freeze
/// layout; the rest unfolds behind a "show all" button.
const MAX_RENDER_CHARS = 40_000;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function markdownInto(target: HTMLElement, text: string) {
  target.innerHTML = DOMPurify.sanitize(marked.parse(text, { async: false }));
}

/** Render text as sanitized markdown, clamped with a "show all" expander. */
function proseNode(text: string): HTMLElement {
  const node = el("div", "prose");
  if (text.length <= MAX_RENDER_CHARS) {
    markdownInto(node, text);
    return node;
  }
  markdownInto(node, text.slice(0, MAX_RENDER_CHARS));
  const more = el("button", "show-more", `Show all (${text.length.toLocaleString()} chars)`);
  more.addEventListener("click", () => {
    markdownInto(node, text);
    more.remove();
  });
  const wrap = el("div");
  wrap.append(node, more);
  return wrap;
}

function clampedPre(text: string): HTMLElement {
  const wrap = el("div");
  const pre = el("pre");
  pre.textContent = text.length > MAX_RENDER_CHARS ? text.slice(0, MAX_RENDER_CHARS) : text;
  wrap.append(pre);
  if (text.length > MAX_RENDER_CHARS) {
    const more = el("button", "show-more", `Show all (${text.length.toLocaleString()} chars)`);
    more.addEventListener("click", () => {
      pre.textContent = text;
      more.remove();
    });
    wrap.append(more);
  }
  return wrap;
}

/// Renders a tool's input field-by-field: `description` becomes a caption,
/// string fields become labeled code blocks, the rest — labeled JSON.
/// Falls back to one "Input" JSON dump when the input isn't an object.
function appendInput(body: HTMLElement, tool: ToolUse) {
  const obj = tool.inputObj;
  if (!obj) {
    if (tool.input && tool.input !== "{}") {
      body.append(el("h4", undefined, "Input"), clampedPre(tool.input));
    }
    return;
  }
  const desc = obj.description;
  if (typeof desc === "string" && desc.trim()) {
    body.append(el("div", "step-desc", desc));
  }
  for (const [key, value] of Object.entries(obj)) {
    if (key === "description") continue;
    body.append(el("h4", undefined, key));
    body.append(clampedPre(
      typeof value === "string" ? value : JSON.stringify(value, null, 2),
    ));
  }
}

/// One tool call as a step row inside a group: ✓ + name + arg; clicking the
/// row lazily unfolds Input/Result details underneath.
function stepNode(tool: ToolUse): HTMLElement {
  const step = el("div", "tool-step");
  const line = el("div", "step-line");
  line.append(el("span", "step-ic", "✓"), el("span", "step-name", tool.name));
  // A human description beats the raw argument when the tool has one.
  if (tool.label) line.append(el("span", "step-lbl", tool.label));
  else if (tool.arg) line.append(el("span", "step-arg", tool.arg));
  step.append(line);

  let body: HTMLElement | null = null;
  line.addEventListener("click", (e) => {
    e.stopPropagation();
    if (body) {
      body.hidden = !body.hidden;
      return;
    }
    body = el("div", "step-body");
    appendInput(body, tool);
    if (tool.output) {
      body.append(el("h4", undefined, "Result"), clampedPre(tool.output));
    }
    if (!body.childElementCount) body.append(el("h4", undefined, "No details"));
    step.append(body);
  });
  return step;
}

/// A run of consecutive tool calls collapsed into one group (v.be style):
/// the header lists the steps comma-separated (ellipsized) with a count;
/// clicking it unfolds the step list.
function toolGroupNode(tools: ToolUse[]): HTMLElement {
  const box = el("div", "tool-group");
  const head = el("div", "tg-head");
  const summary = tools
    .map((t) => t.label || t.name + (t.arg ? ` ${t.arg}` : ""))
    .join(", ");
  head.append(
    el("span", "tg-chev", "▸"),
    el("span", "tg-summary", summary),
    el("span", "tg-count", String(tools.length)),
  );
  head.addEventListener("click", () => box.classList.toggle("open"));
  const list = el("div", "tg-list");
  for (const t of tools) list.append(stepNode(t));
  box.append(head, list);
  return box;
}

function timeLabel(ts: number | null): string {
  if (ts === null) return "";
  return new Date(ts).toLocaleString(undefined, {
    day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit",
  });
}

function imagesNode(images: string[]): HTMLElement {
  const wrap = el("div", "msg-images");
  for (const src of images) {
    const img = el("img");
    img.src = src;
    img.loading = "lazy";
    wrap.append(img);
  }
  return wrap;
}

/// Watches the 1px sentinel above each prompt header: once the sentinel
/// scrolls out of the top of the dialog pane the header is pinned — it gets
/// `.stuck` (compact two-line form + shadow). One observer per rendered dialog.
let stuckObserver: IntersectionObserver | null = null;

function observeStickyPrompts(container: HTMLElement) {
  stuckObserver?.disconnect();
  const root = container.parentElement;
  if (!root) return;
  stuckObserver = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        const header = (e.target as HTMLElement).nextElementSibling;
        if (!header?.classList.contains("turn-user")) continue;
        const stuck = !e.isIntersecting
          && e.boundingClientRect.top < (e.rootBounds?.top ?? 0);
        header.classList.toggle("stuck", stuck);
      }
    },
    { root, threshold: 0 },
  );
  for (const s of container.querySelectorAll(".prompt-sentinel")) {
    stuckObserver.observe(s);
  }
}

export function renderDialog(
  container: HTMLElement,
  entry: SessionEntry | null,
  blocks: DialogBlock[],
) {
  stuckObserver?.disconnect();
  container.replaceChildren();
  if (!entry) {
    const placeholder = el("div", undefined, "Select a session on the left");
    placeholder.id = "dialog-placeholder";
    container.append(placeholder);
    return;
  }

  const header = el("div");
  header.id = "dialog-header";
  const h1 = el("h1", undefined, displayTitle(entry.meta));
  const metaBits = [
    entry.meta.projectPath || entry.meta.projectLabel,
    `${entry.meta.messageCount} messages · ${entry.meta.userTurnCount} prompts`,
    entry.meta.model ?? "",
    entry.meta.id,
  ].filter(Boolean);
  header.append(h1, el("div", "meta", metaBits.join("  ·  ")));
  container.append(header);

  for (const block of blocks) {
    const blockNode = el("div", "block");
    blockNode.dataset.blockId = block.id;
    for (const turn of block.turns) {
      if (turn.isUserPrompt) {
        const node = el("div", "turn-user");
        node.append(el("span", "turn-time", timeLabel(turn.timestamp)));
        const text = el("div", "prompt-text", turn.bodyChunks.join("\n\n"));
        node.append(text);
        if (turn.images.length) node.append(imagesNode(turn.images));
        // A pinned (stuck) header acts as "back to this prompt": click scrolls
        // the block to its natural position. Text selection clicks pass through.
        node.addEventListener("click", () => {
          if (!node.classList.contains("stuck")) return;
          if (window.getSelection()?.toString()) return;
          blockNode.scrollIntoView({ behavior: "smooth", block: "start" });
        });
        blockNode.append(el("div", "prompt-sentinel"), node);
      } else {
        const node = el("div", "turn-assistant");
        // Consecutive tool segments render as one collapsed group.
        let run: ToolUse[] = [];
        const flushRun = () => {
          if (run.length) node.append(toolGroupNode(run));
          run = [];
        };
        for (const seg of turn.segments) {
          if (seg.kind === "tool") {
            run.push(seg.tool);
          } else {
            flushRun();
            node.append(proseNode(seg.text));
          }
        }
        flushRun();
        if (turn.images.length) node.append(imagesNode(turn.images));
        const t = timeLabel(turn.timestamp);
        if (t) node.append(el("div", "turn-time", t));
        blockNode.append(node);
      }
    }
    container.append(blockNode);
  }
  observeStickyPrompts(container);
}

export function renderOutline(container: HTMLElement, blocks: DialogBlock[]) {
  container.replaceChildren();
  const prompts = blocks.filter((b) => b.hasPrompt);
  if (!prompts.length) return;
  container.append(el("div", "outline-title", `Prompts · ${prompts.length}`));
  for (const block of prompts) {
    const label = oneLine(block.turns[0].bodyChunks[0] ?? "", 80) || "…";
    const item = el("button", "outline-item", label);
    item.addEventListener("click", () => {
      document.body.classList.remove("outline-open");
      document
        .querySelector(`[data-block-id="${CSS.escape(block.id)}"]`)
        ?.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    container.append(item);
  }
}
