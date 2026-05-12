# nanostack Operation Support Matrix

Status legend:

- **supported** — implemented, passing the conformance suite.
- **stub** — recognised by the router; returns `NotImplemented` (HTTP 501) with the correct AWS XML body.
- **deferred** — explicitly out of scope for v1; not yet routed.
- **planned** — on the roadmap for the indicated milestone.

This file is updated as part of every release. The source of truth for the v1 cut is [`docs/PRD.md`](docs/PRD.md) §8.

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
| CopyObject | stub | M5 |
| ListObjects (v1) | supported (prefix, delimiter, marker, max-keys, encoding-type=url) | M4 |
| ListObjectsV2 | supported (prefix, delimiter, start-after, continuation-token, max-keys, fetch-owner, encoding-type=url) | M4 |
| CreateMultipartUpload | stub | M6 |
| UploadPart | stub | M6 |
| UploadPartCopy | stub | M6 |
| CompleteMultipartUpload | stub | M6 |
| AbortMultipartUpload | stub | M6 |
| ListMultipartUploads | stub | M6 |
| ListParts | stub | M6 |

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
| Object listing — `encoding-type=url` (URL-encode keys + prefixes in response) | supported | M4 |
| Object listing — `max-keys` cap (1000, request silently clamped) | supported | M4 |
| Streaming payload hashes (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`) | not supported | known limitation; defer |
| Multi-range responses (`multipart/byteranges`) | not supported | polish milestone |
| Path-style addressing | supported | M1 |
| Virtual-hosted-style addressing | supported | M1 |
| AWS-strict bucket-name validation | supported | M1 |
| Filesystem + in-memory (`--ephemeral`) backends | supported | M1 |
| Conditional headers (If-Match / If-None-Match / If-Modified-Since / If-Unmodified-Since) | planned | M5 |
| Range requests with `Accept-Ranges: bytes` | planned | M3 |
| Correct AWS error wire format | partial (M1 codes wired) | M0–M3 |

### Deferred (post-v1)

- Versioning, object lock, replication.
- ACLs and bucket policies (accepted and ignored in v1; full enforcement deferred).
- Lifecycle, intelligent-tiering, restore.
- CORS, static website hosting, transfer acceleration.
- Event notifications (S3 → SNS/SQS/Lambda). Requires those services to land first.
- Select, inventory, analytics.
- Server-side encryption (SSE-S3, SSE-KMS, SSE-C). Headers accepted, not enforced.
- Object tagging (accepted and ignored in v1; full support in v1.1).
