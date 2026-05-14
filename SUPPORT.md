# nanostack Operation Support Matrix

**Version:** v0.0.2-dev (M10 in progress — ACLs, policies, ownership, public access block)

**How to read this matrix:** each row is one S3 operation or cross-cutting capability. Status is one of:

- **supported** — implemented and asserted by the Go + JS conformance suites on every CI run.
- **stub** — recognised by the router; returns `NotImplemented` (HTTP 501) with the correct AWS XML body.
- **deferred** — explicitly out of scope for v1; not yet routed.
- **planned** — on the roadmap for the indicated milestone.

The "Milestone" column points at the release tag in which the capability landed. If you need a behaviour that's not on this matrix, file an issue — we'd rather be honest about gaps than over-promise. The source of truth for the v1 scope (the surface we aim to cover by `v0.0.1`) is [`docs/PRD.md`](docs/PRD.md) §8.

## S3

### v1 — must-have

| Operation | Status | Milestone |
|---|---|---|
| CreateBucket | supported | M1 |
| DeleteBucket | supported | M1 |
| HeadBucket | supported | M1 |
| ListBuckets | supported | M1 |
| PutObject | supported | M3 |
| GetObject | supported (incl. range requests) | M3 |
| HeadObject | supported | M3 |
| DeleteObject | supported (idempotent) | M3 |
| DeleteObjects | supported (incl. Quiet mode) | M3 |
| CopyObject | supported (incl. `x-amz-metadata-directive=COPY\|REPLACE`, `x-amz-copy-source-if-*`) | M5 |
| ListObjects (v1) | supported (prefix, delimiter, marker, max-keys, encoding-type=url) | M4 |
| ListObjectsV2 | supported (prefix, delimiter, start-after, continuation-token, max-keys, fetch-owner, encoding-type=url) | M4 |
| CreateMultipartUpload | supported (content-type + user-metadata captured at init) | M6 |
| UploadPart | supported (1–10000 part numbers, per-part MD5 ETag) | M6 |
| UploadPartCopy | supported (whole-part copy + `x-amz-copy-source-if-*`) | M6 |
| CompleteMultipartUpload | supported (incl. 5 MiB min on non-final parts, conditional `If-Match`/`If-None-Match`) | M6 |
| AbortMultipartUpload | supported (204) | M6 |
| ListMultipartUploads | supported (prefix, delimiter, key-marker, upload-id-marker, max-uploads, encoding-type=url) | M6 |
| ListParts | supported (part-number-marker, max-parts) | M6 |
| PutBucketVersioning | supported (Enabled, Suspended) | M8 |
| GetBucketVersioning | supported | M8 |
| ListObjectVersions | supported (prefix, delimiter, key-marker, version-id-marker, max-keys, encoding-type=url) | M8 |
| PutBucketTagging | supported (replaces existing tag set; max 10 tags) | M9 |
| GetBucketTagging | supported (404 NoSuchTagSet on untagged bucket, AWS-exact) | M9 |
| DeleteBucketTagging | supported (204; idempotent) | M9 |
| PutObjectTagging | supported (per-version with `?versionId=X`) | M9 |
| GetObjectTagging | supported (200 + empty TagSet on untagged object, AWS-exact) | M9 |
| DeleteObjectTagging | supported (204; idempotent) | M9 |
| PutBucketAcl | supported (accept-store-roundtrip; XML body OR `x-amz-acl` canned OR `x-amz-grant-*` headers) | M10 |
| GetBucketAcl | supported (synthesizes default Owner FULL_CONTROL when none set) | M10 |
| PutObjectAcl | supported (per-version with `?versionId=X`) | M10 |
| GetObjectAcl | supported | M10 |
| PutBucketPolicy | supported (well-formed JSON only; no condition-key validation) | M10 |
| GetBucketPolicy | supported (404 `NoSuchBucketPolicy` on unset bucket, AWS-exact) | M10 |
| DeleteBucketPolicy | supported (204; idempotent) | M10 |
| PutBucketOwnershipControls | supported (BucketOwnerEnforced / BucketOwnerPreferred / ObjectWriter) | M10 |
| GetBucketOwnershipControls | supported (404 `OwnershipControlsNotFoundError` on unset, AWS-exact) | M10 |
| DeleteBucketOwnershipControls | supported (204; idempotent) | M10 |
| PutPublicAccessBlock | supported (all 4 bool fields) | M10 |
| GetPublicAccessBlock | supported (404 `NoSuchPublicAccessBlockConfiguration` on unset, AWS-exact) | M10 |
| DeletePublicAccessBlock | supported (204; idempotent) | M10 |

### v1 cross-cutting

