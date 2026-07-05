// App state and glue: local mode (drag&drop + IndexedDB) and shared mode
// (/s/<id> — read-only set fetched from the worker).

import { displayTitle } from "./autotitle";
import * as idb from "./idb";
import { decodeProjectDirName, parseDialog, parseSessionMeta } from "./parser";
import { renderDialog, renderOutline } from "./render";
import { matchesQuery } from "./search";
import { createShare, deleteShare, fetchManifest, fetchPart, ownerTokenFor } from "./share";
import { buildBlocks, buildTurns } from "./turns";
import type { DialogBlock, SessionEntry } from "./types";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const listNode = $("list");
const listEmpty = $("list-empty");
const dialogNode = $("dialog");
const outlineNode = $("outline");
const banner = $("banner");
const searchInput = $<HTMLInputElement>("search");
const shareStatus = $("share-status");
const btnAdd = $<HTMLButtonElement>("btn-add");
const btnShare = $<HTMLButtonElement>("btn-share");
const fileInput = $<HTMLInputElement>("file-input");
const dropzone = $("dropzone");

const sharedMatch = location.pathname.match(/^\/s\/([1-9A-HJ-NP-Za-km-z]{10,40})$/);
const sharedId = sharedMatch?.[1] ?? null;

let entries: SessionEntry[] = [];
let selectedId: string | null = null;
let checked = new Set<string>();
const blockCache = new Map<string, DialogBlock[]>();

function sortEntries() {
  entries.sort((a, b) => b.meta.mtime - a.meta.mtime);
}

function fmtDate(ms: number): string {
  return new Date(ms).toLocaleString(undefined, {
    year: "2-digit", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  });
}

