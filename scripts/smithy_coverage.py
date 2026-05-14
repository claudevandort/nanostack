#!/usr/bin/env python3
"""Compare nanostack's routed S3 operations against the AWS S3 Smithy model.

Reads the cached Smithy JSON at `scripts/.cache/s3.json` (refresh with
`--refresh`) and the `Operation` enum in `src/router.zig`. Emits a
Markdown coverage report to stdout.

Usage:
    python3 scripts/smithy_coverage.py > docs/COVERAGE.md
    python3 scripts/smithy_coverage.py --refresh > docs/COVERAGE.md
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CACHE = REPO / "scripts" / ".cache" / "s3.json"
ROUTER = REPO / "src" / "router.zig"

SMITHY_URL = "https://raw.githubusercontent.com/aws/aws-sdk-go-v2/main/codegen/sdk-codegen/aws-models/s3.json"


def refresh_cache() -> None:
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["curl", "-fsSL", "-o", str(CACHE), SMITHY_URL], check=True)


def load_smithy_ops() -> list[str]:
    data = json.loads(CACHE.read_text())
    ops: list[str] = []
    for shape_id, shape in data["shapes"].items():
        if shape.get("type") == "operation":
            short = shape_id.split("#", 1)[1]
            ops.append(short)
    ops.sort()
    return ops


def load_routed_ops() -> list[str]:
    """Extract Operation enum variants from router.zig, in snake_case."""
    src = ROUTER.read_text()
    m = re.search(r"pub const Operation = enum \{(.*?)\};", src, re.S)
    if not m:
        raise RuntimeError("Could not find Operation enum in router.zig")
    body = m.group(1)
    variants: list[str] = []
    for line in body.splitlines():
        line = line.strip().rstrip(",").strip()
        if not line or line.startswith("//"):
            continue
        if line == "unknown":
            continue
        variants.append(line)
    return variants


# Synthetic ops: dispatched by header-discrimination within another routed
# op, so they don't appear as Operation enum variants. We credit them
# explicitly. Each entry: (AWS PascalCase op name, "discriminator note").
SYNTHETIC = {
    "CopyObject": "Dispatched from put_object when x-amz-copy-source header is present",
    "UploadPartCopy": "Dispatched from upload_part when x-amz-copy-source header is present",
}


def snake_to_pascal(name: str) -> str:
    """Convert nanostack snake_case → AWS PascalCase. Handles known
    quirks (numeric suffixes, ACL/MFA acronyms)."""
    # Special-case the few names that don't follow naive PascalCase rules.
    SPECIAL = {
        "list_objects_v2": "ListObjectsV2",
        "put_bucket_acl": "PutBucketAcl",
        "get_bucket_acl": "GetBucketAcl",
        "put_object_acl": "PutObjectAcl",
        "get_object_acl": "GetObjectAcl",
        # AWS uses the *Configuration suffix for these; our enum names omit it.
        "put_bucket_lifecycle": "PutBucketLifecycleConfiguration",
        "get_bucket_lifecycle": "GetBucketLifecycleConfiguration",
        "put_bucket_notification": "PutBucketNotificationConfiguration",
        "get_bucket_notification": "GetBucketNotificationConfiguration",
        "put_object_lock_config": "PutObjectLockConfiguration",
        "get_object_lock_config": "GetObjectLockConfiguration",
    }
    if name in SPECIAL:
        return SPECIAL[name]
    return "".join(part.capitalize() for part in name.split("_"))


def categorize(op: str) -> str:
    """Bucket unrouted ops into rough thematic groups for the report."""
    LOW = op.lower()
    # Order matters: more specific prefixes first.
    table = [
        ("Lifecycle", ["lifecycle"]),
        ("Replication", ["replication"]),
        ("Accelerate", ["accelerateconfiguration"]),
        ("Intelligent tiering", ["intelligenttiering"]),
        ("Inventory", ["inventoryconfiguration"]),
        ("Metrics", ["metricsconfiguration"]),
        ("Analytics", ["analyticsconfiguration"]),
        ("Encryption / SSE", ["encryption"]),
        ("CORS", ["cors"]),
        ("Website", ["website"]),
        ("Notifications", ["notificationconfiguration"]),
        ("Request payment", ["requestpayment"]),
        ("Logging", ["bucketlogging"]),
        ("Object Lock / retention / legal hold", [
            "objectlock", "objectretention", "objectlegalhold",
        ]),
        ("Restore / Glacier", ["restoreobject", "selectobjectcontent"]),
        ("Access points / MRAP", ["accesspoint", "multiregion"]),
        ("Public access block", ["publicaccessblock"]),
        ("ACL / policy / ownership", ["acl", "policy", "ownership"]),
        ("Tagging", ["tagging"]),
        ("Versioning", ["versioning", "versions"]),
        ("Multipart", ["multipart", "uploadpart", "uploads"]),
        ("Object torrent", ["torrent"]),
        ("Attributes / metadata", ["attributes", "metadata"]),
    ]
    for label, needles in table:
        for n in needles:
            if n in LOW:
                return label
    if "bucket" in LOW:
        return "Bucket-level (other)"
    if "object" in LOW:
        return "Object-level (other)"
    return "Other"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--refresh", action="store_true", help="Re-download s3.json before running")
    args = p.parse_args()

    if args.refresh or not CACHE.exists():
        refresh_cache()

    smithy_ops = load_smithy_ops()
    routed = load_routed_ops()
    routed_pascal = {snake_to_pascal(v) for v in routed}
    routed_pascal |= set(SYNTHETIC.keys())
    smithy_set = set(smithy_ops)

    # Sanity-check our snake→Pascal mapping by flagging routed names that
    # don't exist in the Smithy model. This catches typos or stale ops.
    bogus = sorted(routed_pascal - smithy_set)

    covered = sorted(routed_pascal & smithy_set)
    unrouted = sorted(smithy_set - routed_pascal)

    total = len(smithy_ops)
    covered_n = len(covered)
    pct = 100 * covered_n / total

    out: list[str] = []
    out.append("# AWS S3 Smithy coverage")
    out.append("")
    out.append(f"Generated from `{SMITHY_URL.rsplit('/', 1)[1]}` and `src/router.zig`.")
    out.append("")
    out.append(f"**Coverage: {covered_n} / {total} operations ({pct:.1f}%)**")
    out.append("")
    if bogus:
        out.append(f"## ⚠ Routed names with no Smithy match ({len(bogus)})")
        out.append("")
        out.append("These names exist in router.zig but the Smithy model doesn't declare them — either we mistyped, or AWS deprecated the op. Check each one.")
        out.append("")
        for name in bogus:
            out.append(f"- `{name}`")
        out.append("")

    out.append(f"## Covered ({covered_n})")
    out.append("")
    for name in covered:
        note = SYNTHETIC.get(name)
        if note:
            out.append(f"- {name} — *{note}*")
        else:
            out.append(f"- {name}")
    out.append("")

    # Group unrouted ops by category for readability.
    out.append(f"## Unrouted ({len(unrouted)})")
    out.append("")
    out.append("Grouped thematically. Most of these are explicit non-goals for v1.x (PRD §15) — kept here as the AWS-side checklist.")
    out.append("")
    grouped: dict[str, list[str]] = {}
    for op in unrouted:
        grouped.setdefault(categorize(op), []).append(op)
    for label in sorted(grouped):
        ops = grouped[label]
        out.append(f"### {label} ({len(ops)})")
        out.append("")
        for op in ops:
            out.append(f"- {op}")
        out.append("")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
