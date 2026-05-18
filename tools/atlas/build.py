#!/usr/bin/env python3
"""Atlas data builder.

Parses the canonical docs (SUPPORT.md / CHANGELOG.md / PRD.md /
COVERAGE.md / BENCH.md / CLAUDE.md) into a single ``data.json`` file
that ``tools/atlas/index.html`` renders.

Run from anywhere::

    python3 tools/atlas/build.py

The atlas is *derived* from the docs — there is no separate source of
truth for it. If the docs and data.json drift, rerun this script.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCS = REPO_ROOT / "docs"
ATLAS = REPO_ROOT / "tools" / "atlas"

SUPPORT_MD = DOCS / "SUPPORT.md"
CHANGELOG_MD = DOCS / "CHANGELOG.md"
PRD_MD = DOCS / "PRD.md"
COVERAGE_MD = DOCS / "COVERAGE.md"
BENCH_MD = DOCS / "BENCH.md"
CLAUDE_MD = REPO_ROOT / "CLAUDE.md"

DEFAULT_PLANS_DIR = Path.home() / ".claude" / "plans"


# ---------------------------------------------------------------------------
# Status normalization
#
# The Status column in SUPPORT.md op tables is prose, but a few signals
# distinguish enforcement levels. Order matters: more specific patterns
# win over more general ones.

# Leading-token rules. The op's row category is decided by what the
# status text *starts* with; "enforced" upgrades "supported" when the
# row explicitly calls out enforcement work tied to this op.

ENFORCE_HINTS = re.compile(
    r"\benforced at request time\b|\benforced as of\b|\*\*enforced\b|\bevaluated at publish time\b|\bgated by\b",
    re.I,
)


def classify_status(text: str) -> str:
    s = text.lstrip()
    low = s.lower()
    if low.startswith(("not supported", "rejected", "not routed", "not implemented")):
        return "not_supported"
    if low.startswith("partial"):
        return "partial"
    if low.startswith(("accept-store-roundtrip", "accepted and ignored", "stub", "stored but")):
        return "roundtrip"
    if low.startswith("supported"):
        return "enforced" if ENFORCE_HINTS.search(text) else "supported"
    return "unknown"


# ---------------------------------------------------------------------------
# Markdown table parsing


@dataclass
class TableRow:
    cells: list[str]


def parse_md_table(lines: list[str]) -> tuple[list[str], list[TableRow]] | None:
    """Parse a markdown pipe-table starting at lines[0].

    Returns ``(headers, rows)`` or ``None`` if not a table.
    Stops at the first blank line or non-table line.
    """
    if not lines or not lines[0].lstrip().startswith("|"):
        return None
    header_cells = _split_row(lines[0])
    if len(lines) < 2 or not re.match(r"\s*\|\s*[-:]+", lines[1]):
        return None
    rows: list[TableRow] = []
    for line in lines[2:]:
        if not line.strip() or not line.lstrip().startswith("|"):
            break
        rows.append(TableRow(cells=_split_row(line)))
    return header_cells, rows


def _split_row(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [cell.strip() for cell in line.split("|")]


# ---------------------------------------------------------------------------
# Section walking


def section_lines(text: str, heading_re: re.Pattern[str], stop_re: re.Pattern[str]) -> list[str]:
    """Slice ``text`` between the first line matching ``heading_re`` and
    the next line matching ``stop_re`` (exclusive of both)."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if heading_re.match(line):
            start = i + 1
            break
    if start is None:
        return []
    end = len(lines)
    for j in range(start, len(lines)):
        if stop_re.match(lines[j]):
            end = j
            break
    return lines[start:end]


def find_first_table(lines: list[str]) -> tuple[int, list[str], list[TableRow]] | None:
    """Find the first markdown table within ``lines``.

    Returns ``(start_index, headers, rows)`` or ``None``.
    """
    for i, line in enumerate(lines):
        if line.lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"\s*\|\s*[-:]+", lines[i + 1]):
            parsed = parse_md_table(lines[i:])
            if parsed is not None:
                headers, rows = parsed
                return i, headers, rows
    return None


# ---------------------------------------------------------------------------
# Divergence bullets


DIVERGENCE_BULLET = re.compile(r"^\s*-\s+\*\*(?P<title>[^*]+?)\*\*\.?\s*(?P<body>.*)$")