function fmtSize(bytes: number): string {
  if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(1)} MB`;
  if (bytes >= 1e3) return `${Math.round(bytes / 1e3)} KB`;
  return `${bytes} B`;
}

function visibleEntries(): SessionEntry[] {
  const q = searchInput.value;
  return q.trim() ? entries.filter((e) => matchesQuery(e, q)) : entries;
}

function renderList() {
  const visible = visibleEntries();
  listEmpty.hidden = entries.length > 0;
  listNode.replaceChildren();
  for (const entry of visible) {
    const row = document.createElement("div");
    row.className = "session-row" + (entry.meta.id === selectedId ? " selected" : "");

    if (!entry.readOnly) {
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = checked.has(entry.meta.id);
      cb.addEventListener("click", (e) => e.stopPropagation());
      cb.addEventListener("change", () => {
        if (cb.checked) checked.add(entry.meta.id);
        else checked.delete(entry.meta.id);
        updateShareButton();
      });
      row.append(cb);
    }

    const main = document.createElement("div");
    main.className = "session-main";
    const title = document.createElement("div");
    title.className = "session-title";
    title.textContent = displayTitle(entry.meta);
    const sub = document.createElement("div");
    sub.className = "session-sub";
    sub.textContent = [
      entry.meta.projectLabel,
      fmtDate(entry.meta.mtime),
      `${entry.meta.userTurnCount}✎ ${entry.meta.messageCount}✉`,
      fmtSize(entry.meta.byteSize),
    ].filter(Boolean).join(" · ");
    const preview = document.createElement("div");
    preview.className = "session-preview";
    preview.textContent = entry.meta.lastUserText.slice(0, 160);
    main.append(title, sub, preview);
    row.append(main);

    if (!entry.readOnly) {
      const del = document.createElement("button");
      del.textContent = "✕";
      del.title = "Remove from browser";
      del.addEventListener("click", async (e) => {
        e.stopPropagation();
        await idb.deleteSession(entry.meta.id);
        entries = entries.filter((x) => x.meta.id !== entry.meta.id);
        checked.delete(entry.meta.id);
        blockCache.delete(entry.meta.id);
        if (selectedId === entry.meta.id) selectedId = null;
        refresh();
      });
      row.append(del);
    }

    row.addEventListener("click", () => select(entry.meta.id));
    listNode.append(row);
  }
}

function updateShareButton() {
  btnShare.disabled = checked.size === 0 || sharedId !== null;
  btnShare.textContent = checked.size ? `Share selected (${checked.size})` : "Share selected";
}

function blocksFor(entry: SessionEntry): DialogBlock[] {
  let blocks = blockCache.get(entry.meta.id);
  if (!blocks) {
    blocks = buildBlocks(buildTurns(parseDialog(entry.text)));
    blockCache.set(entry.meta.id, blocks);
  }
  return blocks;
}

function select(id: string) {
  selectedId = id;
  const entry = entries.find((e) => e.meta.id === id) ?? null;
  const blocks = entry ? blocksFor(entry) : [];
  renderDialog(dialogNode, entry, blocks);
  renderOutline(outlineNode, blocks);
  renderList();
  dialogNode.parentElement!.scrollTop = 0;
  document.body.classList.add("view-dialog");
}

// ---- mobile navigation: back to list, prompt jumps, outline sheet ----

function setupMobileNav() {
  $("btn-back").addEventListener("click", () => {
    document.body.classList.remove("view-dialog", "outline-open");
    renderList();
  });
  $("nav-outline").addEventListener("click", () => {
    document.body.classList.toggle("outline-open");
  });
  const jump = (dir: 1 | -1) => {
    const blocks = [...dialogNode.querySelectorAll<HTMLElement>(".block")]
      .filter((b) => b.querySelector(".turn-user"));
    if (!blocks.length) return;
    const tops = blocks.map((b) => b.getBoundingClientRect().top);
    const headerBottom = 60;
    const target = dir === 1
      ? blocks.find((_, i) => tops[i] > headerBottom + 20)
      : [...blocks].reverse().find((_, i) => tops[blocks.length - 1 - i] < headerBottom - 20);
    target?.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  $("nav-up").addEventListener("click", () => jump(-1));
  $("nav-down").addEventListener("click", () => jump(1));
}

function refresh() {
  sortEntries();
  renderList();
  updateShareButton();
  if (selectedId && !entries.some((e) => e.meta.id === selectedId)) {
    selectedId = null;
    renderDialog(dialogNode, null, []);
    renderOutline(outlineNode, []);
    document.body.classList.remove("view-dialog", "outline-open");
  }
}

// ---- local mode: file ingest ----

async function addFile(name: string, text: string, projectDir: string) {
  const hint = projectDir ? decodeProjectDirName(projectDir) : undefined;
  const meta = parseSessionMeta(text, name, hint);
  if (!meta) return 0;
  await idb.saveSession({ id: meta.id, fileName: name, projectDir, text, addedAt: Date.now() });
  entries = entries.filter((e) => e.meta.id !== meta.id);
  blockCache.delete(meta.id);
  entries.push({ meta, text, readOnly: false });
  return 1;
}

async function ingestFiles(files: { file: File; dir: string }[]) {
  let added = 0;
  const jsonl = files.filter((f) => f.file.name.endsWith(".jsonl"));
  shareStatus.textContent = jsonl.length ? `Parsing 0/${jsonl.length}…` : "No .jsonl files found";
  for (let i = 0; i < jsonl.length; i++) {
    try {
      added += await addFile(jsonl[i].file.name, await jsonl[i].file.text(), jsonl[i].dir);
    } catch (err) {
      console.warn("failed to add", jsonl[i].file.name, err);
    }
    shareStatus.textContent = `Parsing ${i + 1}/${jsonl.length}…`;
  }
  shareStatus.textContent = jsonl.length
    ? `Added ${added} session${added === 1 ? "" : "s"}`
    : "No .jsonl files found";
  refresh();
}

/** Recursively collect files from a drop (walks directories, e.g. projects/). */
async function collectDropped(items: DataTransferItemList): Promise<{ file: File; dir: string }[]> {
  const out: { file: File; dir: string }[] = [];
  const walk = async (entry: FileSystemEntry, parentDir: string): Promise<void> => {
    if (entry.isFile) {
      const file = await new Promise<File>((res, rej) =>
        (entry as FileSystemFileEntry).file(res, rej));
      out.push({ file, dir: parentDir });
    } else if (entry.isDirectory) {
      const reader = (entry as FileSystemDirectoryEntry).createReader();
      for (;;) {
        const batch = await new Promise<FileSystemEntry[]>((res, rej) =>
          reader.readEntries(res, rej));
        if (!batch.length) break;
        for (const child of batch) await walk(child, entry.name);
      }
    }
  };
  const roots = [...items]
    .map((i) => (i.kind === "file" ? i.webkitGetAsEntry() : null))
    .filter((e): e is FileSystemEntry => e !== null);
  for (const root of roots) await walk(root, "");
  return out;
}

function setupIngestUI() {
  btnAdd.addEventListener("click", () => fileInput.click());
  fileInput.addEventListener("change", () => {
    if (fileInput.files) {
      void ingestFiles([...fileInput.files].map((file) => ({ file, dir: "" })));
      fileInput.value = "";
    }
  });

  let dragDepth = 0;
  document.addEventListener("dragenter", (e) => {
    if (!e.dataTransfer?.types.includes("Files")) return;
    dragDepth += 1;
    dropzone.hidden = false;
  });
  document.addEventListener("dragleave", () => {
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) dropzone.hidden = true;
  });
  document.addEventListener("dragover", (e) => e.preventDefault());
  document.addEventListener("drop", async (e) => {
    e.preventDefault();
    dragDepth = 0;
    dropzone.hidden = true;
    if (!e.dataTransfer) return;
    const files = await collectDropped(e.dataTransfer.items);
    void ingestFiles(files);
  });
}

// ---- share flow ----

function showShareDialog(url: string) {
  document.getElementById("share-dialog")?.remove();
  const dlg = document.createElement("dialog");
  dlg.id = "share-dialog";
  dlg.innerHTML = `
    <h3 style="margin-top:0">Share link</h3>
    <p style="color:var(--muted);font-size:12.5px">Anyone with the link can view
    these sessions. Expires in 30 days.</p>
    <input id="share-link" readonly>
    <div style="display:flex;gap:8px;justify-content:flex-end">
      <button id="share-copy" class="primary">Copy link</button>
      <button id="share-close">Close</button>
    </div>`;
  document.body.append(dlg);
  const input = dlg.querySelector<HTMLInputElement>("#share-link")!;
  input.value = url;
  dlg.querySelector("#share-copy")!.addEventListener("click", async () => {
    await navigator.clipboard.writeText(url);
    dlg.querySelector("#share-copy")!.textContent = "Copied!";
  });
  dlg.querySelector("#share-close")!.addEventListener("click", () => dlg.close());
  dlg.showModal();
  input.select();
}

function setupShare() {
  btnShare.addEventListener("click", async () => {
    const selected = entries.filter((e) => checked.has(e.meta.id));
    if (!selected.length) return;
    btnShare.disabled = true;
    try {
      const id = await createShare(selected, (done, total) => {
        shareStatus.textContent = `Uploading ${done}/${total}…`;
      });
      shareStatus.textContent = "";
      showShareDialog(`${location.origin}/s/${id}`);
    } catch (err) {
      shareStatus.textContent = `Share failed: ${err instanceof Error ? err.message : err}`;
    } finally {
      btnShare.disabled = false;
      updateShareButton();
    }
  });
}

// ---- boot ----

async function bootLocal() {
  setupIngestUI();
  setupShare();
  const stored = await idb.loadAllSessions();
  for (const s of stored) {
    const hint = s.projectDir ? decodeProjectDirName(s.projectDir) : undefined;
    const meta = parseSessionMeta(s.text, s.fileName, hint);
    if (meta) entries.push({ meta, text: s.text, readOnly: false });
  }
  refresh();
  renderDialog(dialogNode, null, []);
}

async function bootShared(id: string) {
  btnAdd.hidden = true;
  btnShare.hidden = true;
  banner.hidden = false;
  banner.textContent = "Loading shared sessions…";
  try {
    const manifest = await fetchManifest(id);
    if (!manifest.complete) throw new Error("share upload was not completed");
    let done = 0;
    const texts = await Promise.all(
      manifest.sessions.map(async (s, n) => {
        const text = await fetchPart(id, n);
        done += 1;
        banner.textContent = `Loading shared sessions… ${done}/${manifest.sessions.length}`;
        return { s, text };
      }),
    );
    for (const { s, text } of texts) {
      const meta = parseSessionMeta(text, s.name, s.project || undefined);
      if (meta) entries.push({ meta, text, readOnly: true });
    }
    banner.replaceChildren();
    banner.append(
      `Shared set · ${entries.length} session${entries.length === 1 ? "" : "s"} · created ${fmtDate(manifest.createdAt)}`,
    );
    const home = document.createElement("a");
    home.href = "/";
    home.textContent = "Open your own sessions";
    banner.append(home);
    if (ownerTokenFor(id)) {
      const del = document.createElement("button");
      del.textContent = "Delete share";
      del.addEventListener("click", async () => {
        if (!confirm("Delete this share for everyone?")) return;
        await deleteShare(id);
        location.href = "/";
      });
      banner.append(del);
    }
    refresh();
    if (entries.length) select(entries[0].meta.id);
  } catch (err) {
    banner.textContent = `Failed to load share: ${err instanceof Error ? err.message : err}`;
  }
}

searchInput.addEventListener("input", () => renderList());
setupMobileNav();

if (sharedId) void bootShared(sharedId);
else void bootLocal();
