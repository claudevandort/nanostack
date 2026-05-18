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

import json
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
# Main


def main(argv: list[str]) -> int:
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
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