def parse_divergences(lines: list[str]) -> list[dict]:
    """Pull `- **Title.** Body.` bullets until the next blank+heading boundary."""
    out: list[dict] = []
    for line in lines:
        if line.startswith("#"):
            break
        m = DIVERGENCE_BULLET.match(line)
        if m:
            out.append({"title": m.group("title").rstrip("."), "body": m.group("body").strip()})
    return out


# ---------------------------------------------------------------------------
# SUPPORT.md


# AWS docs URL conventions per service. Op name appended verbatim.
AWS_DOC_PATTERN: dict[str, str] = {
    "S3": "https://docs.aws.amazon.com/AmazonS3/latest/API/API_{op}.html",
    "DynamoDB": "https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_{op}.html",
    "SQS": "https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_{op}.html",
    "SNS": "https://docs.aws.amazon.com/sns/latest/api/API_{op}.html",
}

SERVICE_DIR_KEY: dict[str, str] = {
    "S3": "s3",
    "DynamoDB": "dynamodb",
    "SQS": "sqs",
    "SNS": "sns",
}


def code_paths_for(service_name: str) -> list[dict]:
    """Conventional directories where a service's request flow lives.

    Intentionally directories, not files — saves us from parsing
    dispatch tables, which would drift on every refactor.
    """
    key = SERVICE_DIR_KEY.get(service_name)
    if not key:
        return []
    return [
        {"label": "Service handlers", "path": f"src/services/{key}/"},
        {"label": "Wire layer (parsers + renderers)", "path": f"src/wire/{key}/"},
        {"label": "Python conformance tests", "path": f"tests/conformance/python/{key}/"},
        {"label": "JS conformance tests", "path": f"tests/conformance/js/{key}/"},
        {"label": "AWS CLI conformance tests", "path": f"tests/conformance/awscli/{key}/"},
    ]


def aws_doc_url(service_name: str, op: str) -> str | None:
    """Build the canonical AWS API reference URL for an op.

    Heuristic: only emit a URL for ops whose name looks like a real
    AWS API call (CamelCase, starts with a verb). Skip rows that
    document features rather than operations, e.g. "ConditionExpression".
    """
    pat = AWS_DOC_PATTERN.get(service_name)
    if not pat:
        return None
    if not op or not op[0].isupper():
        return None
    # Reject rows that are clearly features/grammar elements, not API ops.
    if " " in op or "/" in op or "(" in op:
        return None
    return pat.format(op=op)


@dataclass
class ServiceData:
    name: str
    ops: list[dict] = field(default_factory=list)
    divergences: list[dict] = field(default_factory=list)
    code_paths: list[dict] = field(default_factory=list)


def parse_support(text: str) -> tuple[list[ServiceData], dict, list[dict]]:
    """Returns ``(services, cross_service, wedge_table)``."""
    services: list[ServiceData] = []
    wedge_rows: list[dict] = []

    # Accuracy-wins-vs-LocalStack: first table after "# Service support" / start of file.
    head = text.splitlines()
    first = find_first_table(head[:100])
    if first is not None:
        _, _headers, rows = first
        for r in rows:
            if len(r.cells) >= 4:
                wedge_rows.append({
                    "n": r.cells[0],
                    "behaviour": r.cells[1],
                    "localstack": r.cells[2],
                    "test": r.cells[3],
                })

    # Per-service H2 sections we care about.
    for name in ("S3", "DynamoDB", "SQS", "SNS"):
        heading_re = re.compile(rf"^## {re.escape(name)}\s*$")
        stop_re = re.compile(r"^## ")
        body = section_lines(text, heading_re, stop_re)
        if not body:
            continue
        sd = ServiceData(name=name, code_paths=code_paths_for(name))
        # Capture only the FIRST `Operation`-column table per service.
        # S3's section has several capability / config / tagging tables
        # too, but for the matrix we want the canonical op list — the
        # divergences prose covers the rest.
        idx = 0
        while idx < len(body):
            t = find_first_table(body[idx:])
            if t is None:
                break
            offset, headers, rows = t
            absolute = idx + offset
            if headers and headers[0].lower() == "operation":
                for r in rows:
                    if len(r.cells) >= 3:
                        status_text = r.cells[1]
                        op_name = r.cells[0]
                        sd.ops.append({
                            "name": op_name,
                            "status_text": status_text,
                            "status": classify_status(status_text),
                            "milestone": r.cells[2],
                            "aws_doc_url": aws_doc_url(name, op_name),
                        })
                break  # one op table per service is enough for the matrix.
            # Not the op table; advance past it.
            end = absolute + 2
            while end < len(body) and body[end].lstrip().startswith("|"):
                end += 1
            idx = end
        # Divergences: take the first "Documented divergences" bullet block.
        for i, line in enumerate(body):
            if "documented divergences" in line.lower():
                sd.divergences = parse_divergences(body[i + 1:])
                break
        services.append(sd)

    # Cross-service wiring.
    cross_lines = section_lines(text, re.compile(r"^## Cross-service wiring\s*$"), re.compile(r"^## "))
    wiring_rows: list[dict] = []
    if cross_lines:
        t = find_first_table(cross_lines)
        if t is not None:
            _, _headers, rows = t
            for r in rows:
                if len(r.cells) >= 3:
                    wiring_rows.append({
                        "flow": r.cells[0],
                        "status_text": r.cells[1],
                        "status": classify_status(r.cells[1]),
                        "notes": r.cells[2],
                    })
    cross = {"flows": wiring_rows}
    return services, cross, wedge_rows


