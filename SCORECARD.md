# nanostack — Conformance Scorecard

**Version:** v0.0.1 (2026-05-13)

The PRD's wedge is **accuracy beats LocalStack on the surface we cover**. This document lists the specific points where nanostack matches real AWS and a popular emulator does not, with the conformance test that proves each claim.

> "We win by being measurably faster on the dev loop AND demonstrably more accurate than S3Mock on the surface we cover."
> — `docs/PRD.md` §4

Every row below is asserted in CI on every push. Anything not listed here is either covered identically by both nanostack and LocalStack (the common case for the basic ops) or out of scope for v0.0.1.

## The four documented wins

| # | Behaviour | AWS spec | nanostack | LocalStack | nanostack test |
|---|---|---|---|---|---|
| 1 | **Presigned URL with a custom header — request sent *without* that header** | 403 `SignatureDoesNotMatch` with an AWS error body | ✅ Clean 403 + canonical error XML | ❌ 5xx panic / partial response (issues [#5269](https://github.com/localstack/localstack/issues/5269), [#4133](https://github.com/localstack/localstack/issues/4133), [#10844](https://github.com/localstack/localstack/issues/10844)) | [`TestPresignedCustomHeaderMissing`](tests/conformance/go/sigv4_test.go) |
| 2 | **`Accept-Ranges: bytes` header on every object response** | Header always present on GetObject/HeadObject | ✅ Present in every response | ❌ Missing in many paths (issue [#1859](https://github.com/localstack/localstack/issues/1859)) | [`tests/conformance/go/get_object_test.go`](tests/conformance/go/get_object_test.go) (`AcceptRanges` assertion) |
| 3 | **Conditional-header split — exact AWS semantics** | GET/HEAD honour all four (`If-Match`/`If-None-Match`/`If-Modified-Since`/`If-Unmodified-Since`); PUT honours `If-Match` + `If-None-Match` only; CopyObject honours `x-amz-copy-source-if-*` against the source | ✅ All three split modes implemented + tested | ⚠️ Inconsistent — some headers accepted but not enforced | [`conditional_get_test.go`](tests/conformance/go/conditional_get_test.go), [`conditional_put_test.go`](tests/conformance/go/conditional_put_test.go), [`copy_object_test.go`](tests/conformance/go/copy_object_test.go) (`CopySourceIfMatch*`) |
| 4 | **Multipart ETag** = `md5(concat(binary-MD5-of-each-part)) + "-" + N` | Quoted hex with `-N` suffix matching AWS exactly | ✅ Verified via the AWS Go + JS SDKs; `EntityTooSmall` correctly returned when any non-final part is < 5 MiB | ⚠️ Format matches but `EntityTooSmall` enforcement inconsistent across versions | [`TestMultipartUpload_HappyPath_TwoParts`](tests/conformance/go/multipart_upload_test.go), [`TestMultipart_EntityTooSmall_NonFinalUndersized`](tests/conformance/go/multipart_errors_test.go) |

## What's covered (the "and the rest matches" baseline)

19 S3 operations have a green Go + JS conformance row:

CreateBucket · DeleteBucket · HeadBucket · ListBuckets · PutObject · GetObject · HeadObject · DeleteObject · DeleteObjects · CopyObject · ListObjects (v1) · ListObjectsV2 · CreateMultipartUpload · UploadPart · UploadPartCopy · CompleteMultipartUpload · AbortMultipartUpload · ListMultipartUploads · ListParts

Plus the cross-cutting capabilities listed in [`SUPPORT.md`](SUPPORT.md): SigV4 header auth, presigned URLs (incl. custom headers), `x-amz-content-sha256` verification, range requests, content-type passthrough, user metadata, etag computation, conditional headers (all three modes above), path-style + virtual-hosted-style addressing.

## What's *not* claimed

Anything not in the table above is **out of scope for v0.0.1**. See [`SUPPORT.md`](SUPPORT.md) for the explicit deferred list (versioning, tagging, ACLs, lifecycle, SSE, etc.). We deliberately do not claim parity on operations we haven't implemented and tested.

## Reproduce locally

```sh
git clone https://github.com/claudevandort/nanostack
cd nanostack
zig build test                              # unit tests
zig build                                   # build the binary
./zig-out/bin/nanostack --port 14566 --data-dir "$(mktemp -d)" &
cd tests/conformance/go && \
  NANOSTACK_ENDPOINT=http://127.0.0.1:14566 \
  NANOSTACK_BIN=../../../zig-out/bin/nanostack \
  go test -v -count=1 ./...
```

Every test cited above will run and pass. If any one of them fails on a fresh clone, that's the bug to report.
