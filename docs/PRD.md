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
| **Accurate** | Every supported S3 operation has a **conformance test** that runs the official AWS Go SDK and AWS JS SDK against nanostack with assertions on response body, headers, status, and error codes. Behaviors not yet covered are explicitly listed in `SUPPORT.md` — we do not over-promise. |
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
- **Build-time codegen** (Zig `build.zig` step) that ingests the Smithy JSON model for S3 (sourced from AWS Go SDK v2 mirror or `awslabs/smithy`) and emits:
  - Operation enum + request/response struct types.
  - Header/query/path binding tables.
  - Error shape registry (so we can emit exact AWS error codes and HTTP statuses).
- **Comptime** is used for in-place optimizations (e.g., perfect-hash route tables), not for whole-schema parsing.

### Storage
- **Filesystem-backed by default.** Object data lives under `<data-dir>/<profile>/s3/<bucket>/<key-hash>/data` per the on-disk layout in §9.
- **Per-object JSON metadata** in a sidecar (`meta.json`) next to each object body. Chosen for inspectability (`cat meta.json` answers debugging questions in one command), zero external dependencies, and atomic per-object writes. The convenience win matters for a dev/test emulator; we accept the linear listing cost and offset it with…
- **In-memory sorted listing index** built by scanning bucket directories at startup. `ListObjects` / `ListObjectsV2` resolve against this index instead of walking the filesystem. Mutations on PUT/DELETE update the index incrementally. Promote to SQLite later if profiling ever shows listing is the bottleneck — unlikely for local dev workloads.
- **`--ephemeral` flag** runs entirely in a tmpfs-style memory backend; the process owns its lifetime.
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
                     │     fs (default) | mem (--ephemeral) │
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
- **Conditional requests:** If-Match, If-None-Match, If-Modified-Since, If-Unmodified-Since on GET/HEAD/PUT/COPY/DELETE. CompleteMultipartUpload conditional writes.
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
- **`--ephemeral`** swaps the backend out entirely for an in-memory `HashMap(Key, Object)` keyed structure with the same interface.

---

## 10. CLI & Configuration

### Default invocation
```
$ nanostack
listening on http://127.0.0.1:4566
profile: default  | data: ~/.nanostack/profiles/default  | ephemeral: false
```