| Capability | Status | Milestone |
|---|---|---|
| SigV4 — header authentication | supported | M2 |
| SigV4 — presigned URLs (incl. custom headers) | supported | M2 |
| `--no-auth` opt-out (dev convenience) | supported | M2 |
| Configurable clock-skew tolerance (`--skew-seconds`) | supported | M2 |
| `x-amz-content-sha256` hex body verification | supported | M3 |
| Range requests with `Accept-Ranges: bytes` header | supported (single-range) | M3 |
| Content-Type passthrough | supported | M3 |
| `x-amz-meta-*` user metadata passthrough | supported | M3 |
| ETag (MD5 of body, double-quoted) | supported (non-multipart) | M3 |
| ETag — multipart objects (`<md5-of-concatenated-part-md5s>-<part-count>`) | supported | M6 |
| Multipart: `x-amz-copy-source-range` on UploadPartCopy | not supported (deferred to post-v1) | post-v1 |
| Multipart: `x-amz-tagging` on CreateMultipartUpload (applied to merged object on Complete) | supported | M9 |
| Multipart: SSE headers on CreateMultipartUpload | accepted and ignored | post-v1 |
| Multipart: lifecycle-based incomplete-upload cleanup | not supported (manual AbortMultipartUpload required) | post-v1 |
| Object listing — `encoding-type=url` (URL-encode keys + prefixes in response) | supported | M4 |
| Object listing — `max-keys` cap (1000, request silently clamped) | supported | M4 |
| Streaming payload hashes (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`) | not supported | known limitation; defer |
| Multi-range responses (`multipart/byteranges`) | not supported | polish milestone |
| Path-style addressing | supported | M1 |
| Virtual-hosted-style addressing | supported | M1 |
| AWS-strict bucket-name validation | supported | M1 |
| Filesystem backend (`--data-dir`; pass a tmpdir for wipe-clean runs) | supported | M1 |
| Conditional headers — GET/HEAD (all four: If-Match / If-None-Match / If-Modified-Since / If-Unmodified-Since) | supported | M5 |
| Conditional headers — PUT (If-Match / If-None-Match, AWS-exact; If-*-Since accepted and ignored) | supported | M5 |
| Conditional headers — CopyObject (`x-amz-copy-source-if-{match,none-match,modified-since,unmodified-since}`) | supported | M5 |
| Conditional headers — DELETE | not enforced (matches AWS) | M5 |
| CopyObject 5 GB source-size cap | not enforced (known divergence) | post-v1 |
| Range requests with `Accept-Ranges: bytes` | planned | M3 |
| Correct AWS error wire format | partial (M1 codes wired) | M0–M3 |

### Versioning-related (M8)

| Capability | Status | Milestone |
|---|---|---|
| Per-object versionId on PUT/Copy/CompleteMPU (`x-amz-version-id` response header) | supported | M8 |
| GET/HEAD/DELETE `?versionId=X` query selector | supported | M8 |
| Delete markers (`x-amz-delete-marker: true`, 404 on GET, removable by versionId) | supported | M8 |
| Multipart-ETag `<md5>-N` format on versioned writes | supported | M8 |
| MFA Delete (`x-amz-mfa` header) | accepted-and-ignored (documented divergence) | post-v1.1 |
| Object Lock (governance/compliance retention) | not supported | post-v1.1 |

### ACL / policy / ownership / PAB (M10)

| Capability | Status | Milestone |
|---|---|---|
| Inline `x-amz-acl` canned header on PutObject / CopyObject / CreateMultipartUpload | supported | M10 |
| Inline `x-amz-grant-{read,write,read-acp,write-acp,full-control}` headers on writes + ACL Puts (full pass-through; folded into persisted ACL) | supported | M10 |
| `x-amz-tagging-directive: COPY \| REPLACE` on CopyObject (M9) — ACL also flows through dest when `x-amz-acl` is set on the copy | supported | M10 |
| Per-version object ACL (`PutObjectAcl?versionId=X`) | supported | M10 |
| `AccessControlListNotSupported` (400) on PutBucketAcl/PutObjectAcl when bucket ownership is `BucketOwnerEnforced` | supported | M10 |
| Canned ACL values: `private`, `public-read`, `public-read-write`, `authenticated-read`, `log-delivery-write` | supported (full expansion) | M10 |
| Canned ACL values: `bucket-owner-read`, `bucket-owner-full-control`, `aws-exec-read` | supported (degrades to "private" — emulator has no distinct bucket owner; documented divergence) | M10 |
| Default `AccessControlPolicy` synthesis (Owner FULL_CONTROL) when none stored | supported | M10 |
| **Access enforcement (ACL / policy / PAB)** | **not enforced** (documented divergence — accept-store-roundtrip only) | M10 |
| Bucket-policy condition-key validation | not supported (well-formed JSON only) | post-v1.1 |
| Bucket-policy size cap (20 KB) | not enforced (documented divergence) | post-v1.1 |
| Access Points / MRAP / S3 Access Grants | not supported | post-v1.1 |

### Tagging-related (M9)

| Capability | Status | Milestone |
|---|---|---|
| Inline `x-amz-tagging` header on PutObject (URL-encoded `k=v&k=v`) | supported | M9 |
| Inline `x-amz-tagging` header on CreateMultipartUpload (applied on Complete) | supported | M9 |
| `x-amz-tagging-directive: COPY \| REPLACE` on CopyObject | supported | M9 |
| `x-amz-tagging-count: N` response header on GetObject / HeadObject | supported | M9 |
| Per-version object tag sets (PutObjectTagging?versionId=X) | supported | M9 |
| AWS-strict validation: max 10 tags, key 1–128 chars, value 0–256 chars, alphabet `[a-zA-Z0-9 +\-=._:/@]`, no duplicate keys, no `aws:` prefix → 400 `InvalidTag` | supported | M9 |
| `NoSuchTagSet` (404) on GetBucketTagging when bucket has no tags | supported | M9 |
| Empty `<TagSet/>` (200) on GetObjectTagging when object has no tags | supported | M9 |
| PutBucketTagging replaces (not merges) existing tag set | supported (matches AWS) | M9 |
| Tag-based IAM/policy condition keys | not supported (M10 accept-store-roundtrip only) | M10 |
| Tag-based lifecycle rules | not supported | post-v1.1 |

### Deferred (post-v1)

- Versioning, object lock, replication.
- ACLs and bucket policies (accepted and ignored in v1; full enforcement deferred).
- Lifecycle, intelligent-tiering, restore.
- CORS, static website hosting, transfer acceleration.
- Event notifications (S3 → SNS/SQS/Lambda). Requires those services to land first.
- Select, inventory, analytics.
- Server-side encryption (SSE-S3, SSE-KMS, SSE-C). Headers accepted, not enforced.
