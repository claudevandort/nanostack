// Plan board — renders plan.json from build.py into a card view.
// Annotations are layered on top via plan.overlay.json, which the
// dev server (`tools/atlas/serve.py`) accepts PUTs to. The plan .md
// is canonical; the overlay is the user's reactions on top.

let PLAN = null;
let OVERLAY = { annotations: {} };
const FLAGS = [
  { id: "none", label: "—", color: "var(--st-unknown)" },
  { id: "agreed", label: "✓ agreed", color: "var(--st-enforced)" },
  { id: "question", label: "? question", color: "var(--st-roundtrip)" },
  { id: "blocked", label: "! blocked", color: "var(--st-not_supported)" },
  { id: "out", label: "🚫 out", color: "var(--st-partial)" },
];

async function init() {
  initTheme();
  document.getElementById("theme-toggle").addEventListener("click", toggleTheme);

  try {
    const resp = await fetch("./plan.json");
    PLAN = await resp.json();
  } catch (err) {
    renderError(err);
    return;
  }

  // Overlay is optional; 404 / parse-error → start with an empty one.
  try {
    const resp = await fetch("./plan.overlay.json");
    if (resp.ok) {
      const j = await resp.json();
      if (j && typeof j === "object" && j.annotations) {
        OVERLAY = j;
      }
    }
  } catch {
    // ignore
  }

  if (!PLAN || PLAN.present === false) {
    renderEmpty();
    return;
  }
  renderHero();
  renderSections();
  attachGlobalKeys();
}

// ---------------------------------------------------------------- THEME

function initTheme() {
  const stored = localStorage.getItem("atlas-theme");
  if (stored) document.documentElement.dataset.theme = stored;
  else if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
    document.documentElement.dataset.theme = "dark";
  }
}
function toggleTheme() {
  const cur = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = cur;
  localStorage.setItem("atlas-theme", cur);
}

// ---------------------------------------------------------------- HERO

function renderHero() {
  const root = document.getElementById("plan-hero");
  root.replaceChildren();

  const h1 = document.createElement("div");
  h1.className = "plan-title";
  h1.textContent = stripMd(PLAN.title);
  root.appendChild(h1);

  const meta = document.createElement("div");
  meta.className = "plan-meta";
  const slugEl = document.createElement("span");
  slugEl.className = "plan-slug mono";
  slugEl.textContent = PLAN.slug + ".md";
  const mtimeEl = document.createElement("span");
  mtimeEl.className = "plan-mtime mono";
  mtimeEl.textContent = "modified " + formatMtime(PLAN.mtime);
  meta.append(slugEl, document.createTextNode(" · "), mtimeEl);
  root.appendChild(meta);
}

