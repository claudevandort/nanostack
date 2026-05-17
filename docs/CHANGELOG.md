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

## [0.2.0] — 2026-05-17

**First minor release: DynamoDB joins S3.**

Per the [versioning scheme](#versioning-scheme), minor releases mark "one AWS service fully implemented against the real-AWS surface." nanostack now covers two services on the same port: S3 (since v0.1.x) and DynamoDB. The architecture proven on S3 generalises — service detection via `X-Amz-Target` header, parallel storage backend vtable, JSON wire layer alongside the existing XML.

Opt-in via `--services s3,dynamodb`. S3 stays default-on; DynamoDB is silent unless explicitly enabled.

### Added — DynamoDB v1 surface (18 ops)

**Table management** (M15-tables):
- `CreateTable` — full KeySchema, AttributeDefinitions, GSI/LSI definitions, BillingMode, Tags.
- `DescribeTable` — returns ACTIVE status, item count, GSI/LSI summaries.
- `ListTables` — paginated; `Limit` + `ExclusiveStartTableName`; lex-ascending.
- `DeleteTable` — immediate; returns TableDescription.
- `UpdateTable` — BillingMode mutation; online GSI add/remove deferred.

**Item CRUD** (M15-items, M15-expressions):
- `GetItem` — full AttributeValue type coverage (S/N/B/BOOL/NULL/L/M/SS/NS/BS); N preserves 38-digit decimal precision.
- `PutItem` — auto-overwrite; ReturnValues NONE/ALL_OLD; **ConditionExpression** supported.
- `DeleteItem` — idempotent; ReturnValues NONE/ALL_OLD; ConditionExpression supported.
- `UpdateItem` — UpdateExpression (SET / REMOVE / ADD / DELETE) with `if_not_exists`, `list_append`, atomic counters; full ReturnValues (NONE / ALL_OLD / ALL_NEW / UPDATED_OLD / UPDATED_NEW); ConditionExpression.

**Expressions** (M15-expressions):
- `ConditionExpression` — comparison (=, <>, <, <=, >, >=), logical (AND/OR/NOT), `BETWEEN`, `IN`, `attribute_exists`, `attribute_not_exists`, `attribute_type`, `begins_with`, `contains`, parentheses.
- `UpdateExpression` — SET (incl. arithmetic, `if_not_exists`, `list_append`), REMOVE, ADD (numeric + set union), DELETE (set subtraction).
- Recursive-descent parsers, no allocations on the happy path. `ExpressionAttributeNames` (`#x`) + `ExpressionAttributeValues` (`:v`) placeholders.

**Query + Scan** (M15-query, M15-scan, M15-gsi):
- `Query` on base table — `KeyConditionExpression` (PK + optional SK predicate including `BETWEEN`, `begins_with`); `FilterExpression`; `Limit`; `ScanIndexForward`; `ExclusiveStartKey`/`LastEvaluatedKey` cursor.
- `Query` on **GSI / LSI** via `IndexName` — projection types `ALL` / `KEYS_ONLY` / `INCLUDE` respected; FilterExpression after projection.
- `Scan` — full table iteration with FilterExpression; pagination via cursor. `TotalSegments > 1` returns ValidationException.

**Batch + Transactions** (M15-batch, M15-tx):
- `BatchGetItem` — up to 100 keys across N tables.
- `BatchWriteItem` — up to 25 Put + Delete ops across N tables.
- `TransactGetItems` — atomic snapshot read of up to 100 items.
- `TransactWriteItems` — all-or-nothing across up to 100 Put/Update/Delete/ConditionCheck ops; per-op `CancellationReasons` on failure; two-pass validate-then-apply under the Fs mutex.

**Misc** (M15-polish):
- `DescribeLimits` — returns synthetic AWS account-level defaults.
- `TagResource` / `UntagResource` / `ListTagsOfResource` — metadata-only.

### Changed
- `--services` flag (was a placeholder string) now parsed into an enabled-services set. Default `"s3"` preserves v0.1.x behaviour.
- `server.zig` branches on `X-Amz-Target` header presence to dispatch DynamoDB requests through a separate handler. SigV4 service-scope validation catches mismatched credential scopes.
- New `storage.DynamoBackend` vtable sibling of `storage.Backend`. `Fs` implements both — one struct, two backend views.
- New `storage.Error` variants: `TableAlreadyExists`, `TableNotFound`, `ConditionalCheckFailed`, `TransactionCanceled`.

### Divergences (intentional, won't change in v0.2.0)
- **No persistence of items across nanostack restart for full-write-through**: schema.json persists; per-item JSON files persist on every mutation. Cold-start item rebuild is a v0.3 task.
- **Parallel scan (`TotalSegments > 1`)** → ValidationException. Single-segment scans work normally.
- **Index queries are O(N)** — every IndexName query walks the base table. A per-index sorted structure is a v0.3 optimisation.
- **Tags** are metadata-only and lost on restart.
- **DynamoDB Streams**, **PartiQL**, **TTL background sweeper**, **Backups/PITR**, **Global Tables**, **Imports/Exports**, **DAX**: out of v0.2.0 scope. Targets return ValidationException with the unsupported-target message.

### Strategic note
v0.2.0 is the inflection point at which nanostack genuinely replaces LocalStack for the "S3 + DynamoDB local dev" workflow. With real bucket-policy enforcement (from v0.1.2) on S3 and atomic transactions + queryable GSIs on DynamoDB, both services are honestly useful — not stubs.

## [0.1.3] — 2026-05-16

**Patch release: Wave 3 drift fixes — `SUPPORT.md` "Known drift" table is now empty.**

Per the [versioning scheme](#versioning-scheme), patches mark "significant pinned cuts of work". Wave 3 closes ten remaining AWS-spec divergences surfaced by the 2026-05-14 drift audit (validation, SigV4 edge cases, virtual-host parsing, error-code corrections, and a couple of small handler bugs). Combined with Wave 1 (status/error codes, v0.1.0) and Wave 2 (response-shape gaps, v0.1.1), the drift table is now empty.

### Added
- **`<LocationConstraint>` validation on CreateBucket.** Mismatched constraint → 400 `IllegalLocationConstraintException` (drift #20). Empty body remains "us-east-1 historical, no constraint required".
- **RestoreObject 200-vs-202 distinction.** First restore returns 202 Accepted; repeats return 200 OK (drift #21). State is in-memory only — lost on restart, acceptable for local-dev semantics.
- **ListBuckets 2023 pagination.** Honours `?prefix`, `?bucket-region`, `?max-buckets` (default 1000, max 10000), `?continuation-token`. Emits `<Prefix>` + `<ContinuationToken>` (next-page) in the response (drift #22).
- **`parseHttpDate` accepts RFC 850 + asctime forms** in `If-Modified-Since` / `If-Unmodified-Since`, matching AWS per RFC 7231 §7.1.1.1 (drift #18). Modern clients only emit IMF-fixdate but the parsers are small and cost almost nothing.

### Changed
- **Virtual-host parser uses an explicit suffix allow-list** (drift #19). Previous over-matching parsed `s3.amazonaws.com` as bucket=`s3` and `example.com` as bucket=`example`. New parser recognises only the documented AWS forms (`.s3.amazonaws.com`, `.s3-<region>.amazonaws.com`, `.s3.<region>.amazonaws.com`, `.s3-website-<region>.amazonaws.com`, `.s3-accelerate.amazonaws.com`) plus dev-local (`.localhost`, `.127.0.0.1`). Unknown hosts fall back to path-style routing.
- **`x-amz-content-sha256` accepts both upper- and lowercase hex** (drift #17). Previously uppercase fell through to the "opaque" branch and silently bypassed body-integrity verification.
- **Object key UTF-8 well-formedness check** added to `validateObjectKey` (drift #12). Lone continuation bytes and truncated multibyte sequences are now rejected via `std.unicode.utf8ValidateSlice`.
- **`CompleteMultipartUpload` part list capped at 10000** (drift #13). Over-cap → 400 `InvalidRequest`, matching AWS.
- **`CompleteMultipartUpload` empty `<Part>` list → `MalformedXML`** (drift #14, was incorrectly `InvalidRequest`).
- **`parseAmzDate` rejects invalid day-in-month** (drift #15). Feb 30, Apr 31, leap-year-edge dates (2000 vs 2100) all validated correctly.

### Removed
- `getBucketPolicyStatus` from the storage `Backend` vtable (orphaned by v0.1.2's switch to evaluator-based `IsPublic`).

## [0.1.2] — 2026-05-16

**Patch release: real ACL + bucket policy + PAB enforcement.**

Per the [versioning scheme](#versioning-scheme), patches mark "significant pinned cuts of work". This release replaces the accept-store-roundtrip behaviour of M10's access-control surface with a real evaluator that runs after auth and before service dispatch. The user-visible promise — "if `PutBucketPolicy` succeeded, the policy actually applies" — is now true. Anonymous GET against a `public-read` object ACL works end-to-end; explicit `Deny` supersedes `Allow` even against the bucket owner; Public Access Block both rejects public-granting puts and filters out public statements/grants at eval time.

### Added
- **Structured policy document parser** (`src/wire/policy_doc.zig`) — turns raw bucket-policy JSON into a typed `PolicyDocument { statements: []Statement }`. Recognises `Principal: "*"` / `{"AWS": "*"}` / `{"AWS": ["arn", ...]}`, scalar or array `Action` / `Resource`, with AWS-glob wildcards (`s3:*`, `s3:Get*`, `arn:aws:s3:::bucket/*`). Statements bearing `Condition`, `NotPrincipal`, `NotAction`, or `NotResource` are flagged as unsupported and skipped by the evaluator.
- **IAM action mapping** (`src/auth/action_map.zig`) — exhaustive 66-row table mapping every routed `Operation` enum variant to its `s3:*` IAM action string, plus `isAccountScoped` / `isObjectScoped` predicates. Account-scoped ops (`ListBuckets`, `CreateBucket`) get an owner-only fast-path.
- **Principal model** (`src/auth/principal.zig`) — `Principal { kind: { anonymous, aws_account }, id }`. Unsigned requests now arrive at the authz hook as `anonymous` instead of being auto-rejected at the SigV4 layer.
- **Policy evaluator** (`src/auth/policy_eval.zig`) — IAM-standard semantics: explicit `Deny` ends evaluation immediately; `Allow` accumulates; no match means "no match" (caller falls through to ACL). Glob matching is iterative two-pointer, zero alloc.
- **ACL evaluator** (`src/auth/acl_eval.zig`) — Grant + Grantee matching with `FULL_CONTROL` implying READ + WRITE + READ_ACP + WRITE_ACP. Group URIs: `AllUsers` matches everyone (incl. anonymous), `AuthenticatedUsers` matches any aws_account principal, `LogDelivery` never grants ordinary access.
- **PAB gate module** (`src/auth/pab_gate.zig`) — three entry points: put-time gates (`gatePolicyPut` / `gateAclPut` reject public-granting puts when the corresponding switch is on, returning 403 `AccessDenied`), and eval-time predicates (`shouldIgnorePublicAcls` / `shouldRestrictPublicBuckets`, both with bucket-owner bypass).
- **Authz hook** (`src/auth/authz.zig`) — orchestrator that runs between `router.parse` and `s3.handle`. Fetches the bucket's ACL + policy + PAB via existing per-config getters, applies PAB filters for non-owner principals, evaluates the bucket policy, falls through to ACL (per-object on object-read, per-bucket on object-create), and finally to bucket-owner-implicit FULL_CONTROL.
- **11 enforcement conformance tests** at `tests/conformance/python/test_policy_enforcement.py` covering: anonymous GET on public-read object ACL, anonymous GET on public-read policy, explicit Deny against the bucket owner, Deny-supersedes-Allow precedence, PAB admission gates for both policy and ACL puts, `IgnorePublicAcls` filter, `RestrictPublicBuckets` filter (with owner-bypass), `Condition` divergence, and `GetBucketPolicyStatus` correctness against the real evaluator.

### Changed
- **`sigv4.verify` returns a `Principal` instead of `void`.** Unsigned requests no longer raise `MissingAuth`; they return `Principal.anonymous()` and proceed to the evaluator. All other failure modes (bad signature, expired presign, etc.) still raise as before.
- **`GetBucketPolicyStatus.IsPublic` is now computed by the real evaluator.** Replaces the prior substring scan of the JSON body. The service layer parses the policy, synthesises an anonymous `s3:GetObject` request against `arn:aws:s3:::<bucket>/*`, and reports `IsPublic = true` iff the evaluator says `Allow` or the bucket ACL has a public group grant. The vestigial `getBucketPolicyStatus` backend vtable entry was removed.
- **Public-granting policy/ACL puts are rejected at admit-time** when the corresponding PAB switch is on (`BlockPublicPolicy`, `BlockPublicAcls`). Previously these puts succeeded silently.

### Divergences
- **Statements with `Condition` blocks are silently skipped** (treated as no-match). The condition-keys spec (~80 keys × 6 operator families) is disproportionate to the dev-loop value. Documented in `SUPPORT.md`.
- **Single-tenant principal model.** One configured `access_key` → one IAM identity (the bucket owner). No cross-account ARNs, no IAM user/role policies, no STS / assumed roles.
- **`NotPrincipal` / `NotAction` / `NotResource` statements are skipped.** Same rationale as Condition.

## [0.1.1] — 2026-05-15

**Patch release: Docker-first distribution + accuracy/drift fixes + AWS CLI conformance.**

Per the [versioning scheme](#versioning-scheme), patch releases mark "significant pinned cuts of work". This release reshapes release engineering (single Docker image instead of 4 tarballs + Homebrew), closes 12 of the 22 AWS-drift items, and adds a third conformance suite.

### Added
- **Docker-first releases.** `claudevandort/nanostack` is now the primary distribution channel on Docker Hub (multi-arch `linux/amd64` + `linux/arm64`, `scratch` base, ~1.5 MB image). Tags: `:X.Y.Z` (immutable, e.g. `:0.1.1`), `:X.Y`, `:latest`. The release workflow cross-compiles a fully-static musl binary for each arch and pushes via `docker buildx`.
- **AWS CLI v2 conformance suite** at `tests/conformance/awscli/` — ~10 pytest-driven tests covering high-level `aws s3` commands (`cp`, `cp --recursive`, `sync` including the idempotency check, `mv`, `ls`, `rm --recursive`, `presign`). These commands add client-side logic (recursion, diffing, composite ops) on top of botocore that the boto3 suite doesn't cover. CI verifies `aws --version` reports v2 on the build-test job (pre-installed on GitHub-hosted runners).

### Changed
- **Linux binaries are now genuinely statically linked** (musl, not glibc). The previous v0.1.0 release shipped glibc-linked binaries despite the README claiming "static". This is the precondition that made the `scratch`-based Docker image possible.
- **Wave 3 (drift #16): SigV4 canonical-headers join multi-valued same-name headers with comma**, per the AWS SigV4 spec. Previously `findHeader` returned only the first match, causing `SignatureDoesNotMatch (403)` for any client that sent duplicate same-name headers (multi-line `Cache-Control`, multi-attribute `X-Amz-Object-Attributes`, etc.). Fix is scoped to canonicalisation only; service-layer handlers continue to read single-valued headers via first-match.
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
- Per-platform tarballs from the GitHub Release page. The 4 cross-platform `.tar.gz` + `.sha256` + combined `SHA256SUMS` machinery is replaced by the single Docker image.
- Homebrew tap formula and the `brew-bump` release job. macOS users use Docker Desktop or `zig build` from source.
- `tests/conformance/go/` (38 .go files including helpers) and `bench/driver/` (Go module). `setup-go` removed from CI.
- macOS leg of the CI matrix — releases are Docker-only, no macOS-specific path to gate.
- 4 of 5 dependabot watchers (pip × 3, npm × 1). Only the GitHub Actions watcher stays — those updates silently break CI if ignored. Dev/CI dep bumps are now manually managed.

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
