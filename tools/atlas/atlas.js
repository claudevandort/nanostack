// Atlas — renders data.json into a static read-only project view.

const STATUS_ORDER = ["enforced", "supported", "roundtrip", "partial", "not_supported", "unknown"];
const STATUS_LABEL = {
  enforced: "enforced",
  supported: "supported",
  roundtrip: "accept-store-roundtrip",
  partial: "partial",
  not_supported: "not supported",
  unknown: "uncategorised",
};

let DATA = null;
let activeFilter = null;
let tooltipEl = null;

// ---------------------------------------------------------------- INIT

async function init() {
  initTheme();
  document.getElementById("theme-toggle").addEventListener("click", toggleTheme);
  document.getElementById("side-close").addEventListener("click", closeSidePanel);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeSidePanel(); });

  try {
    const resp = await fetch("./data.json");
    DATA = await resp.json();
  } catch (err) {
    document.body.innerHTML = `<pre style="padding:30px;color:#a44">Failed to load data.json. Run <code>python3 tools/atlas/build.py</code> first.\n${err}</pre>`;
    return;
  }

  renderHero();
  renderTiles();
  renderLegend();
  renderMatrix();
  renderWiring();
  renderTimeline();
  renderBench();
  attachTooltip();
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
  document.getElementById("version-pill").textContent = `v${DATA.version}`;
  // The tagline comes from CLAUDE.md prose; strip leftover **bold** / `code` markers.
  const cleaned = (DATA.tagline || "")
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/`([^`]+)`/g, "$1");
  document.getElementById("hero-tagline").textContent = cleaned;
}

function renderTiles() {
  const tiles = [];
  // Services count.
  tiles.push(tile("Services", `${DATA.services.length}`, "live on the same port"));

  // Total enforced ops across all services.
  const totalOps = DATA.services.reduce((n, s) => n + s.ops.length, 0);
  tiles.push(tile("Total ops", `${totalOps}`, "across all services"));

  // S3 Smithy coverage.
  if (DATA.coverage?.s3) {
    const [c, t] = DATA.coverage.s3;
    tiles.push(tile("S3 Smithy", `${c} / ${t}`, `${((c / t) * 100).toFixed(1)}% covered`));
  }

  // Tests.
  if (DATA.tests) {
    if (DATA.tests.python) tiles.push(tile("Python tests", DATA.tests.python, "boto3 conformance"));
    if (DATA.tests.js) tiles.push(tile("JS tests", DATA.tests.js, "aws-sdk-js v3"));
    if (DATA.tests.awscli) tiles.push(tile("AWS CLI tests", DATA.tests.awscli, "v2 CLI"));
  }

  document.getElementById("headline-tiles").replaceChildren(...tiles);
}

function tile(label, value, sub) {
  const el = document.createElement("div");
  el.className = "tile";
  el.innerHTML = `<div class="tile-label"></div><div class="tile-value"></div><div class="tile-sub"></div>`;
  el.children[0].textContent = label;
  el.children[1].textContent = value;
  el.children[2].textContent = sub;
  return el;
}

// ---------------------------------------------------------------- LEGEND

function renderLegend() {
  const present = new Set();
  DATA.services.forEach((s) => s.ops.forEach((o) => present.add(o.status)));
  const order = STATUS_ORDER.filter((s) => present.has(s));

  const legend = document.getElementById("status-legend");
  legend.replaceChildren();
  order.forEach((status) => {
    const chip = document.createElement("button");
    chip.className = "legend-chip";
    chip.dataset.status = status;
    const sw = document.createElement("span");
    sw.className = "legend-swatch";
    sw.style.background = `var(--st-${status})`;
    chip.appendChild(sw);
    const lbl = document.createElement("span");
    lbl.textContent = STATUS_LABEL[status] || status;
    chip.appendChild(lbl);
    chip.addEventListener("click", () => toggleFilter(status));
    legend.appendChild(chip);
  });
  // "Clear" chip.
  const clear = document.createElement("button");
  clear.className = "legend-chip";
  clear.textContent = "show all";
  clear.addEventListener("click", () => toggleFilter(null));
  legend.appendChild(clear);
}

function toggleFilter(status) {
  activeFilter = activeFilter === status ? null : status;
  document.querySelectorAll(".legend-chip").forEach((c) => {
    c.classList.toggle("active", c.dataset.status === activeFilter);
  });
  applyFilter();
}

function applyFilter() {
  const matrix = document.getElementById("matrix");
  if (!activeFilter) {
    matrix.classList.remove("filtered");
    return;
  }
  matrix.classList.add("filtered");
  matrix.querySelectorAll(".op").forEach((op) => {
    op.classList.toggle("match", op.dataset.status === activeFilter);
  });
}

// ---------------------------------------------------------------- MATRIX

function renderMatrix() {
  const matrix = document.getElementById("matrix");
  matrix.replaceChildren();
  DATA.services.forEach((svc) => {
    const col = document.createElement("div");
    col.className = "service-col";

    const head = document.createElement("div");
    head.className = "service-head";
    const name = document.createElement("div");
    name.className = "service-name";
    name.textContent = svc.name;
    const meta = document.createElement("div");
    meta.className = "service-meta";
    meta.textContent = `${svc.ops.length} ops · ${svc.divergences.length} notes`;
    head.append(name, meta);
    col.append(head);

    const list = document.createElement("div");
    list.className = "op-list";
    svc.ops.forEach((op) => {
      const row = document.createElement("div");
      row.className = "op";
      row.dataset.status = op.status;
      row.dataset.tooltip = `**${op.name}** — ${op.status_text}\n${op.milestone}`;
      const n = document.createElement("span");
      n.className = "op-name";
      n.textContent = op.name;
      const m = document.createElement("span");
      m.className = "op-milestone";
      m.textContent = op.milestone;
      row.append(n, m);
      row.addEventListener("click", () => showOpDetail(svc, op));
      list.append(row);
    });
    col.append(list);

    // Optional: clickable header that opens the divergence list.
    head.style.cursor = "pointer";
    head.addEventListener("click", () => showServiceDetail(svc));

    matrix.append(col);
  });
}

function showServiceDetail(svc) {
  const c = document.getElementById("side-content");
  c.replaceChildren();
  const h = document.createElement("h3");
  h.textContent = `${svc.name} divergences`;
  c.appendChild(h);
  const p = document.createElement("p");
  p.textContent = `${svc.ops.length} routed ops; ${svc.divergences.length} documented divergences.`;
  c.appendChild(p);
  const ul = document.createElement("ul");
  svc.divergences.forEach((d) => {
    const li = document.createElement("li");
    const s = document.createElement("strong");
    s.textContent = d.title + ". ";
    li.appendChild(s);
    li.append(document.createTextNode(d.body));
    ul.appendChild(li);
  });
  c.appendChild(ul);
  openSidePanel();
}

function showOpDetail(svc, op) {
  const c = document.getElementById("side-content");
  c.replaceChildren();
  const h = document.createElement("h3");
  h.textContent = `${svc.name}.${op.name}`;
  c.appendChild(h);
  const row = document.createElement("div");
  row.className = "side-status-row";
  const sw = document.createElement("span");
  sw.className = "legend-swatch";
  sw.style.background = `var(--st-${op.status})`;
  row.append(sw, document.createTextNode(STATUS_LABEL[op.status] || op.status));
  c.appendChild(row);
  const h4 = document.createElement("h4");
  h4.textContent = "Status (verbatim)";
  c.appendChild(h4);
  const p = document.createElement("p");
  p.textContent = op.status_text;
  c.appendChild(p);
  const m4 = document.createElement("h4");
  m4.textContent = "Milestone";
  c.appendChild(m4);
  const mp = document.createElement("p");
  mp.className = "mono";
  mp.textContent = op.milestone;
  c.appendChild(mp);
  openSidePanel();
}

// ---------------------------------------------------------------- WIRING

function renderWiring() {
  const SERVICES = ["S3", "DDB", "SQS", "SNS", "λ"];
  const POS = {
    S3: { x: 110, y: 60 },
    DDB: { x: 110, y: 250 },
    SQS: { x: 480, y: 60 },
    SNS: { x: 295, y: 155 },
    "λ": { x: 480, y: 250 },
  };
  const BOX_W = 90;
  const BOX_H = 50;

  // Map the SUPPORT.md flow string → (from, to).
  function parseFlow(flow) {
    // Examples: "S3 → SQS event notifications", "SNS → SQS fan-out",
    // "S3 → SNS → SQS multi-hop", "S3 → Lambda notifications", "DynamoDB Streams → SQS"
    const ARROW = "→";
    const parts = flow.split(ARROW).map((s) => s.trim());
    if (parts.length < 2) return null;
    const norm = (s) => {
      if (/^S3\b/i.test(s)) return "S3";
      if (/^DynamoDB|^DDB/i.test(s)) return "DDB";
      if (/^SQS\b/i.test(s)) return "SQS";
      if (/^SNS\b/i.test(s)) return "SNS";
      if (/^Lambda\b/i.test(s)) return "λ";
      return null;
    };
    const from = norm(parts[0]);
    const to = norm(parts[parts.length - 1]);
    if (!from || !to) return null;
    return { from, to, hops: parts.length };
  }

  const container = document.getElementById("wiring");
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 600 320");
  svg.setAttribute("preserveAspectRatio", "xMidYMid meet");

  // Arrowhead markers (one per status).
  const defs = document.createElementNS("http://www.w3.org/2000/svg", "defs");
  ["supported", "not_supported", "enforced"].forEach((status) => {
    const marker = document.createElementNS("http://www.w3.org/2000/svg", "marker");
    marker.setAttribute("id", `arrow-${status}`);
    marker.setAttribute("viewBox", "0 0 10 10");
    marker.setAttribute("refX", "9");
    marker.setAttribute("refY", "5");
    marker.setAttribute("markerWidth", "6");
    marker.setAttribute("markerHeight", "6");
    marker.setAttribute("orient", "auto");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", "M 0 0 L 10 5 L 0 10 z");
    path.setAttribute("class", "wiring-arrowhead " + status);
    path.setAttribute("fill", `var(--st-${status})`);
    marker.appendChild(path);
    defs.appendChild(marker);
  });
  svg.appendChild(defs);

  // Flows first so boxes draw on top.
  (DATA.cross_service?.flows || []).forEach((flow, i) => {
    const parsed = parseFlow(flow.flow);
    if (!parsed) return;
    const { from, to } = parsed;
    const a = POS[from];
    const b = POS[to];
    if (!a || !b) return;

    const x1 = a.x + BOX_W / 2;
    const y1 = a.y + BOX_H / 2;
    const x2 = b.x + BOX_W / 2;
    const y2 = b.y + BOX_H / 2;
    // Curved path for visual distinction between flows on the same axis.
    const mx = (x1 + x2) / 2;
    const my = (y1 + y2) / 2 + (i % 2 === 0 ? -16 : 16);

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", `M ${x1} ${y1} Q ${mx} ${my} ${x2} ${y2}`);
    path.setAttribute("class", `wiring-flow ${flow.status}`);
    path.setAttribute("marker-end", `url(#arrow-${flow.status === "not_supported" ? "not_supported" : "supported"})`);
    path.style.stroke = flow.status === "not_supported" ? "var(--st-not_supported)" : "var(--st-supported)";
    path.dataset.flow = flow.flow;
    path.addEventListener("click", () => {
      document.querySelectorAll(".wiring-flow.selected").forEach((p) => p.classList.remove("selected"));
      path.classList.add("selected");
      showFlowDetail(flow);
    });
    svg.appendChild(path);
  });

  // Boxes.
  SERVICES.forEach((name) => {
    const p = POS[name];
    const g = document.createElementNS("http://www.w3.org/2000/svg", "g");
    g.setAttribute("class", "wiring-box");
    const r = document.createElementNS("http://www.w3.org/2000/svg", "rect");
    r.setAttribute("x", p.x);
    r.setAttribute("y", p.y);
    r.setAttribute("width", BOX_W);
    r.setAttribute("height", BOX_H);
    r.setAttribute("rx", "8");
    g.appendChild(r);
    const t = document.createElementNS("http://www.w3.org/2000/svg", "text");
    t.setAttribute("x", p.x + BOX_W / 2);
    t.setAttribute("y", p.y + BOX_H / 2 + 5);
    t.textContent = name === "λ" ? "Lambda" : name;
    g.appendChild(t);
    svg.appendChild(g);
  });

  container.replaceChildren(svg);
}