function formatMtime(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd} ${hh}:${mi}`;
}

// ---------------------------------------------------------------- SECTIONS

function renderSections() {
  const root = document.getElementById("plan-root");
  root.replaceChildren();
  PLAN.sections.forEach((s) => {
    const el = renderSection(s);
    if (el) root.appendChild(el);
  });
}

function renderSection(s) {
  switch (s.type) {
    case "context":
      return proseCard(s.title, s.body);
    case "decisions":
      return decisionsCard(s);
    case "scope":
      return scopeCard(s);
    case "files":
      return filesCard(s);
    case "boundaries":
      return boundariesCard(s);
    case "freeform":
    default:
      return proseCard(s.title, s.body, "freeform");
  }
}

function proseCard(title, body, extraClass = "") {
  const sec = section(title, extraClass);
  sec.appendChild(renderBlocks(body));
  decorateCard(sec, cardId(extraClass || "prose", 0, title + body));
  return sec;
}

function decisionsCard(s) {
  const sec = section(s.title, "decisions");
  const list = document.createElement("ol");
  list.className = "decision-list";
  (s.items || []).forEach((text, i) => {
    const li = document.createElement("li");
    li.className = "decision-card";
    li.appendChild(renderBlocks(text));
    decorateCard(li, cardId("decision", i, text));
    list.appendChild(li);
  });
  sec.appendChild(list);
  return sec;
}

function scopeCard(s) {
  const sec = section(s.title, "scope");
  const rail = document.createElement("div");
  rail.className = "phase-rail";
  (s.phases || []).forEach((p, i) => {
    const card = document.createElement("article");
    card.className = "phase-card";
    const h = document.createElement("h3");
    h.textContent = p.title;
    card.appendChild(h);
    card.appendChild(renderBlocks(p.body));
    decorateCard(card, cardId("phase", i, p.title + p.body));
    rail.appendChild(card);
  });
  sec.appendChild(rail);
  return sec;
}

function filesCard(s) {
  const sec = section(s.title, "files");
  const split = document.createElement("div");
  split.className = "files-split";
  split.appendChild(filesColumn("Modified", s.modified || []));
  split.appendChild(filesColumn("New", s.new || []));
  sec.appendChild(split);
  return sec;
}

function filesColumn(heading, items) {
  const col = document.createElement("div");
  col.className = "files-col";
  const h = document.createElement("h4");
  h.textContent = heading;
  col.appendChild(h);
  if (!items.length) {
    const p = document.createElement("p");
    p.className = "muted";
    p.textContent = "—";
    col.appendChild(p);
    return col;
  }
  const ul = document.createElement("ul");
  ul.className = "files-list";
  items.forEach((it) => {
    const li = document.createElement("li");
    li.innerHTML = mdInline(it);
    ul.appendChild(li);
  });
  col.appendChild(ul);
  return col;
}

function boundariesCard(s) {
  const sec = section(s.title, "boundaries");
  const grid = document.createElement("div");
  grid.className = "boundaries-grid";
  (s.items || []).forEach((text, i) => {
    const card = document.createElement("div");
    card.className = "boundary-card";
    card.appendChild(renderBlocks(text));
    decorateCard(card, cardId("boundary", i, text));
    grid.appendChild(card);
  });
  sec.appendChild(grid);
  return sec;
}

function section(title, extra = "") {
  const sec = document.createElement("section");
  sec.className = "plan-section" + (extra ? " plan-section-" + extra : "");
  const h = document.createElement("h2");
  h.textContent = title;
  sec.appendChild(h);
  return sec;
}

// ---------------------------------------------------------------- EMPTY / ERROR

function renderEmpty() {
  const root = document.getElementById("plan-root");
  root.replaceChildren();
  const sec = document.createElement("section");
  sec.className = "plan-section";
  const h = document.createElement("h2");
  h.textContent = "No active plan";
  const p = document.createElement("p");
  p.textContent = "No .md files found in " + (PLAN?.source_dir || "the plans dir") + ". Run plan mode in this project to create one.";
  const cmd = document.createElement("pre");
  cmd.textContent = "python3 tools/atlas/build.py --plan-only";
  sec.append(h, p, cmd);
  root.appendChild(sec);
  document.getElementById("plan-hero").replaceChildren();
}

function renderError(err) {
  const root = document.getElementById("plan-root");
  root.innerHTML = `<pre style="padding:30px;color:#a44">Failed to load plan.json. Run <code>python3 tools/atlas/build.py --plan-only</code> first.\n${err}</pre>`;
}

// ---------------------------------------------------------------- MARKDOWN

// Render a multi-line markdown body as a sequence of <p> / <ul> / <pre> blocks.
function renderBlocks(text) {
  const frag = document.createDocumentFragment();
  if (!text) return frag;
  const lines = text.split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    // Fenced code block.
    if (line.trim().startsWith("```")) {
      const buf = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith("```")) {
        buf.push(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // consume the closing fence
      const pre = document.createElement("pre");
      pre.textContent = buf.join("\n");
      frag.appendChild(pre);
      continue;
    }
    // Bullet list.
    if (/^\s*[-*]\s+/.test(line)) {
      const ul = document.createElement("ul");
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
        const li = document.createElement("li");
        li.innerHTML = mdInline(lines[i].replace(/^\s*[-*]\s+/, ""));
        ul.appendChild(li);
        i++;
      }
      frag.appendChild(ul);
      continue;
    }
    // H3-style headings inside section body.
    if (line.startsWith("### ")) {
      const h5 = document.createElement("h5");
      h5.textContent = line.replace(/^###\s+/, "");
      frag.appendChild(h5);
      i++;
      continue;
    }
    // Blank — paragraph separator.
    if (!line.trim()) {
      i++;
      continue;
    }
    // Paragraph: gather until blank line or block-level marker.
    const buf = [line];
    i++;
    while (i < lines.length && lines[i].trim() &&
           !/^\s*[-*]\s+/.test(lines[i]) &&
           !lines[i].startsWith("### ") &&
           !lines[i].trim().startsWith("```")) {
      buf.push(lines[i]);
      i++;
    }
    const p = document.createElement("p");
    p.innerHTML = mdInline(buf.join(" "));
    frag.appendChild(p);
  }
  return frag;
}

