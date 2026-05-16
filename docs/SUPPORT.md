# nanostack Operation Support Matrix

**Version:** v0.1.0 (S3 functionally complete for local dev)

## Accuracy wins vs LocalStack

These are the points where nanostack matches real AWS and LocalStack does not — the PRD §5 "accuracy" wedge. Every row is asserted in CI on every push.

| # | Behaviour | LocalStack | Test |
|---|---|---|---|
| 1 | Presigned URL with a custom header — request sent *without* it → clean `403 SignatureDoesNotMatch` | 5xx panic / partial response ([#5269](https://github.com/localstack/localstack/issues/5269), [#4133](https://github.com/localstack/localstack/issues/4133), [#10844](https://github.com/localstack/localstack/issues/10844)) | [`test_sigv4.py::test_presigned_custom_header_missing`](../tests/conformance/python/test_sigv4.py) |
| 2 | `Accept-Ranges: bytes` on every GetObject / HeadObject response | Missing in many paths ([#1859](https://github.com/localstack/localstack/issues/1859)) | [`test_get_object.py`](../tests/conformance/python/test_get_object.py) |
| 3 | Conditional-header split (GET/HEAD: all four; PUT: `If-Match`/`If-None-Match` only; CopyObject: `x-amz-copy-source-if-*`) | Inconsistent — some headers accepted but not enforced | [`test_conditional_get.py`](../tests/conformance/python/test_conditional_get.py), [`test_conditional_put.py`](../tests/conformance/python/test_conditional_put.py), [`test_copy_object.py`](../tests/conformance/python/test_copy_object.py) |
| 4 | Multipart ETag = `md5(concat(binary-MD5-of-each-part)) + "-" + N`; `EntityTooSmall` when any non-final part < 5 MiB | Format matches but `EntityTooSmall` enforcement inconsistent | [`test_multipart_upload.py`](../tests/conformance/python/test_multipart_upload.py), [`test_multipart_errors.py`](../tests/conformance/python/test_multipart_errors.py) |

## Known drift — to fix

Behavioural drift surfaced by a 2026-05-14 audit. Distinct from the "accept-store-roundtrip" divergences documented per-row in the matrix below: these are bugs we intend to close, not deliberate non-goals. Burndown happens in waves; the **Status** column moves `todo → in-progress → done` as each fix lands.

### High — wrong status / error code on routed ops (Wave 1)

| # | Area | What drifts | Status | Code | Test |
|---|---|---|---|---|---|
| 1 | Multipart | `CompleteMultipartUpload` returns `InvalidPart` (400) when the upload id doesn't exist — AWS returns `NoSuchUpload` (404) | done | [`src/services/s3/multipart.zig`](../src/services/s3/multipart.zig), [`src/storage/fs.zig`](../src/storage/fs.zig) | [`test_multipart_errors.py::test_multipart_complete_with_unknown_upload_id_returns_no_such_upload`](../tests/conformance/python/test_multipart_errors.py) |
| 2 | Tagging | `PutBucketTagging` returns 200 — AWS returns 204 No Content | done | [`src/services/s3/tagging.zig`](../src/services/s3/tagging.zig) | [`test_tagging.py::test_tagging_bucket_round_trip`](../tests/conformance/python/test_tagging.py) |
| 3 | Versioning | HEAD on a delete marker returns 404 — AWS returns 405 Method Not Allowed with `Allow: DELETE` | done | [`src/services/s3/mod.zig`](../src/services/s3/mod.zig) | [`test_versioning.py::test_versioning_head_on_delete_marker_returns_405`](../tests/conformance/python/test_versioning.py) |
| 4 | SigV4 | Payload digest mismatch maps to `BadDigest` — AWS uses distinct `XAmzContentSHA256Mismatch` | done | [`src/server.zig`](../src/server.zig), [`src/wire/errors.zig`](../src/wire/errors.zig) | [`test_sigv4.py::test_content_sha256_mismatch_returns_distinct_code`](../tests/conformance/python/test_sigv4.py) |
| 5 | Versioning | `DeleteObjects` silently drops `<VersionId>` per object — versioned-bucket batch deletes always hit current version | done | [`src/wire/delete_objects_parser.zig`](../src/wire/delete_objects_parser.zig), [`src/services/s3/mod.zig`](../src/services/s3/mod.zig), [`src/wire/object_responses.zig`](../src/wire/object_responses.zig) | [`test_delete_objects.py::test_delete_objects_with_explicit_version_ids`](../tests/conformance/python/test_delete_objects.py) |

### Medium — response-shape gaps (Wave 2)

| # | Area | What drifts | Status | Code | Test |
|---|---|---|---|---|---|
| 6 | Multipart | `ListMultipartUploadsResult` `<Upload>` omits `<Initiator>` and `<Owner>` | done | [`src/wire/multipart_responses.zig`](../src/wire/multipart_responses.zig), [`src/storage/mod.zig`](../src/storage/mod.zig), [`src/storage/fs.zig`](../src/storage/fs.zig), [`src/services/s3/multipart.zig`](../src/services/s3/multipart.zig) | [`test_multipart_list.py::test_multipart_list_uploads_surfaces_initiator_and_owner`](../tests/conformance/python/test_multipart_list.py) |
| 7 | Versioning | `ListVersionsResult` omits `<Owner>` per `<Version>` / `<DeleteMarker>` entry | done | [`src/wire/list_object_versions.zig`](../src/wire/list_object_versions.zig), [`src/services/s3/versioning.zig`](../src/services/s3/versioning.zig) | [`test_versioning.py::test_versioning_list_versions_surfaces_owner_per_entry`](../tests/conformance/python/test_versioning.py) |
| 8 | Listing | `encoding-type=url` is echoed but keys / prefixes / delimiter rendered raw — clients opting in see un-encoded keys | done | [`src/wire/url_encode.zig`](../src/wire/url_encode.zig), [`src/wire/list_objects.zig`](../src/wire/list_objects.zig), [`src/wire/multipart_responses.zig`](../src/wire/multipart_responses.zig), [`src/wire/list_object_versions.zig`](../src/wire/list_object_versions.zig) | [`test_list_objects.py::test_list_objects_v2_encoding_type_url_percent_encodes_keys`](../tests/conformance/python/test_list_objects.py) |
| 9 | Multipart | `ListMultipartUploadsResult` drops `<Prefix>` and `<Delimiter>` when empty — AWS emits them empty | done | [`src/wire/multipart_responses.zig`](../src/wire/multipart_responses.zig), [`src/wire/list_objects.zig`](../src/wire/list_objects.zig), [`src/wire/list_object_versions.zig`](../src/wire/list_object_versions.zig), [`src/wire/xml.zig`](../src/wire/xml.zig) | [`test_multipart_list.py::test_multipart_list_emits_empty_prefix_and_delimiter`](../tests/conformance/python/test_multipart_list.py) |
| 10 | Object attrs | `GetObjectAttributes` response missing `Last-Modified` + `x-amz-delete-marker` headers | done | [`src/services/s3/object_attributes.zig`](../src/services/s3/object_attributes.zig) | [`test_object_attributes.py::test_object_attributes_surfaces_last_modified_header`](../tests/conformance/python/test_object_attributes.py) |
| 11 | Bucket | `ListBuckets` `<Bucket>` entries miss `<BucketRegion>` (AWS 2023 addition) | done | [`src/wire/s3_responses.zig`](../src/wire/s3_responses.zig) | [`test_list_buckets.py::test_list_buckets_emits_bucket_region`](../tests/conformance/python/test_list_buckets.py) |

### Medium/Low — validation, SigV4, edge cases (Wave 3)

| # | Area | What drifts | Status | Code | Test |
|---|---|---|---|---|---|
| 12 | Validation | Object key UTF-8 well-formedness not checked — length only | done | [`src/storage/mod.zig`](../src/storage/mod.zig) | unit: `validateObjectKey: rejects invalid UTF-8` in [`src/storage/mod.zig`](../src/storage/mod.zig) |
| 13 | Multipart | `CompleteMultipartUpload` doesn't cap part list at 10000 | done | [`src/services/s3/multipart.zig`](../src/services/s3/multipart.zig) | [`test_multipart_errors.py::test_multipart_complete_part_list_over_10000_returns_invalid_request`](../tests/conformance/python/test_multipart_errors.py) |
| 14 | Multipart | Empty `<Part>` list returns `InvalidRequest` — AWS returns `MalformedXML` | done | [`src/wire/complete_multipart_parser.zig`](../src/wire/complete_multipart_parser.zig), [`src/services/s3/multipart.zig`](../src/services/s3/multipart.zig) | [`test_multipart_errors.py::test_multipart_complete_empty_part_list_returns_malformed_xml`](../tests/conformance/python/test_multipart_errors.py) |
| 15 | SigV4 | `parseAmzDate` accepts Feb 30 (no day-in-month check) | done | [`src/auth/iso8601.zig`](../src/auth/iso8601.zig) | unit tests in [`src/auth/iso8601.zig`](../src/auth/iso8601.zig) (`Feb 30`, `Feb 29 non-leap`, `Apr 31`, year-2000 / year-2100 leap edges) |
| 16 | SigV4 | Multi-valued same-name headers: `findHeader` returns first match only — AWS joins with commas in canonical form | done | [`src/auth/canonical.zig`](../src/auth/canonical.zig) | [`test_sigv4.py::test_sigv4_multi_value_header_signs_and_authenticates`](../tests/conformance/python/test_sigv4.py) |
| 17 | SigV4 | Uppercase hex `x-amz-content-sha256` falls through to "opaque" branch — body integrity check silently skipped | done | [`src/auth/sigv4.zig`](../src/auth/sigv4.zig) | [`test_sigv4.py::test_content_sha256_uppercase_hex_is_validated`](../tests/conformance/python/test_sigv4.py) |
| 18 | Conditional | `parseHttpDate` strict IMF-fixdate only — rejects RFC 850 + asctime in `If-Modified-Since` | done | [`src/http/date.zig`](../src/http/date.zig) | [`test_conditional_get.py::test_conditional_get_if_modified_since_legacy_formats`](../tests/conformance/python/test_conditional_get.py) |
| 19 | Routing | Virtual-host parser treats any host with a dot as `<bucket>.<rest>` — `s3.amazonaws.com` would set bucket=`s3` | done | [`src/router.zig`](../src/router.zig) | unit tests in [`src/router.zig`](../src/router.zig) (`s3.amazonaws.com is NOT a virtual-host`, regional forms, dev-local) |
| 20 | Bucket | `CreateBucket` ignores `<LocationConstraint>` body — AWS rejects mismatched constraint with `IllegalLocationConstraintException` | todo | [`src/storage/fs.zig:1027`](../src/storage/fs.zig) | — |
| 21 | Restore | `RestoreObject` always returns 202 — AWS returns 200 if already restored | todo | [`src/services/s3/restore.zig:18`](../src/services/s3/restore.zig) | — |
| 22 | Bucket | `ListBuckets` doesn't honour `?prefix`, `?bucket-region`, `?max-buckets`, `?continuation-token` (2023 pagination) | todo | [`src/services/s3/mod.zig:492`](../src/services/s3/mod.zig) | — |

## How to read this matrix

Each row below is one S3 operation or cross-cutting capability. Status is one of:

- **supported** — implemented and asserted by the Python (boto3) + JS conformance suites on every CI run.
- **stub** — recognised by the router; returns `NotImplemented` (HTTP 501) with the correct AWS XML body.
- **deferred** — explicitly out of scope for v1; not yet routed.
- **planned** — on the roadmap for the indicated milestone.

The "Milestone" column points at the release tag in which the capability landed. If you need a behaviour that's not on this matrix, file an issue — we'd rather be honest about gaps than over-promise. The source of truth for the v1 scope (the surface we aim to cover by `v0.0.1`) is [`PRD.md`](PRD.md) §8.

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
| PutBucketCors / GetBucketCors / DeleteBucketCors | supported (404 `NoSuchCORSConfiguration` on untouched; AWS-exact) | M11 |
| PutBucketEncryption / GetBucketEncryption / DeleteBucketEncryption | supported (AES256, aws:kms, aws:kms:dsse; 404 `ServerSideEncryptionConfigurationNotFoundError`) | M11 |
| PutBucketLifecycleConfiguration / GetBucketLifecycleConfiguration / DeleteBucketLifecycle | supported (Filter, Transition, Expiration, Noncurrent*, AbortIncompleteMultipartUpload; 404 `NoSuchLifecycleConfiguration`) | M11 |
| PutBucketNotificationConfiguration / GetBucketNotificationConfiguration | supported (Topic / Queue / CloudFunction targets + Filter; empty Get returns 200 empty body, AWS-exact) | M11 |
| PutBucketWebsite / GetBucketWebsite / DeleteBucketWebsite | supported (IndexDocument, ErrorDocument, RedirectAllRequestsTo, RoutingRules; 404 `NoSuchWebsiteConfiguration`) | M11 |
| GetObjectAttributes | supported (ETag, ObjectSize, StorageClass, ObjectParts.PartsCount, Checksum-empty; per-version; precondition headers honoured) | M11 |
| PutObjectLockConfiguration / GetObjectLockConfiguration | supported (XML body + default-retention rule; 409 InvalidBucketState on non-locked bucket; 404 ObjectLockConfigurationNotFoundError) | M12 |
| PutObjectRetention / GetObjectRetention | supported (per-version; GOVERNANCE/COMPLIANCE mode-transition rules enforced) | M12 |
| PutObjectLegalHold / GetObjectLegalHold | supported (per-version; legal hold supersedes retention) | M12 |
| GetBucketPolicyStatus | supported (lightweight IsPublic heuristic; 404 NoSuchBucketPolicy on untouched) | M13 |
| RestoreObject | supported (accept-store-roundtrip; 202 Accepted; surfaces `x-amz-restore` on HEAD/GET; no actual data movement) | M13 |
| UpdateObjectEncryption | supported (per-version; persists algorithm + KMS key id; surfaces `x-amz-server-side-encryption[-aws-kms-key-id]` on HEAD/GET; no actual cipher) | M13 |
| PutBucketReplication / GetBucketReplication / DeleteBucketReplication | supported (accept-store-roundtrip; no actual replication; 404 ReplicationConfigurationNotFoundError on untouched) | M13 |

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
| **Access enforcement (ACL / policy / PAB)** | **enforced** — real evaluator runs after auth, before dispatch (`tests/conformance/python/test_policy_enforcement.py`) | M14 |
| Public Access Block — put-time admission gates (`BlockPublicPolicy`, `BlockPublicAcls` reject public-granting puts) | supported | M14 |
| Public Access Block — eval-time filters (`IgnorePublicAcls`, `RestrictPublicBuckets`; bucket-owner bypasses both) | supported | M14 |
| Bucket-policy `Condition` blocks | **skipped silently (no-match)** — documented divergence; condition-keys spec is ~80 keys × 6 operator families | M14 |
| Bucket-policy `NotPrincipal` / `NotAction` / `NotResource` | skipped silently — same rationale as `Condition` | M14 |
| Cross-account principal ARNs / IAM user-role policies / STS / assumed roles | not supported — single-tenant model (one configured `access_key` = bucket owner) | post-v1.1 |
| Bucket-policy condition-key validation | not supported (well-formed JSON only) | post-v1.1 |
| Bucket-policy size cap (20 KB) | not enforced (documented divergence) | post-v1.1 |
| Access Points / MRAP / S3 Access Grants | not supported | post-v1.1 |

### Post-v0.1.0 deferred (~39 ops, S3 dev-emulator non-goals)

After v0.1.0, S3 is functionally complete for **local dev** purposes — ~99% of real dev workflows are covered. The remaining ~36% Smithy coverage is split between three categories nanostack doesn't aim to provide:

**Observability / metrics CRUDs (16 ops; "M14 deferred indefinitely")**
- `Put/Get/Delete/ListBucketMetricsConfiguration(s)` — CloudWatch request metrics filters; no CloudWatch in nanostack.
- `Put/Get/Delete/ListBucketInventoryConfiguration(s)` — periodic inventory reports; we don't generate them.
- `Put/Get/Delete/ListBucketAnalyticsConfiguration(s)` — storage-class analysis output; same.
- `Put/Get/Delete/ListBucketIntelligentTieringConfiguration(s)` — auto-tiering; no tiering happens.

**Niche / rarely-emitted (~6 ops)**
- `Put/GetBucketLogging` — server access logs; we don't generate them.
- `Put/GetBucketAccelerateConfiguration` — Transfer Acceleration; no CloudFront in nanostack.
- `Put/GetBucketRequestPayment` — requester-pays billing; no billing.

**Distinct sub-services + deprecated (~13 ops)**
- `CreateSession`, `RenameObject` — S3 Express One Zone (directory buckets). Different service surface.
- `WriteGetObjectResponse` — S3 Object Lambda. Requires Lambda service.
- `SelectObjectContent` — S3 Select (SQL over objects). AWS-deprecated; huge implementation surface. Currently nanostack's 501 sentinel.
- `GetObjectTorrent` — deprecated BitTorrent feature; never coming back.
- Bucket metadata tables (`Create/Delete/GetBucketMetadataConfiguration`, etc., 7 ops) — 2024 Iceberg-table feature; niche.

These will only be added if a real user hits a setup-script gap; not on any roadmap.

### Object Lock + WORM enforcement (M12)

**M12 is the first nanostack milestone where persisted state actually enforces — DeleteObject is rejected within retention; COMPLIANCE mode is immutable; legal hold supersedes everything.** This is a deliberate departure from the M10/M11 accept-store-roundtrip pattern.

| Capability | Status | Milestone |
|---|---|---|
| `x-amz-bucket-object-lock-enabled: true` on CreateBucket → auto-enable versioning | supported | M12 |
| `PutBucketVersioning` Status=Suspended on Object-Lock-enabled bucket | rejected (409 InvalidBucketState, AWS-exact) | M12 |
| `PutObjectLockConfiguration` on non-Object-Lock-enabled bucket | rejected (409 InvalidBucketState; token-based "enable after creation" out of scope) | M12 |
| GOVERNANCE retention mode | supported (shortenable with `x-amz-bypass-governance-retention: true`) | M12 |
| COMPLIANCE retention mode | supported (immutable: only extendable, never weakened or removed; mode change rejected) | M12 |
| Legal hold (ON / OFF, per-version) | supported (always supersedes retention for delete protection) | M12 |
| `x-amz-bypass-governance-retention: true` on DeleteObject / DeleteObjects / PutObjectRetention | honoured at face value (no IAM check; documented divergence — real AWS checks `s3:BypassGovernanceRetention` permission) | M12 |
| Inline `x-amz-object-lock-{mode,retain-until-date,legal-hold}` on PutObject / CopyObject / CreateMultipartUpload | supported | M12 |
| Default retention from bucket config applied to new writes | supported (Days + Years; inline headers override) | M12 |
| Response headers `x-amz-object-lock-{mode,retain-until-date,legal-hold}` on GetObject / HeadObject | supported | M12 |
| CopyObject inheriting source retention | not inherited (AWS-exact; dest gets request headers or bucket default) | M12 |
| Delete marker creation on locked object (DeleteObject without versionId) | allowed even with retention (AWS-exact; delete marker doesn't actually remove the version's data) | M12 |
| Token-based "enable Object Lock after bucket creation" flow | not supported (must be set at CreateBucket; documented divergence) | post-v1.x |

### Bucket configurations (M11)

| Capability | Status | Milestone |
|---|---|---|
| CORS XML round-trip (rules: AllowedMethod/AllowedOrigin/AllowedHeader/ExposeHeader/MaxAgeSeconds) | supported (accept-store-roundtrip; no actual cross-origin enforcement) | M11 |
| Server-side encryption config (AES256 / aws:kms / aws:kms:dsse; KMSMasterKeyID; BucketKeyEnabled) | supported (accept-store-roundtrip; **no actual cipher applied to object data**) | M11 |
| Lifecycle rules (Filter, Prefix, Transition, Expiration, NoncurrentVersionTransition, NoncurrentVersionExpiration, AbortIncompleteMultipartUpload) | supported (accept-store-roundtrip; **rules never expire / transition objects**) | M11 |
| Notification targets (TopicConfiguration → SNS, QueueConfiguration → SQS, CloudFunctionConfiguration → Lambda; events + filter rules) | supported (accept-store-roundtrip; **events never fire — no downstream services**) | M11 |
| Website config (IndexDocument / ErrorDocument / RedirectAllRequestsTo / RoutingRules) | supported (accept-store-roundtrip; **website-mode requests not honoured**) | M11 |
| `GetObjectAttributes` ObjectParts detail | partial (`PartsCount` only; per-part rows out of scope) | M11 |
| **Enforcement of any M11 config** | **not enforced** (accept-store-roundtrip only; documented divergence) | M11 |
| Lifecycle structural validation (Days XOR Date; Filter XOR Prefix) | not enforced (we round-trip whatever the client sends) | post-v1.x |
| EventBridge notification target | not supported (trivial when needed) | post-v1.x |

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