function showFlowDetail(flow) {
  const c = document.getElementById("side-content");
  c.replaceChildren();
  const h = document.createElement("h3");
  h.textContent = flow.flow;
  c.appendChild(h);
  const row = document.createElement("div");
  row.className = "side-status-row";
  const sw = document.createElement("span");
  sw.className = "legend-swatch";
  sw.style.background = `var(--st-${flow.status})`;
  row.append(sw, document.createTextNode(flow.status_text || flow.status));
  c.appendChild(row);
  const h4 = document.createElement("h4");
  h4.textContent = "Notes";
  c.appendChild(h4);
  const p = document.createElement("p");
  p.textContent = flow.notes;
  c.appendChild(p);
  openSidePanel();
}

// ---------------------------------------------------------------- TIMELINE

function renderTimeline() {
  const container = document.getElementById("timeline");
  container.replaceChildren();
  (DATA.timeline || []).forEach((entry) => {
    const pill = document.createElement("div");
    pill.className = `timeline-pill ${entry.shipped ? "shipped" : "pending"}`;
    const v = document.createElement("div");
    v.className = "timeline-version";
    v.textContent = `v${entry.version}`;
    const n = document.createElement("div");
    n.className = "timeline-name";
    n.textContent = entry.name;
    const d = document.createElement("div");
    d.className = "timeline-date";
    d.textContent = entry.date || (entry.shipped ? "shipped" : "planned");
    pill.append(v, n, d);
    pill.addEventListener("click", () => {
      document.querySelectorAll(".timeline-pill.selected").forEach((p) => p.classList.remove("selected"));
      pill.classList.add("selected");
      showVersionDetail(entry);
    });
    container.append(pill);
  });
}