// Inline markdown: **bold**, `code`, [text](url). Returns HTML.
function mdInline(text) {
  if (!text) return "";
  // Escape HTML first.
  let html = text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
  // Code spans (run BEFORE bold so backticks aren't confused with stray **).
  html = html.replace(/`([^`]+)`/g, "<code>$1</code>");
  // Bold.
  html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  // Links.
  html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  return html;
}

function stripMd(text) {
  if (!text) return "";
  return text.replace(/\*\*([^*]+)\*\*/g, "$1").replace(/`([^`]+)`/g, "$1");
}

// ---------------------------------------------------------------- ANNOTATIONS

// Deterministic 4-hex-char hash of the card's content. Stable across
// --plan-only rebuilds when the content doesn't change.
function shortHash(s) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return ("0000" + h.toString(16)).slice(-4);
}

function cardId(kind, index, content) {
  return `${kind}-${index}-${shortHash(content || "")}`;
}

function decorateCard(el, id) {
  el.dataset.cardId = id;
  el.classList.add("annotatable");
  el.tabIndex = 0;
  const ann = OVERLAY.annotations?.[id];
  if (ann && (ann.flag !== "none" || (ann.note && ann.note.trim()))) {
    renderBadge(el, ann);
  }
  el.addEventListener("click", (ev) => {
    if (ev.target.closest(".annotation-editor")) return;
    if (ev.target.closest(".annotation-badge")) {
      // Let click on badge open the editor too — same handler.
    }
    if (el.querySelector(":scope > .annotation-editor")) return;
    openEditor(el, id);
  });
  el.addEventListener("keydown", (ev) => {
    if (ev.key === "e" && !el.querySelector(":scope > .annotation-editor")) {
      ev.preventDefault();
      openEditor(el, id);
    }
  });
}

function renderBadge(el, ann) {
  // Replace any existing badge.
  el.querySelectorAll(":scope > .annotation-badge").forEach((b) => b.remove());
  if (!ann || (ann.flag === "none" && !ann.note?.trim())) return;
  const badge = document.createElement("div");
  badge.className = "annotation-badge";
  badge.dataset.flag = ann.flag;
  const f = FLAGS.find((x) => x.id === ann.flag) ?? FLAGS[0];
  const dot = document.createElement("span");
  dot.className = "annotation-badge-dot";
  dot.style.background = f.color;
  badge.append(dot);
  if (ann.note && ann.note.trim()) {
    const note = document.createElement("span");
    note.className = "annotation-badge-note";
    note.textContent = ann.note;
    badge.append(note);
  } else {
    badge.append(document.createTextNode(f.label));
  }
  el.appendChild(badge);
}

