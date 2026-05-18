// Plan board — renders plan.json from build.py into a card view.
// Read-only; the source is ~/.claude/plans/<slug>.md.

let PLAN = null;

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

  if (!PLAN || PLAN.present === false) {
    renderEmpty();
    return;
  }
  renderHero();
  renderSections();
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
  return sec;
}

function decisionsCard(s) {
  const sec = section(s.title, "decisions");
  const list = document.createElement("ol");
  list.className = "decision-list";
  (s.items || []).forEach((text) => {
    const li = document.createElement("li");
    li.className = "decision-card";
    li.appendChild(renderBlocks(text));
    list.appendChild(li);
  });
  sec.appendChild(list);
  return sec;
}

function scopeCard(s) {
  const sec = section(s.title, "scope");
  const rail = document.createElement("div");
  rail.className = "phase-rail";
  (s.phases || []).forEach((p) => {
    const card = document.createElement("article");
    card.className = "phase-card";
    const h = document.createElement("h3");
    h.textContent = p.title;
    card.appendChild(h);
    card.appendChild(renderBlocks(p.body));
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
  (s.items || []).forEach((text) => {
    const card = document.createElement("div");
    card.className = "boundary-card";
    card.appendChild(renderBlocks(text));
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

init();