### Flags (v1)
```
--port <n>            default 4566 (LocalStack-compatible)
--bind <addr>         default 127.0.0.1
--data-dir <path>     default ~/.nanostack
--profile <name>      default "default"
--ephemeral           wipe-clean in-memory mode
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
   - **Go suite** using `aws-sdk-go-v2`.
   - **JS suite** using `@aws-sdk/client-s3`.
   - **Python suite** using `boto3`.
   - Each suite is a matrix of `(operation × scenario)` — happy path + at least three error paths per operation.
   - The *same matrix* runs against both nanostack and a real AWS account (or LocalStack) on a nightly schedule, so we can flag drift.
3. **Fuzz tests:** quickly randomized PUT/GET/HEAD/LIST sequences against both backends, asserting equivalence with a reference implementation.

### Per-PR CI gates
- Unit tests pass.
- Full Go + JS conformance suite passes.
- No regression in cold-start budget (500 ms) or warm p99 GET latency budget (5 ms for ≤1 MB objects).

### Public scorecard
We publish a Markdown table at the repo root, updated on every release, showing pass/fail per operation per SDK. This is the artifact that proves the accuracy claim.

---

## 12. Performance Targets (v1)

All numbers are measured by the bench harness in `bench/driver/` driving signed AWS SDK calls (Go SDK v2) against `ReleaseFast`-built nanostack. We deliberately use the AWS SDK rather than `wrk`/`bombardier` so the budget reflects what users actually experience — SigV4 cost included.

Two storage backends, two budget columns where the physics differ:

| Metric | mem | fs | How measured |
|---|---|---|---|
| Cold start to bound listener | ≤ 500 ms | ≤ 500 ms | `time nanostack --self-test-ready` (real bind, then exit); median of 5 |
| Idle RSS (5 s after start) | ≤ 30 MB | ≤ 30 MB | `/proc/<pid>/status` `VmRSS`; max of 3 samples |
| Binary size (stripped) | ≤ 20 MB | ≤ 20 MB | `os.Stat` after `zig build -Doptimize=ReleaseFast -Dstrip=true` |
| Wipe-restart | ≤ 100 ms | ≤ 500 ms | kill + respawn, time to first TCP accept; median of 5. fs walks `objects/*/meta.json` to rebuild its key index. |
| Warm p50 PutObject (1 KB) | ≤ 1 ms | ≤ 3 ms | 10 000 sequential PutObject ops via aws-sdk-go-v2. fs slower because each PUT atomically writes both `data` and `meta.json`. |
| Warm p99 PutObject (1 KB) | ≤ 5 ms | ≤ 5 ms | 99th percentile of the same series |
| Warm p99 GetObject (≤ 1 MB) | ≤ 5 ms | ≤ 5 ms | 10 000 sequential GetObject ops |
| PutObject throughput (1 KB, 32 concurrent) | ≥ 5 000 req/s | ≥ 500 req/s | 32 goroutines for 5 s, unique keys per worker |

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
| **M0 — Skeleton** | Repo, `build.zig`, zap "hello", lint, CI scaffolding, conformance harness shell that runs `aws-sdk-go-v2` against the server | Server accepts a request and returns 501 with correct XML body |
| **M1 — Buckets** | CreateBucket, DeleteBucket, HeadBucket, ListBuckets + filesystem backend | Go + JS conformance suites green for these 4 ops |
| **M2 — SigV4** | Full SigV4 verifier, both header-auth and presigned URLs, anonymous fall-through. Custom-header presigned URLs work (LocalStack's known weak spot) | Conformance includes 6+ presigned-URL scenarios; all green |
| **M3 — Objects (basic)** | PutObject, GetObject, HeadObject, DeleteObject, DeleteObjects | Conformance green; range requests return correct headers |
| **M4 — Listing** | ListObjects (v1), ListObjectsV2, pagination, prefix/delimiter | Conformance green; large-bucket listing benchmarked |
| **M5 — Copy + conditional** | CopyObject, all conditional headers on GET/HEAD/PUT/COPY/DELETE | Conformance green |
| **M6 — Multipart** | All 7 multipart operations, conditional writes on CompleteMultipartUpload | Conformance green; concurrent-part upload bench |
| **M7 — Ephemeral mode** | `--ephemeral` backend, full conformance green against both backends | Same suite passes against both backends |
| **M8 — v1.0** | Polish, docs, `SUPPORT.md`, scorecard, brew/release tarballs | Public release; LocalStack-comparable conformance posted |

Time estimate end-to-end: **~6 weeks** with focused effort, assuming the foundation work in M0–M2 lands clean.

---

## 15. Post-v1 Roadmap (directional only — no commitments)

The order is informed by both *user demand* and *how cleanly the service shares infrastructure with what we already have*.

1. **v1.1 — S3 versioning + tagging + ACLs/policies.** Closes the biggest S3 gaps left by v1.
2. **v1.2 — SQS.** Small surface, exercises long-polling and request cancellation. Good second service to validate the abstractions.
3. **v1.3 — DynamoDB.** The other foundational service; pulls in conditional expressions (real parser work, but worth it).
4. **v1.4 — Lambda + S3 → Lambda event notifications.** The first cross-service wiring. Forces us to design the event bus abstraction.
5. **v2 — Windows support.** Requires either swapping the HTTP server (likely `http.zig`) or contributing Windows support upstream to zap.

Anything beyond that (SNS, EventBridge, Kinesis, IAM) is reconsidered after v1.4 lands.

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
- **AWS error catalog overlay:** we extract from Smithy at build time, but some legacy/special errors aren't in the Smithy model. Decide between hard-coding the deltas vs maintaining a small `errors.zig` overlay file.

## 17a. Decisions Locked

- **Metadata format (2026-05-12):** per-object JSON sidecar (`meta.json`) + in-memory sorted listing index built at startup. Resolves the §9 / §17 open question. Chosen for inspectability and zero deps; offsets listing cost with the index. See §6 / §9.
- **Multi-profile state isolation (2026-05-12):** deferred to v1.1. v1 ships single-profile-only. The `--profile` flag still exists and is honoured for the data-dir path so that v1.1 can layer multi-profile in without breaking existing users.

---

## 18. Glossary

- **SigV4** — AWS Signature Version 4 request signing.
- **Smithy** — AWS's IDL for service models; the source of truth for AWS APIs.
- **Conformance suite** — out-of-tree polyglot test suite that asserts nanostack behaves like real AWS for a defined matrix of operations.
- **Profile** — isolated state namespace within a running nanostack instance; corresponds to an `~/.nanostack/profiles/<name>` directory.

---

*End of PRD v0.1.*