function showVersionDetail(entry) {
  const c = document.getElementById("side-content");
  c.replaceChildren();
  const h = document.createElement("h3");
  h.textContent = `v${entry.version} — ${entry.name}`;
  c.appendChild(h);
  if (entry.headline) {
    const p = document.createElement("p");
    p.textContent = entry.headline;
    c.appendChild(p);
  }
  if (entry.scope) {
    const h4 = document.createElement("h4");
    h4.textContent = "Scope";
    c.appendChild(h4);
    const p = document.createElement("p");
    p.textContent = entry.scope;
    c.appendChild(p);
  }
  if (entry.rationale) {
    const h4 = document.createElement("h4");
    h4.textContent = "Why this order";
    c.appendChild(h4);
    const p = document.createElement("p");
    p.textContent = entry.rationale;
    c.appendChild(p);
  }
  if (entry.tests && Object.keys(entry.tests).length) {
    const h4 = document.createElement("h4");
    h4.textContent = "Conformance after this release";
    c.appendChild(h4);
    const ul = document.createElement("ul");
    Object.entries(entry.tests).forEach(([lang, n]) => {
      const li = document.createElement("li");
      const s = document.createElement("strong");
      s.textContent = lang.toUpperCase() + ": ";
      li.appendChild(s);
      li.append(document.createTextNode(String(n)));
      ul.appendChild(li);
    });
    c.appendChild(ul);
  }
  openSidePanel();
}

