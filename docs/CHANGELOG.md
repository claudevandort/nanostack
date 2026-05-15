# Changelog

All notable changes to nanostack are documented here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Versioning scheme

This project does **not** use strict [SemVer](https://semver.org/) semantics. We use a project-specific mapping:

- **Patch (`x.x.1`)** — a significant pinned cut of work; the working baseline as of a point in time.
- **Minor (`x.1.x`)** — one AWS service fully implemented against the real-AWS surface (not just the curated v1 subset).
- **Major (`1.x.x`)** — the curated multi-service surface needed for real workflows is implemented.

We are very far from `1.0.0`. Anything below it should be treated as "useful but not API-stable".

---

## [Unreleased]

### Changed
- **Conformance + bench harness ported from Go (`aws-sdk-go-v2`) to Python (`boto3`).** All 162 conformance tests translated 1:1 to pytest; `bench/driver.py` replaces the Go bench driver. Two perf-budget rows recalibrated for boto3's heavier SigV4 path: `put_object_p99_ms` 5 → 10 ms, `put_object_throughput_rps` 500 → 150 req/s. Server unchanged.
- **Wave 2 AWS-drift fixes (6 XML response-shape gaps in listing responses)**, tracked in [`SUPPORT.md` → Known drift](SUPPORT.md#known-drift--to-fix):
  - `ListMultipartUploads` now emits `<Initiator>` + `<Owner>` per `<Upload>` (persisted requester identity).
  - `ListObjectVersions` now emits `<Owner>` per `<Version>` and `<DeleteMarker>` entry.
  - All three list responses (objects, multipart uploads, versions) honour `encoding-type=url` — keys/prefixes/delimiter/marker fields are percent-encoded per RFC 3986 via new `wire/url_encode.zig`.
  - `ListMultipartUploads` + `ListObjects` (V1+V2) + `ListObjectVersions` emit `<Prefix>` and `<Delimiter>` unconditionally (even when empty), matching AWS exactly. `wire/xml.zig` now distinguishes `text = null` (self-close `<Foo/>`) from `text = ""` (paired `<Foo></Foo>`).
  - `GetObjectAttributes` now surfaces `Last-Modified` and `x-amz-delete-marker` HTTP headers.
  - `ListBuckets` now emits `<BucketRegion>` per `<Bucket>` (AWS 2023 addition).

- **Wave 1 AWS-drift fixes (5 status/error-code corrections on routed ops)**, tracked in [`SUPPORT.md` → Known drift](SUPPORT.md#known-drift--to-fix):
  - `CompleteMultipartUpload` on an unknown upload id now returns `404 NoSuchUpload` (was `400 InvalidPart`). New `storage.Error.InvalidPart` variant disambiguates etag-mismatch from upload-missing.
  - `PutBucketTagging` returns `204 No Content` (was `200`). `PutObjectTagging` stays at 200 per AWS docs.
  - HEAD on a delete marker now returns `405 Method Not Allowed` + `Allow: DELETE` (was `404 NoSuchKey`). GET remains `404`.
  - `x-amz-content-sha256` payload-hash mismatch returns the distinct `XAmzContentSHA256Mismatch` code (was collapsed onto `BadDigest`, the Content-MD5 code).
  - `DeleteObjects` now threads per-`<Object>` `<VersionId>` through to the storage call and echoes it back in `<Deleted>` (previously silently dropped, so versioned batch deletes always hit current).

### Removed
- `tests/conformance/go/` (38 .go files including helpers) and `bench/driver/` (Go module). `setup-go` removed from CI.

---

## [0.1.0] — 2026-05-14

**First minor release. S3 is functionally complete for local-dev use.**

Per the [versioning scheme](#versioning-scheme), minor releases mark "one AWS service fully implemented against the real-AWS surface." We meet this for *local dev emulator* purposes: 68 / 107 Smithy ops routed (63.6%), but **~99% of real dev workflows** covered. The remaining 39 ops are observability padding, distinct sub-services, or deprecated — none of them are observable in a local dev context.

### S3 milestones since v0.0.2

- **M11 — Bucket setup essentials** (`6211715`): CORS, Encryption, Lifecycle, Notifications, Website, GetObjectAttributes. 15 ops. Closes the "real setup script tries to call X after CreateBucket" gap.
- **M12 — Object Lock + retention + legal hold** (`34f53f7`): 6 ops with **real WORM enforcement** — first nanostack milestone where persisted state actually blocks deletes. GOVERNANCE/COMPLIANCE mode transitions, legal hold supersedes retention, bypass-governance honoured, CreateBucket auto-enables versioning on locked buckets.
- **M13 — Close the S3 dev-emulator surface** (`7877760`): GetBucketPolicyStatus (IsPublic heuristic), RestoreObject (flips the 501 sentinel to GetObjectTorrent), UpdateObjectEncryption (per-version SSE), Put/Get/DeleteBucketReplication. 6 ops.

### Operation coverage

68 routed / 107 Smithy operations. See [`COVERAGE.md`](COVERAGE.md) for the table and [`SUPPORT.md`](SUPPORT.md) for the categorised "post-v0.1.0 deferred" list (~39 ops split into observability padding, niche, and distinct sub-services).

### Conformance + perf gate

Every CI run (Ubuntu + macOS) executes:
- Full Zig unit suite (~316 tests).
- Full Go conformance (~117 tests) at port 14566.
- Full JS conformance (51 tests) at port 14566.
- Perf gate from PRD §12 (cold start, idle RSS, binary size, PUT/GET p50/p99, throughput, multipart).

### Notes
- The pre-M7 in-memory backend stays removed; everything uses `--data-dir` (pass a tmpdir for wipe-clean runs).
- The Object Lock WORM enforcement (M12) is a documented departure from the M10/M11 "accept-store-only" pattern — see SUPPORT.md.
- Per the assessment in the project notes, the next high-leverage move is **a second AWS service** (DynamoDB / SQS / IAM / SNS). Padding the S3 number with M14-class observability CRUDs has diminishing returns for a local dev emulator.

## [0.0.2] — 2026-05-14

Second pinned cut. Closes the **v1.1 wave**: bucket versioning, S3 tagging, and ACLs/policies/ownership/public-access-block (accept-store-roundtrip). Full Go + JS conformance green on every CI run; perf gate unchanged.

### Added — S3 operations
- **M8 — Versioning** (`ac23d4d`): PutBucketVersioning, GetBucketVersioning, ListObjectVersions. Per-object versionId on PUT/Copy/CompleteMPU. GET/HEAD/DELETE `?versionId=X`. Delete markers (`x-amz-delete-marker: true`, removable by versionId). Multipart-ETag `<md5>-N` survives versioned writes.
- **M9 — Tagging** (`c251930`): 6 ops (Put/Get/Delete on bucket and object). Inline `x-amz-tagging` header on PutObject / CopyObject / CreateMultipartUpload. `x-amz-tagging-directive: COPY|REPLACE` on CopyObject. `x-amz-tagging-count` response header on Get/HeadObject. Per-version object tag sets. AWS-strict validation (max 10 tags; key 1–128, value 0–256; alphabet `[a-zA-Z0-9 +\-=._:/@]`; no duplicates; no `aws:` prefix). `NoSuchTagSet` on untagged bucket; empty `<TagSet/>` on untagged object — both AWS-exact.
- **M10 — ACLs + bucket policies + ownership + public access block** (`85c1f45`): 13 ops covering ACL Put/Get on bucket and object; bucket policy Put/Get/Delete; ownership controls Put/Get/Delete; public access block Put/Get/Delete. Inline `x-amz-acl` canned header on PutObject / CopyObject / CreateMultipartUpload. Full `x-amz-grant-*` header pass-through folded into the persisted AccessControlPolicy. Per-version object ACLs. Synthesized default Owner FULL_CONTROL on untouched buckets/objects. `AccessControlListNotSupported` (400) when ACL Put issued under `BucketOwnerEnforced`. `NoSuchBucketPolicy` / `OwnershipControlsNotFoundError` / `NoSuchPublicAccessBlockConfiguration` on untouched bucket Get — all AWS-exact.

### Notes
- **Accept-store-roundtrip, not enforcement.** No request is denied based on persisted ACL/policy/PAB. Documented divergence in [`SUPPORT.md`](SUPPORT.md). The value v1.1 unlocks is that real CDK/Terraform/boto3 setup scripts that block on these ops can now run end-to-end.
- Backend schema: `BucketRecord` (in `buckets.json`) and per-object/per-version `meta.json` gained optional `versioning`, `tags`, `acl`, `policy_json`, `ownership_controls`, `public_access_block` fields. All optional → older records load cleanly.
- Test count: 19 Go tests + 5 JS smokes added for M10 alone; full suite green at CI port 14566 on both Ubuntu and macOS runners.

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
- `SCORECARD.md` (later folded into [`SUPPORT.md`](SUPPORT.md#accuracy-wins-vs-localstack)) listing the four documented points where nanostack is more accurate than LocalStack.
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
- See [`SUPPORT.md`](SUPPORT.md#accuracy-wins-vs-localstack) for the LocalStack-comparable accuracy claims.
- See [`PRD.md`](PRD.md) for the product spec, design decisions (§17a), and post-v1 roadmap (§15).
