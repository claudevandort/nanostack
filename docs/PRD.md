# nanostack — Product Requirements Document

**Status:** Draft v0.1
**Date:** 2026-05-11
**Owner:** Claudio Guerra
**Scope of this PRD:** Project charter + v1 (S3 service only)

---

## 1. Context

Local AWS emulation today is dominated by **LocalStack** (Python/Docker) and a small handful of alternatives (Ministack, Moto, MinIO, adobe/S3Mock). All of them are useful, none of them feel *snappy*, and several have well-documented fidelity gaps in services as foundational as S3. The pain shows up where developers feel it most: in the inner test loop, in CI startup costs, and when an emulator quietly accepts a request that real AWS would reject (or vice versa).

**nanostack** is an AWS emulator for local development, built ground-up in Zig. We will not try to emulate every AWS service. We will pick a small set and make each one *accurate* (behaves like real AWS, including its errors), *snappy* (sub-second cold start, low idle memory), and *reliable* (no surprise drift across releases). **S3 is the first service.** Additional services will follow once the foundation — wire codecs, SigV4, conformance harness, codegen pipeline — is proven on S3.

This PRD covers the project's overall positioning and the v1 cut (S3 only). Subsequent PRDs will cover each additional service.

---

## 2. Goals and Non-Goals

### Goals
- **Single static binary**, no Docker, no JVM, no Python runtime.
- **Cold start < 500 ms** to "ready to serve."
- **Idle memory < 30 MB.**
- **Accuracy against the AWS SDK conformance matrix** — see §11. We define *exactly* which behaviors we promise to match real AWS on, and prove it with tests on every commit.
- **Permissive license** (Apache 2.0) — no AGPL friction for downstream users.
- **Linux + macOS** support from v1. (Windows is post-v1.)
- **Extensible architecture** so the second, third, and fourth services slot in cleanly without rewriting the core.

### Non-Goals (v1)
- **Not** a production-grade S3-compatible storage system (that's MinIO's market).
- **Not** full LocalStack parity — we are deliberately picking a smaller, sharper surface.
- **Not** a hosted service. Local-only.
- **Not** AWS Console emulation, IAM emulation, or cross-service event wiring in v1.
- **Not** Windows in v1.

### Non-Goals (the whole project, ever)
- Replacing real AWS for production.
- Emulating every AWS service. We will keep the supported list curated.

---

## 3. Target Users

1. **Backend engineers** who write services that talk to S3 and want a tight TDD loop — start, run test, wipe, repeat — in seconds, not minutes.
2. **CI/CD pipelines** where LocalStack's 30–90 s cold start dominates per-job latency.
3. **Polyglot teams** (Go, Rust, Node, Python) who don't want a JVM or container runtime as a test dependency.
4. **Embedded/edge developers** testing S3-bound code on machines where Docker is impractical.
5. **OSS projects** that need a permissively-licensed S3 test double they can vendor or invoke without AGPL compliance concerns.

---

## 4. Competitive Landscape (Findings)

