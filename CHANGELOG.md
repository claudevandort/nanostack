# Changelog

All notable changes to nanostack are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Versioning scheme

This project does **not** use strict [SemVer](https://semver.org/) semantics. We use a project-specific mapping:

- **Patch (`x.x.1`)** — a significant pinned cut of work; the working baseline as of a point in time.
- **Minor (`x.1.x`)** — one AWS service fully implemented against the real-AWS surface (not just the curated v1 subset).
- **Major (`1.x.x`)** — the curated multi-service surface needed for real workflows is implemented.

We are very far from `1.0.0`. Anything below it should be treated as "useful but not API-stable".

---

## [0.0.1] — 2026-05-13

First pinned release of the nanostack S3 v1 surface. 19 operations, full SigV4 (header auth + presigned URLs incl. custom headers), conditional headers, multipart upload. Green Go + JS conformance against both backends at CI time (now collapsed to single fs backend post-cleanup).

### Added — S3 operations
- **M1 — Buckets:** CreateBucket, DeleteBucket, HeadBucket, ListBuckets. Filesystem backend with per-object JSON sidecar metadata + in-memory sorted listing index.
- **M2 — SigV4:** Header auth and presigned URLs. **Custom-header presigned URLs are first-class** (LocalStack's known weak point). `--no-auth` opt-out for curl-friendly local debugging.
- **M2.5 — Perf gate:** PRD §12 budgets enforced in CI; new metrics added per milestone.
- **M3 — Objects:** PutObject, GetObject, HeadObject, DeleteObject, DeleteObjects (incl. Quiet mode). Range requests with `Accept-Ranges: bytes` on every response. `x-amz-content-sha256` body verification. `x-amz-meta-*` user-metadata passthrough.
- **M4 — Listing:** ListObjects v1 + ListObjectsV2. `prefix`, `delimiter` (with `CommonPrefixes` rollup), `marker`/`continuation-token`, `max-keys`, `start-after`, `fetch-owner`, `encoding-type=url`.
- **M5 — CopyObject + conditional headers:** CopyObject with `x-amz-metadata-directive=COPY|REPLACE` and `x-amz-copy-source-if-*`. AWS-exact conditional-header split (GET/HEAD honour all four; PUT honours If-Match/If-None-Match; CopyObject honours copy-source-if-*). HTTP-date parser (`src/http/date.zig`).
- **M6 — Multipart upload:** All seven operations (CreateMultipartUpload, UploadPart, UploadPartCopy, CompleteMultipartUpload, AbortMultipartUpload, ListMultipartUploads, ListParts). AWS-exact ETag format `md5(concat-binary-MD5s)-N`. 5 MiB min-part-size enforcement on non-final parts (`EntityTooSmall`). Conditional CompleteMultipartUpload. opaque 22-char base64-url upload IDs.

### Added — release plumbing (this commit)
- `--version` flag.
- `zig build release` step (cross-compile via `-Dtarget=…`).
- GitHub Releases workflow building four tarballs (`linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-aarch64`) with `SHA256SUMS`.
- Homebrew formula template (`release/nanostack.rb`) for `claudevandort/homebrew-nanostack`.
- `SCORECARD.md` listing the four documented points where nanostack is more accurate than LocalStack.
- `dependabot.yml`, issue + PR templates.

### Performance (dev machine, Linux, ReleaseFast + strip)
| Metric | Measured | Budget |
|---|---|---|
| Cold start | ~1.9 ms | 500 ms |
| Idle RSS | ~11.5 MB | 30 MB |
| Binary size | ~0.82 MB | 20 MB |
| Wipe-restart | ~175 ms | 500 ms |
| PutObject p50 (1 KB) | ~0.81 ms | 3 ms |
| PutObject p99 (1 KB) | ~1.29 ms | 5 ms |
| GetObject p99 | ~0.57 ms | 5 ms |
| PutObject throughput (32 workers) | ~1 760 req/s | ≥ 500 req/s |
| Multipart p99 (5 × 5 MiB) | ~156 ms | 500 ms |

### Notes
- The pre-M7 in-memory backend (`--ephemeral`) was removed (commit `0656161`). Tests and CI now use `--data-dir <tmp>` for wipe-clean runs.
- See [`SUPPORT.md`](SUPPORT.md) for the full operation matrix and the deferred-feature list.
- See [`SCORECARD.md`](SCORECARD.md) for the LocalStack-comparable accuracy claims.
- See [`docs/PRD.md`](docs/PRD.md) for the product spec, design decisions (§17a), and post-v1 roadmap (§15).