function openEditor(card, id) {
  closeAllEditors();
  const ann = OVERLAY.annotations?.[id] ?? { flag: "none", note: "" };

  const editor = document.createElement("div");
  editor.className = "annotation-editor";
  editor.dataset.cardId = id;

  const pillRow = document.createElement("div");
  pillRow.className = "flag-pill-row";
  FLAGS.forEach((f) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "flag-pill";
    btn.dataset.flag = f.id;
    btn.textContent = f.label;
    btn.style.setProperty("--pill-color", f.color);
    if (f.id === ann.flag) btn.classList.add("active");
    btn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      pillRow.querySelectorAll(".flag-pill").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
    });
    pillRow.append(btn);
  });

  const ta = document.createElement("textarea");
  ta.className = "annotation-textarea";
  ta.maxLength = 800;
  ta.placeholder = "Optional note. Markdown: **bold**, `code`, [link](url).";
  ta.value = ann.note || "";

  const counter = document.createElement("div");
  counter.className = "annotation-counter";
  const updateCounter = () => {
    counter.textContent = `${ta.value.length} / 800`;
  };
  updateCounter();
  ta.addEventListener("input", updateCounter);

  const actions = document.createElement("div");
  actions.className = "annotation-actions";
  const save = document.createElement("button");
  save.type = "button";
  save.className = "annotation-save";
  save.textContent = "Save";
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "annotation-cancel";
  cancel.textContent = "Cancel";

  cancel.addEventListener("click", (ev) => {
    ev.stopPropagation();
    editor.remove();
  });
  save.addEventListener("click", async (ev) => {
    ev.stopPropagation();
    const flag = pillRow.querySelector(".flag-pill.active")?.dataset.flag ?? "none";
    const note = ta.value.trim();
    save.disabled = true;
    const ok = await persistAnnotation(id, { flag, note });
    if (ok) {
      // Update in-memory OVERLAY + badge + close.
      if (flag === "none" && !note) {
        delete OVERLAY.annotations[id];
        // Wipe badge.
        card.querySelectorAll(":scope > .annotation-badge").forEach((b) => b.remove());
      } else {
        OVERLAY.annotations[id] = { flag, note, updated_at: new Date().toISOString() };
        renderBadge(card, OVERLAY.annotations[id]);
      }
      toast("saved", "ok");
      editor.remove();
    } else {
      save.disabled = false;
    }
  });

  actions.append(save, cancel);
  editor.append(pillRow, ta, counter, actions);
  card.appendChild(editor);
  setTimeout(() => ta.focus(), 0);
}

function closeAllEditors() {
  document.querySelectorAll(".annotation-editor").forEach((e) => e.remove());
}

async function persistAnnotation(id, value) {
  // Update in-memory OVERLAY copy, then PUT the full overlay.
  const next = JSON.parse(JSON.stringify(OVERLAY));
  if (!next.annotations) next.annotations = {};
  if (value.flag === "none" && !value.note) {
    delete next.annotations[id];
  } else {
    next.annotations[id] = {
      flag: value.flag,
      note: value.note,
      updated_at: new Date().toISOString(),
    };
  }
  next.plan_slug = PLAN.slug;
  next.plan_mtime = PLAN.mtime;
  try {
    const resp = await fetch("./plan.overlay.json", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(next),
    });
    if (!resp.ok) {
      const body = await resp.text();
      let msg = `HTTP ${resp.status}`;
      try {
        const j = JSON.parse(body);
        if (j.error) msg = j.error;
      } catch {}
      toast(`save failed: ${msg}`, "err");
      return false;
    }
    return true;
  } catch (err) {
    toast(`save failed: ${err.message || err}`, "err");
    return false;
  }
}

function attachGlobalKeys() {
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") closeAllEditors();
  });
  document.addEventListener("click", (ev) => {
    // Close editors when clicking outside any card.
    if (!ev.target.closest(".annotatable")) closeAllEditors();
  });
}

let _toastTimer = null;
function toast(text, kind = "ok") {
  let el = document.getElementById("atlas-toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "atlas-toast";
    el.className = "atlas-toast";
    document.body.appendChild(el);
  }
  el.textContent = text;
  el.dataset.kind = kind;
  el.classList.add("visible");
  if (_toastTimer) clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => el.classList.remove("visible"), 1500);
}

init();