# ---------------------------------------------------------------------------
# CHANGELOG.md


CHANGELOG_HEADING = re.compile(r"^##\s+\[(?P<v>\d+\.\d+\.\d+)\]\s+—\s+(?P<date>\d{4}-\d{2}-\d{2})\s*$")
TEST_COUNT_LINE = re.compile(r"^\s*-\s+(?P<lang>Python|JS|AWS CLI):\s+\d+\s*→\s*(?P<after>\d+)\b", re.I)


def parse_changelog(text: str) -> list[dict]:
    lines = text.splitlines()
    entries: list[dict] = []
    i = 0
    while i < len(lines):
        m = CHANGELOG_HEADING.match(lines[i])
        if not m:
            i += 1
            continue
        version = m.group("v")
        date = m.group("date")
        # Headline = first non-blank line after the heading that isn't bold.
        headline = ""
        j = i + 1
        while j < len(lines) and not lines[j].strip():
            j += 1
        if j < len(lines):
            line = lines[j].strip()
            # Often the first line is **Patch release: foo.** ; strip wrapping bold.
            if line.startswith("**") and line.endswith("**"):
                headline = line.strip("*").rstrip(".")
            else:
                headline = line.rstrip(".")
        # Walk until the next H2 collecting test counts.
        tests: dict[str, int] = {}
        k = i + 1
        while k < len(lines) and not CHANGELOG_HEADING.match(lines[k]):
            t = TEST_COUNT_LINE.match(lines[k])
            if t:
                lang = t.group("lang").lower().replace(" ", "_")
                if lang == "aws_cli":
                    lang = "awscli"
                tests[lang] = int(t.group("after"))
            k += 1
        entries.append({
            "version": version,
            "date": date,
            "headline": headline,
            "tests": tests,
        })
        i = k
    return entries


# ---------------------------------------------------------------------------
# PRD §15 trajectory


PRD_ROW_SHIPPED = re.compile(r"~~\*\*v(?P<v>[\d.]+)\s+—\s+(?P<name>[^*~]+?)\*\*~~", re.I)
PRD_ROW_PENDING = re.compile(r"\*\*v(?P<v>[\d.]+)\s+—\s+(?P<name>[^*]+?)\*\*", re.I)


def parse_trajectory(text: str) -> list[dict]:
    body = section_lines(
        text,
        re.compile(r"^##\s+15\.\s+Roadmap"),
        re.compile(r"^---\s*$|^##\s+16\."),
    )
    out: list[dict] = []
    for line in body:
        if not line.lstrip().startswith("|"):
            continue
        cells = _split_row(line)
        if len(cells) < 3 or cells[0].startswith("---"):
            continue
        m_shipped = PRD_ROW_SHIPPED.search(cells[0])
        if m_shipped:
            out.append({
                "version": m_shipped.group("v"),
                "name": m_shipped.group("name").strip(),
                "shipped": True,
                "scope": _strip_md(cells[1]),
                "rationale": _strip_md(cells[2]),
            })
            continue
        m_pending = PRD_ROW_PENDING.search(cells[0])
        if m_pending:
            out.append({
                "version": m_pending.group("v"),
                "name": m_pending.group("name").strip(),
                "shipped": False,
                "scope": _strip_md(cells[1]),
                "rationale": _strip_md(cells[2]),
            })
    return out


