# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**nanostack** is a snappy, accurate AWS emulator for local development, written in Zig. Single static binary (~0.8 MB stripped), sub-second cold start, ~11 MB idle RSS. Currently `v0.4.2` — four services on the same port: **S3** (68/107 Smithy ops, real bucket-policy / ACL / PAB enforcement), **DynamoDB** (18 ops, full UpdateExpression, queryable GSI/LSI, batch + atomic transactions, 573-word reserved-word enforcement), **SQS** (23 ops including FIFO + Queue Policy enforcement), **SNS** (19 ops including AddPermission/RemovePermission + FilterPolicy evaluation + Topic Policy enforcement). Cross-service wiring: S3 → SQS event notifications, S3 → SNS → SQS multi-hop fan-out. All services verified against Python + JS + AWS CLI v2 conformance suites. Opt-in via `--services s3,dynamodb,sqs,sns`. Pre-`v1.0.0`; minor breaking changes are expected.

The wedge is **accuracy beats LocalStack on the surface we cover**. See `docs/PRD.md` for the full product spec, `docs/SUPPORT.md` for the live op matrix + accuracy-wins-vs-LocalStack section + drift tracking table.

## Common commands

| What | Command |
|---|---|
| Build the binary | `zig build` (output: `zig-out/bin/nanostack`) |
| Run unit tests (in-tree Zig) | `zig build test` |
| Run a single test file | `zig test src/wire/<module>.zig` (some modules need explicit `-Mxml=...` deps — prefer `zig build test` for anything inside `lib_mod`) |
| Run nanostack against a tmp dir | `./zig-out/bin/nanostack --port 4566 --data-dir "$(mktemp -d)"` |
| Run the perf gate | `zig build bench` (wraps `bench/run.sh` — builds ReleaseFast+strip, drives `bench/driver.py`) |
| Release build | `zig build -Doptimize=ReleaseFast -Dstrip=true` |
| Smithy coverage report | `python3 scripts/smithy_coverage.py` (regenerates `docs/COVERAGE.md`) |
| Refresh project atlas | `python3 tools/atlas/build.py` (re-parses docs into `tools/atlas/data.json`; open `tools/atlas/index.html` to view) |

### Conformance suites (CI gate)

Conformance lives in `tests/conformance/{python,awscli,js}/{service}/` — each client surface is split by service so adding a new service is just a new subdirectory. See `tests/conformance/README.md` for the full index.

```sh
# Start a server on a dedicated port (use 14566 to match CI):
./zig-out/bin/nanostack --port 14566 --data-dir "$(mktemp -d)" --services s3,dynamodb &

# Python (boto3) — primary suite, ~308 tests across s3/ and dynamodb/.
cd tests/conformance/python
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
NANOSTACK_ENDPOINT=http://127.0.0.1:14566 \
  NANOSTACK_BIN=$(realpath ../../../zig-out/bin/nanostack) \
  pytest -n auto

# Scope to one service:
pytest -n auto s3/
pytest -n auto dynamodb/

# Single test:
pytest s3/test_versioning.py::test_versioning_head_on_delete_marker_returns_405 -v

# AWS CLI v2 — ~19 tests for high-level commands (s3 cp/sync/mv/presign, dynamodb create-table/put-item/query):
cd tests/conformance/awscli
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
NANOSTACK_ENDPOINT=http://127.0.0.1:14566 pytest -n auto

# JS (aws-sdk-js v3) — ~65 tests across s3/ and dynamodb/:
cd tests/conformance/js && npm ci && NANOSTACK_ENDPOINT=http://127.0.0.1:14566 npm test
```

The AWS CLI suite requires `aws --version` to report v2.x on PATH. CI runners ship v2 pre-installed.

`NANOSTACK_BIN` is required by the few Python tests that spawn their own nanostack (e.g. `test_no_auth_flag_accepts_anonymous`). Conformance binds nanostack on `14566`; everyday dev usually uses `4566`.

## Architecture

Request flow:

```
HTTP (httpz takeover)
  → src/server.zig                 — pipeline: id → log → SigV4 → router → service → render
  → src/auth/sigv4.zig             — header + presigned auth verification
  → src/router.zig                 — (host, path, method, query) → Operation enum
  → src/services/s3/mod.zig        — dispatch table on Operation; per-op handlers in sibling files
  → src/storage/mod.zig (Backend vtable)
  → src/storage/fs.zig             — only impl; persists under --data-dir/profiles/<profile>/s3/...
  → src/wire/*.zig                 — XML parsers + renderers; one file per shape family
  → src/wire/errors.zig            — AWS-compatible <Error> bodies + status code mapping
```

**Key invariants** when touching this code:

- **`storage.Backend` is a vtable**, not a Zig interface — adding a backend op means a new vtable entry in `storage/mod.zig` AND an `fs.zig` impl. The fs backend is the only one shipped; the vtable exists as an abstraction boundary for future backends.
- **Per-request arena allocator**: handlers receive `ctx.allocator` which is freed when the response is sent. Body + header values are arena-allocated. The backend uses `self.allocator` (long-lived) for persisted state.
- **`Context.owner_id` / `owner_display_name`** come from the configured `access_key` and represent the bucket-owner identity. Used wherever AWS responses emit `<Owner>` (ListObjectsV2 fetch-owner, ListObjectVersions, ListMultipartUploads) and as the principal identity for owner-implicit FULL_CONTROL in the authz hook.
- **Authz hook runs between `router.parse` and `s3.handle`** (`src/auth/authz.zig`). Bucket policy + ACL + PAB are **really evaluated**, not accept-store-roundtrip. Order: account-scoped fast-path → PAB filters (non-owner) → bucket policy → ACL (per-object on object-read, per-bucket on object-create) → bucket-owner-implicit FULL_CONTROL → default deny. `--no-auth` bypasses both SigV4 and this hook. Unsigned requests arrive as `Principal.anonymous()` and go through the hook, not auto-403 — that's how `public-read` works end-to-end.
- **XML emitter at `src/wire/xml.zig`**: `Element.text = null` self-closes as `<Foo/>`; `Element.text = ""` emits paired `<Foo></Foo>`. AWS expects paired tags for empty-but-present fields (Prefix, Delimiter, KeyMarker).
- **Storage schema is versioned by milestones**, not by an explicit schema version field — every new persisted field on `MetaDoc` / `VersionedMetaDoc` / `ManifestDoc` / `BucketRecord` must be threaded through `readMeta`, `writeFlat*`, `cloneVersionedMeta`, `freeObjectMetaOwned`, `rebuildVersionIndex`, `migrateNoneToEnabled`, `rewriteVersionMeta`, `putObjectFlat`, `putObjectVersioned`, `completeMultipartUpload`, `rebuildUploadIndex`, `writeManifest`. M9/M10/M11/M12/M13 commits are the templates.
- **SUPPORT.md drift table** (`docs/SUPPORT.md` § "Known drift — to fix") tracks known AWS-spec divergences across 3 waves. All three waves are done as of v0.1.3 — the table is empty and the only reason it remains is to record what we fixed. Future drift goes into a new wave.
- **PR checklist** (`.github/PULL_REQUEST_TEMPLATE.md`): every PR confirms `zig build && zig build test` green, conformance suites green, and updates `docs/SUPPORT.md` + `docs/CHANGELOG.md` when user-visible behaviour shifts.

## Development workflow

This codebase follows a strict plan-then-implement loop. Every non-trivial task — features, drift fixes, refactors — goes through these steps in order:

1. **Plan mode first.** Enter plan mode for any new task. Ask clarifying questions before designing; spend up to a minute on read-only investigation so questions are specific.
2. **Plan file.** Write the plan to the plan file (`~/.claude/plans/<slug>.md`). Include: **Context** (why), **Decisions Taken** (numbered), **Scope** (per-phase breakdown), **Critical Files** (modified vs new), **Reuse Anchors**, **Implementation Order**, **Verification** (build/test/manual smoke), **Open Items**.
3. **User approval.** Exit plan mode (`ExitPlanMode`) to request approval. **Do not start coding until the user approves.**
4. **Branch + PR up front.** Create a feature branch and an empty PR whose body **is the plan**. The PR is the durable record of intent.
5. **Implement.** Commit-per-phase or commit-per-fix so the diff bisects cleanly. Each commit ends green on `zig build && zig build test && pytest -n auto`. Don't move forward on red.
6. **Append learnings.** Anything non-obvious encountered along the way (a workaround, a quirk discovered, a follow-up surfaced) goes as an addendum to the PR description. The plan stays as written; learnings accrete below it.
7. **Commit, push, merge.** Push the branch, merge the PR to `main`.
8. **Switch back.** `git checkout main && git pull` so the next task starts from a clean tip.

Notes:
- For a single drift row or one-line fix, the "plan" can be ~10 lines — the workflow scales down. The branch + PR + learnings cycle stays.
- Multi-fix waves (see SUPPORT.md drift table) follow one PR per wave, one commit per fix inside the wave, plus a tracking-table commit at the start of the wave.
- `docs/SUPPORT.md` rows move `todo → in-progress → done` in the same commit that lands the fix + its conformance test.

## Pointers

- `docs/PRD.md` — product spec, perf budgets (§12), milestone roadmap.
- `docs/SUPPORT.md` — live op matrix, accuracy wins, drift tracking.
- `docs/CHANGELOG.md` — release notes + the project-specific versioning scheme (patch / minor / major mean specific things — read it once).
- `docs/BENCH.md` — perf gate setup + latest dev-machine numbers.
- `docs/COVERAGE.md` — auto-regenerated from `scripts/smithy_coverage.py` against `scripts/.cache/s3.json`.