### LocalStack (Python + Hypercorn, Apache 2.0 + Pro)
- **Strengths:** Broadest coverage (~70 AWS services), spec-driven via `botocore`/Smithy with **weekly automated parity PRs**, native S3 implementation (not Moto-backed), event notifications wired across services.
- **Weaknesses:**
  - **Cold start** 30–90 s in realistic CI, ~5 s warm.
  - **Idle memory** ~30–500 MB; objects stored in-memory by default and can grow unbounded.
  - **Known S3 accuracy gaps**: presigned URL validation flaky with custom headers ([#5269](https://github.com/localstack/localstack/issues/5269), [#4133](https://github.com/localstack/localstack/issues/4133), [#10844](https://github.com/localstack/localstack/issues/10844)); range request headers wrong ([#1859](https://github.com/localstack/localstack/issues/1859)); incomplete ACL validation ([#13357](https://github.com/localstack/localstack/issues/13357)); missing AWS error codes ([#10351](https://github.com/localstack/localstack/issues/10351)).
  - Docker-only distribution.

### Ministack (Python, MIT) — *confirmed real project at ministack.org*
- **Strengths:** Smaller image (~270 MB vs LocalStack's ~1 GB), permissive license, 40+ services, real backing stores for adjacent services (Postgres/Redis).
- **Weaknesses:** Still Python/Docker; performance characteristics not dramatically better than LocalStack on the dev loop.

### MinIO (Go, AGPLv3)
- **Strengths:** Production-grade, fast (~1 s startup, ~50–100 MB), broad S3 API.
- **Weaknesses:** **AGPLv3 license friction**; aimed at production, not "wipe-clean local dev"; assumes persistence and admin model that's heavy for tests.

### adobe/S3Mock (Java, Apache 2.0)
- **Strengths:** Easy as a JUnit/TestContainer dependency.
- **Weaknesses:** JVM cold start; **no presigned URL validation, path-style only, no versioning**.

### Moto (Python, Apache 2.0)
- **Strengths:** Mature, lightweight as a Python in-process mock.
- **Weaknesses:** Test-fixture-shaped, not a server-grade emulator; no event notifications.

### Where the wedge is
A **single-binary, sub-second-startup, Apache-2.0, accurate-on-the-core-surface** S3 emulator does not currently exist. MinIO is fast but AGPL and production-shaped. LocalStack is accurate-ish but slow and Docker-only. S3Mock is convenient but inaccurate. The wedge is real but narrow — we win by being **measurably faster on the dev loop AND demonstrably more accurate than S3Mock on the surface we cover.**

---

## 5. Differentiation — The Three Promises

| Promise | How we will keep it |
|---|---|
| **Snappy** | Single static Zig binary, no runtime. Cold start budget 500 ms, p99 GET latency budget 5 ms (warm, in-memory). Continuous regression bench in CI. |
| **Accurate** | Every supported S3 operation has a **conformance test** that runs the official AWS Python SDK (boto3) and AWS JS SDK against nanostack with assertions on response body, headers, status, and error codes. Behaviors not yet covered are explicitly listed in `SUPPORT.md` — we do not over-promise. |
| **Reliable** | Wire codecs and request dispatch are **generated from Smithy models** (the same source AWS uses internally), pinned per release. Hand-written code is limited to *semantics*, not surface. |

---

## 6. Technology Decisions

### Language & runtime
- **Zig 0.16+ (post-1.0 stability guarantees, released April 2026).** Colorless async/await (re-introduced in 0.16) lets us write straight-line request handlers that compile to event-loop dispatch.

### HTTP server foundation
- **`http.zig` (karlseguin/http.zig, MIT) — pure-Zig.** We use the `master` branch which explicitly targets Zig 0.16. We drive routing ourselves via http.zig's `handle` takeover hook because AWS APIs encode the operation in the (host, path, method, query) tuple rather than in a static URL pattern.
- **Why not `zap`:** zap's latest tag (v0.11.0) targets Zig 0.15.1, not 0.16. Its raw req/s advantage doesn't move our budgets, so we trade it for fewer moving parts and no C interop. Revisit if perf budgets are ever breached on the listener.
- **Why not `std.http.Server`:** HTTP/1.1 only, known keep-alive edge cases, library-grade rather than production-grade for hot serving paths.

### TLS
- **`boring_tls`** (Thomvanoorschot/boring_tls) — Zig wrapper over BoringSSL.
- TLS is **optional in v1** (off by default). HTTP-only listener is fine for local dev. TLS becomes mandatory when we add services that fail without it (e.g., presigned-URL-over-HTTPS workflows that test in browsers).

### Parsing
- **XML emit:** hand-rolled in `src/wire/xml.zig`. `nektro/zig-xml` is parser-only and S3 responses use a small, fixed shape (no namespaces beyond a single `xmlns`, no mixed content). The emitter is ~100 LOC with full attribute/text escaping.
- **XML parse:** deferred until we hit a request body that needs it (multipart `CompleteMultipartUpload`, `DeleteObjects`, `PutBucketCors`, etc., all post-M0). At that point we'll either fold in `zig-xml` or extend our hand-rolled module.
- **JSON:** `std.json` (stable, parseFromSlice-into-struct). Not used in S3 but on deck for SQS/DynamoDB.
- **Multipart/form-data, URL & query:** built into `http.zig`.

### Crypto / SigV4
- **`std.crypto.hash.sha2` + `std.crypto.auth.hmac`** for primitives.
- **SigV4 verifier:** port and adapt from `elerch/aws-sdk-for-zig`'s `aws_signing.zig` (~500 LOC). The upstream is tightly coupled to that SDK's request flow; the M2 task extracts the canonical-request / string-to-sign / signing-key logic into a standalone `auth/sigv4` module so future services (SQS, DynamoDB, Lambda) share it without modification.

### Code generation
- **Build-time codegen** (Zig `build.zig` step) that ingests the Smithy JSON model for S3 (sourced from the AWS SDK Smithy model mirror or `awslabs/smithy`) and emits:
  - Operation enum + request/response struct types.
  - Header/query/path binding tables.
  - Error shape registry (so we can emit exact AWS error codes and HTTP statuses).
- **Comptime** is used for in-place optimizations (e.g., perfect-hash route tables), not for whole-schema parsing.

### Storage
- **Filesystem-backed by default.** Object data lives under `<data-dir>/<profile>/s3/<bucket>/<key-hash>/data` per the on-disk layout in §9.
- **Per-object JSON metadata** in a sidecar (`meta.json`) next to each object body. Chosen for inspectability (`cat meta.json` answers debugging questions in one command), zero external dependencies, and atomic per-object writes. The convenience win matters for a dev/test emulator; we accept the linear listing cost and offset it with…
- **In-memory sorted listing index** built by scanning bucket directories at startup. `ListObjects` / `ListObjectsV2` resolve against this index instead of walking the filesystem. Mutations on PUT/DELETE update the index incrementally. Promote to SQLite later if profiling ever shows listing is the bottleneck — unlikely for local dev workloads.
- **Wipe-clean runs** pass `--data-dir <tmp>` and let the OS reap the directory on exit. (The pre-M7 `--ephemeral` in-memory backend was dropped — see §17.)
- **`io_uring` on Linux** via `Cloudef/zig-aio` for hot read/write paths; standard POSIX file I/O on macOS via kqueue.

---

## 7. Architecture Overview

```
                     ┌────────────────────────────────────┐
                     │              CLI / Main             │
                     │   (flags, config, profile select)   │
                     └────────────────┬────────────────────┘
                                      │
                     ┌────────────────▼────────────────────┐
                     │           Listener (zap)             │
                     │   HTTP/1.1, keep-alive, chunked,     │
                     │   virtual-host & path-style routing  │
                     └────────────────┬────────────────────┘
                                      │
                     ┌────────────────▼────────────────────┐
                     │         Auth / SigV4 verifier        │
                     │   (presigned URLs handled here too)  │
                     └────────────────┬────────────────────┘
                                      │
                     ┌────────────────▼────────────────────┐
                     │       Service router (codegen)       │
                     │   Smithy-derived dispatch tables     │
                     └────────────────┬────────────────────┘
                                      │
                     ┌────────────────▼────────────────────┐
                     │      Service impl: s3 (semantics)    │
                     │  - bucket lifecycle                  │
                     │  - object ops (GET/PUT/DEL/HEAD/COPY)│
                     │  - LIST (v1 + v2)                    │
                     │  - multipart                         │
                     │  - conditional requests              │
                     └────────────────┬────────────────────┘
                                      │
                     ┌────────────────▼────────────────────┐
                     │            Storage backend          │
                     │                fs                    │
                     └─────────────────────────────────────┘
```

Layers above the service impl are **service-agnostic** so adding SQS, DynamoDB, etc. only requires a new `services/<name>/` module plus its Smithy model.

---

## 8. v1 Scope — S3 Surface

### IN (v1 must-have)
- **Buckets:** CreateBucket, DeleteBucket, HeadBucket, ListBuckets.
- **Objects:** PutObject, GetObject, HeadObject, DeleteObject, DeleteObjects (batch), CopyObject.
- **Listing:** ListObjects (v1), ListObjectsV2.
- **Multipart upload:** CreateMultipartUpload, UploadPart, UploadPartCopy, CompleteMultipartUpload, AbortMultipartUpload, ListMultipartUploads, ListParts.
- **Conditional requests (AWS-exact split):** all four (`If-Match`, `If-None-Match`, `If-Modified-Since`, `If-Unmodified-Since`) on `GET`/`HEAD`; `If-Match` and `If-None-Match` (incl. `*`) on `PUT`; `x-amz-copy-source-if-{match,none-match,modified-since,unmodified-since}` on `CopyObject`. `DELETE` accepts the headers but does not enforce them, matching AWS. CompleteMultipartUpload conditional writes land with multipart.
- **Range requests** with **correct `Accept-Ranges: bytes` header** (the spot LocalStack gets wrong).
- **Authentication:** SigV4 verification on every authenticated request. Anonymous access for public-acl objects.
- **Presigned URLs:** SigV4 query-string signing verified end-to-end, **including with custom headers and query params** (the spot LocalStack gets wrong).
- **Path-style and virtual-hosted-style** addressing.
- **Correct error wire format** for the supported operations: AWS error codes, HTTP statuses, XML error body shape, `x-amz-request-id`, `x-amz-id-2`.

### OUT of v1 (deferred to later versions)
- Versioning, object lock, replication.
- ACLs and bucket policies (we accept and ignore; we return AccessDenied only when SigV4 fails).
- Lifecycle rules, intelligent-tiering, restore.
- CORS, static website hosting, transfer acceleration.
- Event notifications (S3 → SNS/SQS/Lambda). *Requires those services to exist first.*
- Select, inventory, analytics.
- Server-side encryption (SSE-S3, SSE-KMS, SSE-C). Accept headers, do not enforce.
- Object tagging (accept and ignore in v1; full support in v1.1).

### `SUPPORT.md` discipline
We will ship a `SUPPORT.md` that lists *every* S3 operation and one of: **supported**, **stub (accepted, no-op)**, **unsupported (501)**, **deferred**. Users should never be surprised by what we silently swallow.

---

## 9. Storage Model (default backend)

```
<data-dir>/
  profiles/
    <profile>/
      s3/
        buckets.json              # registry: name, region, created, attrs
        <bucket>/
          objects/
            <key-hash>/
              data                # raw object bytes
              meta.json           # content-type, etag, mtime, headers, etc.
          multipart/
            <upload-id>/
              part-00001
              part-00002
              ...
              meta.json
```

- **Object keys** are stored as raw bytes; the on-disk filename is `sha256(key)` to sidestep filesystem path constraints (S3 allows characters that `ext4`/`apfs` reject and supports keys up to 1024 bytes).
- **ETag** is computed lazily on the first read and cached in `meta.json`. For multipart, ETag is `<md5-of-concatenated-part-md5s>-<part-count>` to match AWS.
- **Atomic writes** via `O_TMPFILE` + `linkat` on Linux, `rename(2)` on macOS.
- **Wipe-clean runs**: pass `--data-dir <tmp>` (e.g. `mktemp -d`). The OS reaps the directory on exit; no in-memory backend.

---

## 10. CLI & Configuration

### Default invocation
```
$ nanostack
listening on http://127.0.0.1:4566
profile: default  | data: ~/.nanostack/profiles/default
```

### Flags (v1)
```
--port <n>            default 4566 (LocalStack-compatible)
--bind <addr>         default 127.0.0.1
--data-dir <path>     default ~/.nanostack — pass a tmpdir for a wipe-clean run
--profile <name>      default "default"
--services <list>     default "s3" (only one for v1, future-proofs the flag)
--log-level <lvl>     trace|debug|info|warn|error
--access-key <key>    accepted SigV4 access key id (default: "test")
--secret-key <key>    accepted SigV4 secret (default: "test")
--region <r>          default "us-east-1"
```

### Config file (optional)
- `~/.nanostack/config.toml` — same keys as flags, flags override file.

---

## 11. Conformance & Testing Strategy

This is the part that separates "another emulator" from "the accurate one."

### Three test tiers

1. **Unit tests (in-tree, Zig):** parser, signing, route dispatch, storage backends.
2. **Conformance tests (out-of-tree, polyglot):**
   - **Python suite** using `boto3`.
   - **JS suite** using `@aws-sdk/client-s3`.
   - Each suite is a matrix of `(operation × scenario)` — happy path + at least three error paths per operation.
   - The *same matrix* runs against both nanostack and a real AWS account (or LocalStack) on a nightly schedule, so we can flag drift.
3. **Fuzz tests:** quickly randomized PUT/GET/HEAD/LIST sequences against both backends, asserting equivalence with a reference implementation.

### Per-PR CI gates
- Unit tests pass.
- Full Python (boto3) + JS conformance suite passes.
- No regression in cold-start budget (500 ms) or warm p99 GET latency budget (5 ms for ≤1 MB objects).

### Public scorecard
We publish a Markdown table at the repo root, updated on every release, showing pass/fail per operation per SDK. This is the artifact that proves the accuracy claim.

---

## 12. Performance Targets (v1)

All numbers are measured by the bench harness in `bench/driver.py` driving signed AWS SDK calls (boto3) against `ReleaseFast`-built nanostack. We deliberately use the AWS SDK rather than `wrk`/`bombardier` so the budget reflects what users actually experience — SigV4 cost included.

| Metric | Budget | How measured |
|---|---|---|
| Cold start to bound listener | ≤ 500 ms | `time nanostack --self-test-ready` (real bind, then exit); median of 5 |
| Idle RSS (5 s after start) | ≤ 30 MB | `/proc/<pid>/status` `VmRSS`; max of 3 samples |
| Binary size (stripped) | ≤ 20 MB | `os.Stat` after `zig build -Doptimize=ReleaseFast -Dstrip=true` |
| Wipe-restart | ≤ 500 ms | kill + respawn, time to first TCP accept; median of 5. fs walks `objects/*/meta.json` to rebuild its key index. |
| Warm p50 PutObject (1 KB) | ≤ 3 ms | 10 000 sequential PutObject ops via boto3. Cost reflects two atomic writes (`data` + `meta.json`) per PUT. |
| Warm p99 PutObject (1 KB) | ≤ 10 ms | 99th percentile of the same series. Budget bumped from 5 ms in 2026-05-14 when the harness switched to boto3 (SDK round-trip dominates). |
| Warm p99 GetObject (≤ 1 MB) | ≤ 5 ms | 10 000 sequential GetObject ops |
| PutObject throughput (1 KB, 32 concurrent) | ≥ 150 req/s | 32 threads for 5 s, unique keys per worker. Budget lowered from 500 in 2026-05-14 when the harness switched to boto3 — Python's GIL serialises SigV4 across threads, so the driver caps below the server's actual capacity. |
| Multipart upload p99 (5 × 5 MiB concurrent) | ≤ 500 ms | 20 iterations of {InitiateMPU → 5 concurrent UploadParts of 5 MiB → CompleteMPU} |

Numbers are budgets, not promises — but a regression past any of them in CI fails the build. Each new milestone may add rows; an existing row only loosens with a one-liner justification recorded in the commit message.

### Methodology note

The original PRD draft cited `≥ 50 000 req/s` for PutObject throughput, calibrated against `wrk` against raw HTTP. We deliberately use SDK-driven measurement because that's the load shape real users put on nanostack. SDK loads max out roughly an order of magnitude lower because every request pays SigV4 verification cost on every call. The current targets are honest about that.

---

## 13. Observability

- **Structured logs** to stderr, JSON line format, configurable level.
- **Request log** at debug level: method, path, signed-headers, content-length, response status, duration.
- **`/_/health`** endpoint (under reserved prefix to avoid bucket-name collision).
- **`/_/metrics`** Prometheus endpoint (post-v1; v1 just exposes counters via `/_/stats` JSON).

---

## 14. Release Plan & Milestones

We will work in tight, verifiable cuts. Each milestone ends with a green CI run plus a benchmark report.

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 — Skeleton** | Repo, `build.zig`, zap "hello", lint, CI scaffolding, conformance harness shell that runs `boto3` against the server | Server accepts a request and returns 501 with correct XML body |
| **M1 — Buckets** | CreateBucket, DeleteBucket, HeadBucket, ListBuckets + filesystem backend | Python (boto3) + JS conformance suites green for these 4 ops |
| **M2 — SigV4** | Full SigV4 verifier, both header-auth and presigned URLs, anonymous fall-through. Custom-header presigned URLs work (LocalStack's known weak spot) | Conformance includes 6+ presigned-URL scenarios; all green |
| **M3 — Objects (basic)** | PutObject, GetObject, HeadObject, DeleteObject, DeleteObjects | Conformance green; range requests return correct headers |
| **M4 — Listing** | ListObjects (v1), ListObjectsV2, pagination, prefix/delimiter | Conformance green; large-bucket listing benchmarked |
| **M5 — Copy + conditional** | CopyObject, all conditional headers on GET/HEAD/PUT/COPY/DELETE | Conformance green |
| **M6 — Multipart** | All 7 multipart operations, conditional writes on CompleteMultipartUpload | Conformance green; concurrent-part upload bench |
| **M7 — v1.0** | Polish, docs, `SUPPORT.md`, scorecard, brew/release tarballs | Public release; LocalStack-comparable conformance posted |

Time estimate end-to-end: **~6 weeks** with focused effort, assuming the foundation work in M0–M2 lands clean.

---

## 15. Roadmap — state of the project (2026-05-18, post-v0.4.2)

The original §15 ordering (S3 v1.1 → SQS → DDB → Lambda) anchored against pre-v0.1 scope. As of v0.3.1, three services have shipped — most of the original v1.x roadmap is already done. This section is rewritten as a live state-of-the-world.

### Where each service stands

**S3 — comprehensive.** 68/107 Smithy ops. v1 must-have done (M1–M14, plus the v1.1 trio of versioning + tagging + ACL/policy/PAB enforcement and M12 Object Lock + WORM enforcement). M11 bucket configurations (CORS / encryption / lifecycle / notification / website) are **accept-store-roundtrip only** — rules never expire, no actual cipher, events never fire, website-mode requests not served. ~39 deferred ops (metrics / inventory / analytics CRUDs, S3 Express, Object Lambda, Select, BitTorrent, bucket metadata tables) are explicitly post-v1 — not on the roadmap unless a user files a real gap.

**DynamoDB — comprehensive.** 18 base ops + DynamoDBStreams sub-service + TTL sweeper + PartiQL (ExecuteStatement / ExecuteTransaction / BatchExecuteStatement) + Backups (5 ops) + PITR (3 ops). Imports/Exports + Global Tables + DAX are out of scope. Parallel scan (`TotalSegments > 1`) returns ValidationException.

**SQS — feature-complete + fully enforced.** 23 ops + FIFO + cold-start safety + retention sweeper + Queue Policy enforcement (v0.3.3). The authz cascade is `--no-auth` → allow / account-scoped → require non-anonymous / queue-scoped → owner-implicit-allow / policy evaluation (default-deny on no_match). Anonymous requests with a `Principal: "*"` policy work end-to-end. Cross-account principals are out of scope (SigV4 only verifies against the configured `--access-key`).

### Cross-service wiring — PROVEN (v0.3.4)

**S3 → SQS event notifications** landed in v0.3.4. `PutBucketNotificationConfiguration` QueueConfiguration entries now fire on PutObject / CopyObject / CompleteMultipartUpload / DeleteObject / DeleteObjects, with filter rule (prefix + suffix) + wildcard event matcher support. The canonical local-dev serverless workflow (upload object → message in queue → worker picks up) works end-to-end.

The dispatcher pattern (Context-threaded optional backend, single dispatch entry point per S3 op) is reusable for the next two wirings: SNS (target == .topic) and Lambda (target == .lambda) just need additional branches. DDB Streams → SQS would mirror the same shape.

**Still not wired**: S3 → SNS, S3 → Lambda (services don't exist yet), DDB Streams → SQS.

### Recommended trajectory toward v1.0

| Version | Scope | Why this order |
|---|---|---|
| ~~**v0.3.2 — SQS robustness**~~ | ~~Cold-start message rehydration; MessageRetentionPeriod sweeper; 6 unrouted ops (`AddPermission`/`RemovePermission`/`ListDeadLetterSourceQueues`/MessageMoveTask trio).~~ | **Shipped 2026-05-18.** Closes SUPPORT.md ↔ behaviour drift; lands all unrouted ops. Queue Policy enforcement deferred to v0.3.3. |
| ~~**v0.3.3 — Queue Policy enforcement**~~ | ~~Wire `policy_eval.zig` into a new `src/services/sqs/authz.zig` hook; SQS action map; thread Principal through the SQS service context.~~ | **Shipped 2026-05-18.** Last SQS gap closed. After this, SQS is feature-complete + fully enforced. |
| ~~**v0.3.4 — S3 → SQS event notifications**~~ | ~~Wire `PutBucketNotificationConfiguration` QueueConfiguration entries to actually fire on PutObject / DeleteObject / Copy / CompleteMultipartUpload, with prefix/suffix filter eval and AWS-format event envelope.~~ | **Shipped 2026-05-18.** The strategic unlock — first cross-service wiring proven. Canonical local-dev serverless workflow (upload → queue → worker) works end-to-end. |
| ~~**v0.4.0 — SNS**~~ | ~~17 ops (topic CRUD + subscriptions + Publish/PublishBatch + tags). SNS → SQS fan-out + S3 → SNS dispatch. Query+XML wire protocol layer added.~~ | **Shipped 2026-05-18.** First minor since v0.3.0 SQS. Multi-hop S3 → SNS → SQS works end-to-end. |
| ~~**v0.4.1 — SNS robustness**~~ | ~~Tags persistence across restart; `AddPermission` / `RemovePermission` (Policy mutation, accept-store-roundtrip); per-entry `MessageAttributes` on `PublishBatch`; `FilterPolicy` evaluated at publish time (exact string-array shapes).~~ | **Shipped 2026-05-18.** Closes the four divergences flagged in v0.4.0's SUPPORT.md. Topic Policy enforcement deferred to v0.4.2 (same v0.3.2 → v0.3.3 SQS trajectory). |
| ~~**v0.4.2 — SNS Topic Policy enforcement**~~ | ~~Wire `policy_eval.zig` into a new `src/services/sns/authz.zig` hook; SNS action map; thread Principal through the SNS service context.~~ | **Shipped 2026-05-18.** Mirrors v0.3.3 SQS verbatim. After this, SNS is feature-complete + enforced modulo FIFO. |
| **v0.5.0 — Lambda** | Function CRUD + Invoke + S3 / SQS / DDB-Streams event-source mappings. Likely a sidecar-process execution model (we don't host an in-Zig runtime). | The big multi-service hop. Highest payoff for the v1.0 claim. (Minor.) |
| **v1.0.0 — Polish + multi-profile + bench** | Multi-profile state isolation (deferred from v1 per §17a); end-to-end performance pass against the broader surface; documented "production local-dev surface". | "Curated multi-service surface workflow-ready." Stabilization, not new features. (Major.) |

**Deferred indefinitely:** TLS (still §17 open question; revisit if browser-driven presigned-URL workflows surface user demand), Windows (post-v1 per §2 non-goals), FIFO high-throughput mode, S3 Express / Object Lambda / Select, EventBridge, Kinesis, IAM, AWS Console emulation.

---

## 16. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Zig ecosystem churn** in third-party libs (zap, zig-xml, zig-aio) | Medium | Medium | Pin all deps; fork on critical regressions; minimize external surface |
| **SigV4 edge cases** burn weeks (header canonicalization is famously fiddly) | High | Medium | Port from `aws-sdk-for-zig` rather than write from scratch; conformance tests in M2 cover known pitfalls |
| **XML wire-format drift** vs real AWS | Medium | High | Generate from Smithy where possible; conformance suite catches drift; nightly diff vs real AWS for canary ops |
| **Filesystem semantics differ Linux ↔ macOS** (atomic rename, fsync) | Medium | Medium | Backend tests run on both in CI from M1 |
| **Performance budget breached late** | Medium | Medium | Bench every milestone; no merging if budget breached |
| **Smithy model changes mid-project** | Low | Low | Pin model version per release; bump deliberately |
| **The wedge isn't real** (users prefer LocalStack despite the cost) | Medium | High | Land M2 (presigned URLs) early to validate the "more accurate" story; publish scorecard publicly |

---

## 17. Open Questions

- **TLS in v1 or v1.1?** Currently planned for post-v1. If early users need it for browser-driven presigned URL workflows, we accelerate.

## 17a. Decisions Locked

- **Metadata format (2026-05-12):** per-object JSON sidecar (`meta.json`) + in-memory sorted listing index built at startup. Resolves the §9 / §17 open question. Chosen for inspectability and zero deps; offsets listing cost with the index. See §6 / §9.
- **Multi-profile state isolation (2026-05-12):** deferred to v1.1. v1 ships single-profile-only. The `--profile` flag still exists and is honoured for the data-dir path so that v1.1 can layer multi-profile in without breaking existing users.
- **In-memory backend dropped (2026-05-13):** the pre-M7 `--ephemeral` mode is removed. Reasons: every new storage operation had to be implemented twice (M6 alone added a 200+ LOC `MultipartState` mirror); the mem-resident part buffers crashed dev environments under realistic multipart load; the fs backend already covers the "wipe-clean" use case via `--data-dir <tmp>`. Old M7 ("Ephemeral mode") vacated from §14; old M8 becomes the new M7.
- **AWS error catalog: hand-maintained (2026-05-13):** errors live in `src/wire/errors.zig` as a small hand-written enum + table. The Smithy-overlay alternative is deferred indefinitely; the catalog is short enough (≈20 codes covering the v1 surface) that hand-maintained is fine, and the Smithy approach would add a build-time codegen step we don't currently need.
- **Versioning scheme (2026-05-13):** project-specific, not strict SemVer. `1.x.x` is reserved for "the curated multi-service surface needed for real workflows is implemented". `x.1.x` ships when one AWS service is fully implemented against the real-AWS surface (not just the v1 subset in §8). `x.x.1` is bumped for each significant pinned cut. M7's first release tags as **`v0.0.1`**. The PRD §14 label "M7 — v1.0" refers to the first project surface scope (19 S3 ops), independent of the semver tag. Documented in `CHANGELOG.md`.

---

## 18. Glossary

- **SigV4** — AWS Signature Version 4 request signing.
- **Smithy** — AWS's IDL for service models; the source of truth for AWS APIs.
- **Conformance suite** — out-of-tree polyglot test suite that asserts nanostack behaves like real AWS for a defined matrix of operations.
- **Profile** — isolated state namespace within a running nanostack instance; corresponds to an `~/.nanostack/profiles/<name>` directory.

---

*End of PRD v0.2 — last revised 2026-05-13.*