// ---------------------------------------------------------------- BENCH

function renderBench() {
  const container = document.getElementById("bench-grid");
  container.replaceChildren();
  (DATA.bench || []).forEach((row) => {
    const t = document.createElement("div");
    t.className = "bench-tile";
    t.innerHTML = `<div class="bench-metric"></div><div class="bench-measured"></div><div class="bench-budget"></div>`;
    t.children[0].textContent = row.metric;
    t.children[1].textContent = row.measured;
    t.children[2].textContent = row.budget && row.budget !== "—" ? `budget ${row.budget}` : "no budget";
    container.append(t);
  });
}

// ---------------------------------------------------------------- SIDE PANEL

function openSidePanel() {
  const p = document.getElementById("side-panel");
  p.hidden = false;
}
function closeSidePanel() {
  document.getElementById("side-panel").hidden = true;
  document.querySelectorAll(".timeline-pill.selected, .wiring-flow.selected").forEach((e) => e.classList.remove("selected"));
}

// ---------------------------------------------------------------- TOOLTIP

function attachTooltip() {
  tooltipEl = document.createElement("div");
  tooltipEl.className = "tooltip";
  document.body.appendChild(tooltipEl);

  document.addEventListener("mouseover", (e) => {
    const target = e.target.closest("[data-tooltip]");
    if (!target) return;
    const raw = target.dataset.tooltip;
    showTooltip(raw, e);
  });
  document.addEventListener("mousemove", (e) => {
    if (tooltipEl.classList.contains("visible")) positionTooltip(e);
  });
  document.addEventListener("mouseout", (e) => {
    if (!e.target.closest("[data-tooltip]")) hideTooltip();
  });
}

function showTooltip(raw, e) {
  // Render `**title**` as <strong> and a trailing line as meta.
  const html = raw.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>").replace(/\n([^\n]+)$/, '<div class="tt-meta">$1</div>');
  tooltipEl.innerHTML = html;
  tooltipEl.classList.add("visible");
  positionTooltip(e);
}
function positionTooltip(e) {
  const offset = 14;
  let x = e.clientX + offset;
  let y = e.clientY + offset;
  const w = tooltipEl.offsetWidth;
  const h = tooltipEl.offsetHeight;
  if (x + w > window.innerWidth - 8) x = e.clientX - w - offset;
  if (y + h > window.innerHeight - 8) y = e.clientY - h - offset;
  tooltipEl.style.left = `${x}px`;
  tooltipEl.style.top = `${y}px`;
}
function hideTooltip() { tooltipEl.classList.remove("visible"); }

init();