def _strip_md(s: str) -> str:
    """Cheap markdown stripping for prose cells."""
    s = re.sub(r"~~([^~]+)~~", r"\1", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
    s = re.sub(r"`([^`]+)`", r"\1", s)
    return s.strip()


# ---------------------------------------------------------------------------
# COVERAGE.md


COVERAGE_RE = re.compile(r"\*\*Coverage:\s*(?P<covered>\d+)\s*/\s*(?P<total>\d+)")


def parse_coverage(text: str) -> dict:
    m = COVERAGE_RE.search(text)
    if not m:
        return {}
    return {"s3": [int(m.group("covered")), int(m.group("total"))]}


# ---------------------------------------------------------------------------
# BENCH.md


def parse_bench(text: str) -> list[dict]:
    body = section_lines(
        text,
        re.compile(r"^##\s+Current baseline"),
        re.compile(r"^##\s"),
    )
    t = find_first_table(body)
    if t is None:
        return []
    _, headers, rows = t
    out: list[dict] = []
    for r in rows:
        if len(r.cells) >= 3:
            out.append({
                "metric": r.cells[0],
                "measured": r.cells[1].lstrip("~").strip(),
                "budget": r.cells[2].lstrip("~").strip(),
            })
    return out


# ---------------------------------------------------------------------------
# CLAUDE.md tagline


def parse_claude_intro(text: str) -> tuple[str, str]:
    """Returns (version, tagline-prose)."""
    # Find the project intro paragraph.
    m = re.search(r"Currently\s+`v(?P<v>[\d.]+)`\s+—\s+(?P<rest>[^\n]+)", text)
    if m:
        return m.group("v"), m.group("rest").strip().rstrip(".")
    return "", ""


# ---------------------------------------------------------------------------
# Plan parsing (~/.claude/plans/<slug>.md)
#
# Plans vary in structure across files: some use "Decisions Taken",
# others "Approach + File changes" tables. We do a generic H2 walk
# first; then run a small layer of enrichers that attach extra
# structure when a section matches a known shape. Unknown sections
# fall through to a freeform card on the frontend.


def find_active_plan(plans_dir: Path) -> Path | None:
    """Return the most-recently-modified `.md` file in ``plans_dir``."""
    if not plans_dir.exists() or not plans_dir.is_dir():
        return None
    candidates = list(plans_dir.glob("*.md"))
    if not candidates:
        return None
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


H1_RE = re.compile(r"^#\s+(.+?)\s*$")
H2_RE = re.compile(r"^##\s+(.+?)\s*$")
H3_RE = re.compile(r"^###\s+(.+?)\s*$")
NUMBERED_RE = re.compile(r"^(\d+)\.\s+(.+)$")
BULLET_RE = re.compile(r"^[-*]\s+(.+)$")


def _classify_section(title: str) -> str:
    t = title.strip().lower()
    if t in ("context", "background", "approach", "summary"):
        return "context"
    if t in ("decisions taken", "decisions", "approach (numbered)"):
        return "decisions"
    if t == "scope":
        return "scope"
    if t in ("critical files", "file changes", "files"):
        return "files"
    if t in ("open items", "out of scope", "out of scope (explicit)", "boundaries", "deferred", "open questions"):
        return "boundaries"
    return "freeform"


def _split_h2_sections(lines: list[str]) -> list[dict]:
    """Walk markdown lines, returning a list of `{title, raw_lines}` per H2."""
    sections: list[dict] = []
    current: dict | None = None
    for line in lines:
        m = H2_RE.match(line)
        if m:
            if current is not None:
                sections.append(current)
            current = {"title": m.group(1), "raw_lines": []}
        else:
            if current is not None:
                current["raw_lines"].append(line)
    if current is not None:
        sections.append(current)
    # Trim trailing blank lines per section.
    for s in sections:
        while s["raw_lines"] and not s["raw_lines"][-1].strip():
            s["raw_lines"].pop()
    return sections


def _enrich_decisions(raw_lines: list[str]) -> list[str] | None:
    """Extract numbered list items (decisions/approach steps). Returns
    items joined with their continuation paragraphs, or None if no
    numbered items found."""
    items: list[str] = []
    current: list[str] | None = None
    for line in raw_lines:
        m = NUMBERED_RE.match(line.strip())
        if m:
            if current is not None:
                items.append("\n".join(current).strip())
            current = [m.group(2)]
        elif current is not None and (line.startswith(" ") or line.startswith("\t") or not line.strip() or BULLET_RE.match(line.strip()) is None):
            # Either an indented continuation, a blank line within an item,
            # or any non-numbered prose — fold into the current item.
            current.append(line)
    if current is not None:
        items.append("\n".join(current).strip())
    return items if items else None


def _enrich_scope_phases(raw_lines: list[str]) -> list[dict] | None:
    """Split a Scope section into phase cards by `### Phase *` H3s."""
    phases: list[dict] = []
    current: dict | None = None
    for line in raw_lines:
        m = H3_RE.match(line)
        if m and "phase" in m.group(1).lower():
            if current is not None:
                phases.append(current)
            current = {"title": m.group(1), "raw_lines": []}
        else:
            if current is not None:
                current["raw_lines"].append(line)
    if current is not None:
        phases.append(current)
    # Trim each phase's trailing blank lines.
    for p in phases:
        while p["raw_lines"] and not p["raw_lines"][-1].strip():
            p["raw_lines"].pop()
    return phases if phases else None


def _enrich_files(raw_lines: list[str]) -> dict | None:
    """Split Critical Files into Modified vs New lists.

    Supports two shapes:
      ### Modified / ### New  (H3 sub-headings)
      **Modified:** / **New:** (bold inline labels)
    """
    modified: list[str] = []
    new: list[str] = []
    bucket: list[str] | None = None
    for line in raw_lines:
        h3 = H3_RE.match(line)
        if h3:
            t = h3.group(1).strip().lower()
            if "modified" in t:
                bucket = modified
            elif "new" in t:
                bucket = new
            else:
                bucket = None
            continue
        # Bold-label sentinels.
        stripped = line.strip()
        if stripped.startswith("**Modified") or stripped.startswith("**modified"):
            bucket = modified
            continue
        if stripped.startswith("**New") or stripped.startswith("**new"):
            bucket = new
            continue
        if bucket is None:
            continue
        m = BULLET_RE.match(stripped)
        if m:
            bucket.append(m.group(1))
    if not modified and not new:
        return None
    return {"modified": modified, "new": new}


def _enrich_boundaries(raw_lines: list[str]) -> list[str] | None:
    """Pull top-level bullets from an Open Items / Out of Scope section."""
    items: list[str] = []
    current: list[str] | None = None
    for line in raw_lines:
        m = BULLET_RE.match(line.lstrip())
        if m and not line.startswith(" ") and not line.startswith("\t"):
            if current is not None:
                items.append("\n".join(current).strip())
            current = [m.group(1)]
        elif current is not None:
            current.append(line)
    if current is not None:
        items.append("\n".join(current).strip())
    return items if items else None


def parse_plan(text: str) -> dict:
    """Parse a plan markdown into the atlas plan-board structure."""
    lines = text.splitlines()
    title = ""
    for line in lines:
        m = H1_RE.match(line)
        if m:
            title = m.group(1)
            break

    raw_sections = _split_h2_sections(lines)
    sections: list[dict] = []
    for s in raw_sections:
        kind = _classify_section(s["title"])
        body = "\n".join(s["raw_lines"]).strip()
        record: dict = {
            "title": s["title"],
            "type": kind,
            "body": body,
        }
        if kind == "decisions":
            extracted = _enrich_decisions(s["raw_lines"])
            if extracted:
                record["items"] = extracted
            else:
                record["type"] = "freeform"
        elif kind == "scope":
            phases = _enrich_scope_phases(s["raw_lines"])
            if phases:
                record["phases"] = [
                    {"title": p["title"], "body": "\n".join(p["raw_lines"]).strip()}
                    for p in phases
                ]
            else:
                record["type"] = "freeform"
        elif kind == "files":
            split = _enrich_files(s["raw_lines"])
            if split:
                record["modified"] = split["modified"]
                record["new"] = split["new"]
            else:
                record["type"] = "freeform"
        elif kind == "boundaries":
            items = _enrich_boundaries(s["raw_lines"])
            if items:
                record["items"] = items
            else:
                record["type"] = "freeform"
        sections.append(record)
    return {"title": title, "sections": sections}


def build_plan_payload(plans_dir: Path) -> dict:
    """Top-level orchestrator. Always returns a JSON-safe dict, even on
    error — frontend reads `present` to branch."""
    plans_dir = plans_dir.expanduser()
    path = find_active_plan(plans_dir)
    if path is None:
        return {
            "present": False,
            "reason": "no .md files in plans dir",
            "source_dir": str(plans_dir),
        }
    parsed = parse_plan(path.read_text())
    mtime = dt.datetime.fromtimestamp(path.stat().st_mtime, tz=dt.timezone.utc)
    return {
        "present": True,
        "slug": path.stem,
        "source_path": str(path),
        "source_dir": str(plans_dir),
        "mtime": mtime.isoformat(),
        "title": parsed["title"],
        "sections": parsed["sections"],
    }


# ---------------------------------------------------------------------------
# Main


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Build the atlas data + plan JSON.")
    ap.add_argument("--plan-only", action="store_true",
                    help="Skip re-parsing project docs; refresh plan.json only.")
    ap.add_argument("--data-only", action="store_true",
                    help="Skip the plan parse; refresh data.json only.")
    ap.add_argument("--plans-dir", default=os.environ.get("PLANS_DIR"),
                    help="Override the plans directory. Default ~/.claude/plans/")
    args = ap.parse_args(argv)

    plans_dir = Path(args.plans_dir) if args.plans_dir else DEFAULT_PLANS_DIR

    if not args.plan_only:
        _build_data_json()

    if not args.data_only:
        _build_plan_json(plans_dir)

    return 0


def _build_plan_json(plans_dir: Path) -> None:
    payload = build_plan_payload(plans_dir)
    out_path = ATLAS / "plan.json"
    out_path.write_text(json.dumps(payload, indent=2) + "\n")
    rel = out_path.relative_to(REPO_ROOT)
    if payload.get("present"):
        print(f"wrote {rel}")
        print(f"  plan: {payload['title'][:60]}{'…' if len(payload['title']) > 60 else ''}")
        print(f"  slug: {payload['slug']}")
        print(f"  sections: {len(payload['sections'])}")
    else:
        print(f"wrote {rel} (empty-state — {payload['reason']})")


def _build_data_json() -> None:
    services, cross, wedge = parse_support(SUPPORT_MD.read_text())
    changelog = parse_changelog(CHANGELOG_MD.read_text())
    trajectory = parse_trajectory(PRD_MD.read_text())
    coverage = parse_coverage(COVERAGE_MD.read_text())
    bench = parse_bench(BENCH_MD.read_text())
    version, tagline = parse_claude_intro(CLAUDE_MD.read_text())

    # Merge trajectory + changelog by version into a single timeline.
    by_version = {e["version"]: e for e in changelog}
    timeline: list[dict] = []
    for row in trajectory:
        entry = {
            "version": row["version"],
            "name": row["name"],
            "shipped": row["shipped"],
            "scope": row["scope"],
            "rationale": row["rationale"],
        }
        cl = by_version.get(row["version"])
        if cl:
            entry["date"] = cl["date"]
            entry["headline"] = cl["headline"]
            entry["tests"] = cl["tests"]
        timeline.append(entry)
    # CHANGELOG is authoritative for test counts — pick the most recent
    # entry that has them (timeline can be empty / partial).
    latest_tests: dict[str, int] = {}
    for entry in changelog:
        if entry.get("tests"):
            latest_tests = entry["tests"]
            break

    data = {
        "version": version,
        "tagline": tagline,
        "wedge": wedge,
        "services": [asdict(s) for s in services],
        "cross_service": cross,
        "timeline": timeline,
        "coverage": coverage,
        "bench": bench,
        "tests": latest_tests,
    }

    out_path = ATLAS / "data.json"
    out_path.write_text(json.dumps(data, indent=2) + "\n")
    print(f"wrote {out_path.relative_to(REPO_ROOT)}")
    print(f"  version: v{version}")
    print(f"  services: {len(services)}  ({', '.join(s.name + ':' + str(len(s.ops)) for s in services)})")
    print(f"  cross-service flows: {len(cross['flows'])}")
    print(f"  timeline entries: {len(timeline)}")
    print(f"  bench metrics: {len(bench)}")
    print(f"  s3 smithy coverage: {coverage.get('s3')}")
    print(f"  latest tests: {latest_tests}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
