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

## [0.3.3] — 2026-05-18

**Patch release: SQS Queue Policy enforcement.**

Closes the last SUPPORT.md divergence row for SQS. The Policy attribute (mutated by `AddPermission` / `RemovePermission` / `SetQueueAttributes`) is now evaluated on every request via the existing `auth/policy_eval.zig` evaluator. After v0.3.3, SQS is **feature-complete + fully enforced** — lining up cleanly for v0.3.4's strategic S3 → SQS event-notification unlock.

### Added

- **`src/services/sqs/authz.zig`** (new, ~80 lines): the queue-policy authz hook. Cascade: `--no-auth` → allow; account-scoped op → require non-anonymous; queue-scoped op + owner principal → allow (implicit); queue has no policy → deny; queue has policy → `policy_eval.evaluate(...)` (`allow` / `deny` short-circuit, `no_match` → default-deny).
- **`src/auth/sqs_action_map.zig`** (new): string-keyed switch mapping `X-Amz-Target` op strings ("SendMessage", etc.) to IAM action strings ("sqs:SendMessage", etc.). Batch ops map to their per-message action (AWS-exact).
- **Principal threading** in `src/server.zig::handleSqs`: the SigV4-returned `Principal` is no longer discarded — it's now captured and threaded into `services/sqs/mod.zig::Context` for the authz hook.
- **`access_denied` error code** in `src/wire/sqs/errors.zig` (HTTP 403, AWS error code `AccessDenied`).

### Tests

- Python: 495 → 504 (+9 enforcement tests covering owner-implicit-allow, anonymous-denied-by-default, public-send policy, action-mismatch denial, explicit-Deny-overrides-Allow, owner-bypasses-Deny, `--no-auth`-bypasses-policy, account-scoped ops).
- JS: 103 → 106 (+3 — anonymous fetch + owner-signed SDK).
- AWS CLI: 43 → 45 (+2 — signed-owner sanity + owner-bypasses-Deny).

### Documented divergences (new / changed in v0.3.3)

- **Removed**: "Queue Policy attribute is accepted, not evaluated" — it now is.
- **New**: "Cross-account principals not supported." SigV4 verifies only against the configured `--access-key`; cross-account `Principal: { AWS: ... }` grants can't be exercised in nanostack. Anonymous (`Principal: "*"`) works end-to-end.
- **New**: "`AddPermission` only constructs Allow statements" — same constraint as AWS-real. Hand-built policies via `SetQueueAttributes` are the path for Deny statements.
- **New**: "Policy `Condition` blocks are skipped" — inherited from `auth/policy_eval.zig`.

## [0.3.2] — 2026-05-18

**Patch release: SQS robustness.**

Closes the SUPPORT.md ↔ behaviour drift accumulated through v0.3.0 + v0.3.1, lands the remaining 6 ops, and adds the MessageRetentionPeriod sweeper. After this patch SQS is feature-complete except for Queue Policy enforcement (deferred to v0.3.3) and FIFO high-throughput mode (deferred indefinitely).

### Fixed — drift closures

- **Cold-start message rehydration.** `loadSingleQueue` now walks `<queue>/messages/*.json` and rebuilds `slot.messages` (sorted by `sent_unix` then by message-id for stable sub-second ordering). SUPPORT.md had claimed this worked since v0.3.0; v0.3.2 makes it real.
- **FIFO dedup history persistence.** `<queue>/dedup_history.json` is written through after every send and loaded on cold start. A re-send within the 5-minute window now correctly dedupes even after a restart.
- **MessageRetentionPeriod is enforced.** New background sweeper thread (mirroring v0.2.3 TTL pattern) drops messages where `now > sent_unix + retention`. Tunable via `--sqs-retention-sweep-interval-seconds N` (default 60s, range 1..=3600).

### Added — surface completion (6 ops)

- **`ListDeadLetterSourceQueues`** — reverse-lookup from a DLQ to its source queues; reuses `parseRedrivePolicy`.
- **`AddPermission` / `RemovePermission`** — AWS-real syntactic sugar over the Policy attribute. AddPermission constructs an IAM-style Statement and merges it; RemovePermission drops by Sid + clears the Policy when empty. Duplicate Sid → `InvalidParameterValue`; unknown Label → `InvalidParameterValue`. (Policy enforcement itself is still accept-store-roundtrip; deferred to v0.3.3.)
- **`StartMessageMoveTask` / `CancelMessageMoveTask` / `ListMessageMoveTasks`** — the DLQ redrive task API. Synchronous execution model: Start drains the entire DLQ into the destination immediately and the task is recorded as `COMPLETED`. `MaxNumberOfMessagesPerSecond` accepted but ignored. Tasks are in-memory only.

### Tests

- Python: 474 → 495 (+21 robustness tests).
- JS: 98 → 103 (+5).
- AWS CLI: 40 → 43 (+3).

### Documented divergences (new / changed in v0.3.2)

- Removed "MessageRetentionPeriod not enforced" — it now is.
- Removed "FIFO dedup history is in-memory only" — persisted to disk as of v0.3.2.
- Removed "In-flight messages tracked in-memory" — full rehydration ships.
- Reworded "Queue Policy attribute is accepted, not evaluated" — points at v0.3.3 as the planned enforcement landing.
- New: "MessageMoveTask runs synchronously" — drains on Start, no intermediate `RUNNING` status, `MaxNumberOfMessagesPerSecond` accepted but ignored. In-memory state.

## [0.3.1] — 2026-05-18

**Patch release: SQS FIFO queues.**

Closes the headline gap in the v0.3.0 SQS surface — FIFO queues now actually order messages, dedupe, and enforce head-of-line blocking. Standard queues are unchanged.

### Added — FIFO support

- **`FifoQueue` attribute** — derived from the `.fifo` name suffix, immutable post-creation. Mismatch between the name and the explicit `FifoQueue` attribute → `InvalidAttributeValue`.
- **`ContentBasedDeduplication` attribute** — when `true`, SendMessage on a FIFO queue without `MessageDeduplicationId` uses `sha256(body)` as the implicit dedup id.
- **`MessageGroupId` (SendMessage)** — required on FIFO sends, rejected on Standard. Carries the group-ordering scope.
- **`MessageDeduplicationId` (SendMessage)** — explicit dedup id with a 5-minute window. Re-sends within the window silently return the original `MessageId` + `SequenceNumber`.
- **`SequenceNumber` (SendMessage response)** — monotonic per-queue u128, rendered as zero-padded 20-digit decimal. Persisted on `attributes.json` so re-sends after restart can't collide.
- **Per-group head-of-line blocking on ReceiveMessage** — only one in-flight message per `MessageGroupId` at a time. ReceiveMessage walks the in-memory list once per call, claiming groups as it goes; a group's later messages are hidden while its head is in-flight. `DeleteMessage` / `ChangeMessageVisibility(0)` re-elect the new head naturally.
- **Per-message `DelaySeconds` rejected on FIFO** (matches AWS).
- **`SendMessageBatch` per-entry FIFO support** — each successful entry returns its own `SequenceNumber`; in-batch dedup collapses to one delivered message.

### Tests

- Python: 448 → 474 (+26 FIFO).
- JS: 94 → 98 (+4).
- AWS CLI: 37 → 40 (+3).

### Documented divergences (new in v0.3.1)

- **FIFO high-throughput mode (`DeduplicationScope=messageGroup` + `FifoThroughputLimit=perMessageGroupId`)** is not modelled — attributes accepted but the per-group-throughput accounting isn't built.
- **Dedup history is in-memory only** — survives within a process but not across restart.
- **SequenceNumber width**: 20-digit zero-padded decimal (covers u64 with room to grow). AWS docs say up to 39 digits.

## [0.3.0] — 2026-05-17

**Minor release: SQS joins S3 + DynamoDB.**

Per the [versioning scheme](#versioning-scheme), minor releases mark "one AWS service fully implemented against the real-AWS surface." nanostack now covers three services on the same port: S3 (since v0.1.x), DynamoDB (since v0.2.x), and SQS. The architecture proven over four minor cuts of DDB generalises cleanly — three-way `X-Amz-Target` dispatch (`AmazonSQS.*` / `DynamoDB_20120810.*` / S3), parallel storage backend vtable on `Fs`, parallel JSON wire layer.

Opt-in via `--services sqs` (or `--services s3,dynamodb,sqs` for all three). The default is still S3-only.

### Added — SQS v1 surface (17 ops)

**Queue management** (Phase 1, 7 ops):
- `CreateQueue` — Attributes parsed for VisibilityTimeout / DelaySeconds / ReceiveMessageWaitTimeSeconds / MessageRetentionPeriod / MaximumMessageSize / RedrivePolicy / Policy. Duplicate-name calls are idempotent.
- `DeleteQueue` — immediate; wipes disk + in-memory state.
- `ListQueues` — QueueNamePrefix filter; MaxResults + NextToken cursor.
- `GetQueueUrl`, `GetQueueAttributes`, `SetQueueAttributes`, `PurgeQueue`.

**Messages** (Phase 2, 4 ops):
- `SendMessage` — real MD5 of body, per-message DelaySeconds override, MessageAttributes round-trip verbatim.
- `ReceiveMessage` — MaxNumberOfMessages 1..10, per-call VisibilityTimeout override. Visibility timeout enforced via on-read promotion of expired in-flight messages (no background sweeper needed).
- `DeleteMessage` — receipt-handle decoded + validated; idempotent on already-deleted.
- `ChangeMessageVisibility` — 0..43200 seconds; 0 immediately re-releases.

**Batches** (Phase 3, 3 ops):
- `SendMessageBatch`, `DeleteMessageBatch`, `ChangeMessageVisibilityBatch` — up to 10 entries each, per-entry Successful / Failed split, per-entry errors don't abort the batch.

**Long polling** (Phase 3):
- `ReceiveMessage` with `WaitTimeSeconds > 0` (1..20) blocks the handler. Polls the queue every 100ms until a message arrives or the deadline expires. Resolves the effective wait from the request or the queue's `ReceiveMessageWaitTimeSeconds` attribute. **First long-poll handler in nanostack** — sets the precedent for future Lambda invoke / DDB Streams subscriptions.

**Dead-letter queues** (Phase 4):
- `RedrivePolicy` attribute parsed at receive time. Once `receive_count >= maxReceiveCount`, the message moves atomically to the DLQ (write to DLQ's messages dir, delete from source). Body preserved. Missing DLQ silently disables routing.

**Tags** (Phase 5, 3 ops):
- `TagQueue` / `UntagQueue` / `ListQueueTags`. Max 50 tags per queue. Persisted to `tags.json` per queue. Survive restart.

### Added — service plumbing

- **`--account-id` CLI flag** (default `000000000000`) — embedded in queue URLs and ARNs. Future Lambda integration will share the same value across services.
- **Three-way X-Amz-Target dispatch in `src/server.zig`**: `AmazonSQS.*` → SQS, other non-null target → DynamoDB, null → S3. SigV4 with `service="sqs"` for SQS requests.
- **Storage layout**: `<data_dir>/profiles/<profile>/sqs/queues/<name>/{attributes.json, tags.json, messages/<id>.json}` — parallel to DDB's `dynamodb/tables/...`. Queues survive restart with their attributes, tags, and pending messages intact.

### Internals

- **Receipt handle encoding**: base64-url of `<queue_name>|<message_id>|<receive_count>`. Opaque to clients; we decode + validate the queue name + look up by message ID for `DeleteMessage` / `ChangeMessageVisibility`.
- **Message ID format**: UUID-v4-shaped from the nanosecond clock. AWS-compatible string format (`xxxxxxxx-xxxx-4xxx-xxxx-xxxxxxxxxxxx`).
- **Long-poll primitive**: `std.os.linux.nanosleep` per the v0.2.3 TTL sweeper precedent. No new background-thread infrastructure introduced.

### Tests

- Zig unit tests: 520 → 532 (+12 — queue-name validation, wire parser shapes for queues + messages + batches).
- Python conformance: 405 → 448 (+43 — 15 queue CRUD + 14 messages + 6 batch & long-polling + 4 DLQ + 4 tag).
- JS conformance: 86 → 94 (+8 — full SQS round-trip via `@aws-sdk/client-sqs`).
- AWS CLI conformance: 33 → 37 (+4).

### Documented divergences (intentional)

- **JSON wire only**, not the legacy query-string/XML form. Modern SDKs default to JSON; users on older SDKs should upgrade.
- **FIFO queues deferred.** Future v0.3.x patch.
- **In-handler long-poll sleep** (not server-side event loop). Wastes one handler thread per active poll.
- **No connection-cancellation detection** during long polls.
- **No rate limits.** AWS enforces per-account caps.
- **MessageRetentionPeriod is configured but not enforced.**
- **No encryption at rest**, queue policies accepted-not-enforced.

### Strategic note

After v0.3.0 nanostack covers the three services that anchor the dominant local-dev workflow for serverless backends — S3 for blobs, DynamoDB for state, SQS for queues. The PRD §15 v1.4 target (Lambda + cross-service event wiring) becomes the next strategic move: S3 → Lambda, DDB Streams → Lambda, SQS → Lambda. After that, v1.0 — the "multi-service workflow-ready" milestone — is in reach.

## [0.2.5] — 2026-05-17

**Patch release: DynamoDB Backups + PITR.**

v0.2.5 lands the last truly-useful DDB deferred feature. Real apps test their restore workflows in local dev (backup → corrupt some data → restore-and-verify), and that flow now works end-to-end against nanostack.

After v0.2.5 the deferred list trims to Imports/Exports — DDB is feature-complete for almost every local-dev workflow. The next minor (v0.3.0) is still SQS per PRD §15.

### Added — Backups (5 ops)

- **`CreateBackup`** — real on-disk snapshot of the table's full schema + every item at time T. Stored at `<data_dir>/profiles/<profile>/dynamodb/backups/<backup_id>/`, independent of the source table. Backups outlive `DeleteTable` (matching AWS).
- **`ListBackups`** — `TableName` filter, `Limit` + `ExclusiveStartBackupArn` cursor, lex-ascending ARNs.
- **`DescribeBackup`** — returns the full `BackupDescription` with snapshotted KeySchema + ItemCount + SourceTableDetails.
- **`DeleteBackup`** — `deleteTree` on the backup dir; returns the description with `BackupStatus=DELETED`.
- **`RestoreTableFromBackup`** — creates the target table from the snapshotted schema and replays every snapshotted item. Rejects on target-name conflict with `ResourceInUseException`.

### Added — PITR (3 ops)

- **`UpdateContinuousBackups`** — toggles PITR enabled/disabled. Status snaps directly (no ENABLING/DISABLING transients). Persisted on the table slot's `continuous_backup` field; survives nanostack restart.
- **`DescribeContinuousBackups`** — returns `ContinuousBackupsStatus = ENABLED` (account-level) + `PointInTimeRecoveryDescription` with the configured PITR status + `EarliestRestorableDateTime` = `max(table_created, now - 35d)` + `LatestRestorableDateTime` = `now`.
- **`RestoreTableToPointInTime`** — accepts `RestoreDateTime` / `UseLatestRestorableTime` but **ignores them** and snapshots the current source state. Documented divergence; LocalStack and Moto do the same. Real time-travel would require a write-ahead log we don't keep.

### Internals

- **Backup disk layout**: `<base>/dynamodb/backups/<backup_id>/{manifest.json, schema.json, items/<sha>.json}`. Backup IDs are `<14-digit unix-ms>-<8-hex>` (matches AWS's opaque shape). Backup ARN format `arn:aws:dynamodb:<region>:000000000000:table/<source>/backup/<id>`.
- **Reused schema persistence**: backups invoke `slotToDoc` directly to serialize the schema, matching the live `tables/<name>/schema.json` format. Items use the existing AttributeValue renderer.
- **`createTableLocked` extracted** from `ddbCreateTable` so callers that already hold the mutex (restore path) don't re-lock.
- **TableSlot grows `continuous_backup`** following the same persistence template as `stream_spec` (v0.2.2) and `ttl_spec` (v0.2.3): new SchemaDoc fields, `slotToDoc` + `docToSlot` threaded through.

### Tests

- Zig unit tests: 514 → 520 (+6 — wire parser tests for the new ops).
- Python conformance: 383 → 405 (+22 — full Phase-1 + Phase-2 coverage including restart-survival and the backup-then-corrupt-then-restore pattern).
- JS conformance: 80 → 86 (+6 — round-trips through `@aws-sdk/client-dynamodb`).
- AWS CLI conformance: 29 → 33 (+4).

### Documented divergences (intentional)

- **PITR target time ignored** on `RestoreTableToPointInTime`. Snapshots current state.
- **`EarliestRestorableDateTime` is synthetic** when PITR is disabled (boto3 reads it unconditionally).
- **No backup encryption** (no KMS modelling).
- **`BackupSizeBytes` is an estimate** = sum of item-file sizes after JSON serialization.
- **No restore-in-progress state.** AWS shows `CREATING` for several minutes; nanostack snaps to `ACTIVE`.

### Strategic note

After v0.2.5 the DDB deferred list trims to Imports/Exports only — and Imports/Exports involves S3 cross-service data shuffling and an async job model that fits a future patch better than this release. The next minor (v0.3.0) brings SQS as service #3.

## [0.2.4] — 2026-05-17

**Patch release: DynamoDB PartiQL.**

PartiQL is the SQL-shaped DDB surface a lot of apps reach for, especially apps migrated from a relational backend. v0.2.4 lands all three ops — `ExecuteStatement`, `ExecuteTransaction`, `BatchExecuteStatement` — by recognising that the WHERE clause and SET clause grammars are isomorphic to ConditionExpression / UpdateExpression, so most of the work is a thin SQL-shaped lexer/parser that delegates to the existing evaluators.

After v0.2.4 the deferred list trims to Backups/PITR and Imports/Exports. DDB at this point covers everything most local-dev workflows reach for.

### Added — three PartiQL ops

- **`ExecuteStatement`** — SELECT / INSERT / UPDATE / DELETE.
  - **SELECT**: PK eq query, PK + SK predicate (eq / lt / le / gt / ge / BETWEEN / begins_with), full-table scan (no WHERE), column projection, parameterised `?` placeholders, quoted + unquoted identifiers.
  - **INSERT**: `INSERT INTO "t" VALUE {'col': literal_or_?, ...}` with all common attribute types (S/N/BOOL/NULL via inline; lists/maps/sets via positional `?` params).
  - **UPDATE**: `UPDATE "t" SET col = ?, col = col + ? WHERE pk = ?` — atomic counter arithmetic (add/sub against the existing value), multi-assignment, new-attribute creation.
  - **DELETE**: `DELETE FROM "t" WHERE pk = ? [AND sk = ?]`.
  - **RETURNING**: `ALL OLD *`, `ALL NEW *`, `MODIFIED OLD *`, `MODIFIED NEW *` — maps to the underlying `ReturnValues` field.
- **`ExecuteTransaction`** — up to 100 statements, all INSERT / UPDATE / DELETE (SELECT rejected per AWS). All-or-nothing atomicity via the existing `transactWriteItems` primitive. Cancellation surfaces `TransactionCanceledException` with the parallel `CancellationReasons` array.
- **`BatchExecuteStatement`** — up to 25 statements, independent (non-atomic) execution. SELECT, INSERT, UPDATE, DELETE all allowed. Per-statement errors are reported inline rather than aborting the batch.

### Internals

- **`?` placeholder mechanism**: The PartiQL parser tracks each `?` in encounter order; the handler synthesises an in-memory parameter map from the request's `Parameters` array. The WHERE / SET evaluators take the same parameter array via a small dispatch helper.
- **WHERE eval reuses `condition_mod.valuesEqual` / `compareValues`** (already used by Query). No new evaluator code.
- **SET eval is custom but minimal** — assign / add-to-col / sub-from-col with `std.fmt.parseFloat` for the arithmetic case, matching the existing UpdateExpression's atomic-counter approach.
- **No storage backend changes.** PartiQL routes through `query`, `putItem`, `updateItem`, `deleteItem`, `transactWriteItems` — all existing vtable entries.

### Tests
- Zig unit tests: 497 → 514 (+17 — 8 lexer + 8 parser + 1 misc).
- Python conformance: 351 → 383 (+32 — 14 SELECT + 14 INSERT/UPDATE/DELETE + 4 Transaction/Batch tests + 1 surface).
- JS conformance: 74 → 80 (+6 — ExecuteStatement + Transaction + Batch shape).
- AWS CLI conformance: 25 → 29 (+4 — execute-statement / execute-transaction shape).

### Documented divergences (intentional)
- **Phase-1 WHERE grammar** for SELECT covers PK eq + SK predicate only (no OR / NOT / IN / scan-filter syntax). Future patches may extend.
- **LIMIT in statement is rejected** — matches AWS. Use the request-level `Limit`.
- **Quoted identifiers are case-sensitive**; unquoted case-fold to lowercase — matches AWS.

### Strategic note
After v0.2.4 the DDB deferred list trims to Backups/PITR and Imports/Exports. The next minor (v0.3.0) is still SQS per PRD §15.

## [0.2.3] — 2026-05-17

**Patch release: DynamoDB TTL background sweeper.**

Per the [versioning scheme](#versioning-scheme), patches mark "significant pinned cuts of work". v0.2.2 deferred TTL alongside PartiQL / PITR / Imports/Exports; this release closes TTL because ephemeral-data tables (session storage, OTP codes, idempotency keys, request dedup) are a common DDB use case that simply doesn't work in local emulation without it.

This release also introduces **the first background thread in nanostack**. The threading model + shutdown semantics (`std.Thread.spawn` from `Fs.init`, stop-flag via `std.atomic.Value(bool)`, join in `Fs.deinit`) become the precedent for future sweepers.

### Added — TTL surface (2 ops)

- **`UpdateTimeToLive`** — `{TableName, TimeToLiveSpecification: {Enabled, AttributeName}}`. Returns `{TimeToLiveSpecification: {Enabled, AttributeName}}` (different wrapper from Describe — matches the AWS shape exactly). Status snaps directly to terminal; we don't model the ENABLING / DISABLING transients.
- **`DescribeTimeToLive`** — `{TableName}` → `{TimeToLiveDescription: {TimeToLiveStatus, AttributeName?}}`. Returns `DISABLED` for never-configured tables (no AttributeName). Spec persists across nanostack restart.

### Added — background sweeper

- **`--ttl-sweep-interval-seconds N`** (range 1..=3600, default 5). Real AWS evicts "best-effort within 48h"; 5s makes local-dev tests responsive without polling too aggressively.
- **One background thread per `Fs` instance**, spawned in `Fs.initWithOptions` and joined in `Fs.deinit`. Shutdown signalled via a `std.atomic.Value(bool)` polled in 250ms chunks. Test-friendly `Fs.init` shim disables the sweeper (Zig test runner doesn't tolerate dangling threads).
- **Sweep semantics**: iterates every TTL-enabled table, collects items where the TTL attribute is a `Number` (`.n`) ≤ `now()`, and evicts each via the existing `applyDeleteLocked` (so capture + on-disk delete come for free). Items where the attribute is missing or non-Number are ignored, matching AWS.

### Added — Stream-record userIdentity for TTL-driven REMOVE

- Sweeper-evicted items appear in the stream with `userIdentity: {Type: "Service", PrincipalId: "dynamodb.amazonaws.com"}`. User-driven `DeleteItem` REMOVE records have no `userIdentity` field — matches AWS exactly, so consumer code that filters on this distinction works.
- Internally: new `UserIdentity` enum (`.user`, `.ttl_sweeper`) threaded through `captureWrite` → `Stream.capture` → `StreamRecord`. The 6 existing capture sites pass `.user`; the sweeper passes `.ttl_sweeper` via a new identity parameter on `applyDeleteLocked`.

### Tests

- Zig unit tests: 489 → 497 (+8 — TTL spec, parse + render, status enum, CLI flag).
- Python conformance: 337 → 351 (+14 — schema persistence + 7 surface tests + 6 sweeper tests + 1 userIdentity contrast test).
- JS conformance: 70 → 74 (+4 surface tests; eviction is verified in Python).
- AWS CLI conformance: 22 → 25 (+3 surface tests).

### Documented divergences (intentional)

- **Sweep interval defaults to 5s**, not the AWS "up to 48h". Tunable.
- **Status transitions snap immediately**, no ENABLING / DISABLING transients.

### Strategic note

After v0.2.3 the DDB deferred list trims to PartiQL, PITR, and Imports/Exports — all candidates for future v0.2.x patches if demand surfaces. Global Tables and DAX stay out of scope indefinitely (multi-region and separate-protocol respectively). The next minor (v0.3.0) is still SQS per PRD §15.

## [0.2.2] — 2026-05-17

**Patch release: DynamoDB Streams.**

Per the [versioning scheme](#versioning-scheme), patches mark "significant pinned cuts of work". v0.2.0 explicitly deferred Streams alongside PartiQL / PITR / Global Tables / DAX / Imports/Exports; this release closes the biggest of those holes — change-data-capture is the canonical surface DDB users reach for, and it's the prerequisite for the future Lambda-trigger work on the post-v1 roadmap.

### Added — DynamoDBStreams sub-service (4 ops)

New target prefix `DynamoDBStreams_20120810.*` on the same port as the core DDB service. Opt-in via the same `--services s3,dynamodb` flag — the sub-service is part of DDB.

- **`ListStreams`** — `TableName` filter, `Limit` + `ExclusiveStartStreamArn` cursor, lex-ascending ARNs. Only stream-enabled tables appear.
- **`DescribeStream`** — returns the single open shard per stream with `StreamStatus`, `StreamViewType`, `CreationRequestDateTime`, `KeySchema`. Mismatched stream label in the ARN → `ResourceNotFoundException` (matches AWS's "label changes on re-enable" behaviour).
- **`GetShardIterator`** — all four iterator types (`TRIM_HORIZON`, `LATEST`, `AT_SEQUENCE_NUMBER`, `AFTER_SEQUENCE_NUMBER`). Returns an opaque base64-url token; clients must treat as opaque.
- **`GetRecords`** — `Limit` 1–1000 (default 1000), `INSERT`/`MODIFY`/`REMOVE` classification with per-view-type image filtering. Always returns `NextShardIterator` (single open shard never closes in our model). Records render with the standard `eventID`/`eventName`/`awsRegion`/`eventSource`/`dynamodb` shape, so consumers that key off those fields work out of the box.

### Added — table-side surface

- **`StreamSpecification` on `CreateTable` and `UpdateTable`** — all four view types (`NEW_IMAGE`, `OLD_IMAGE`, `NEW_AND_OLD_IMAGES`, `KEYS_ONLY`). `DescribeTable` echoes the spec plus `LatestStreamLabel` and `LatestStreamArn` when enabled. The spec persists across nanostack restart; records do not (matches LocalStack, keeps cold start sub-second).
- **Capture chokepoint = the storage backend.** Six write sites instrumented: `ddbPutItem`, `ddbDeleteItem`, `ddbUpdateItem`, and the three `apply*Locked` helpers used by `TransactWriteItems`. `BatchWriteItem` inherits capture for free since it routes through the public Put/Delete handlers.
- **Bounded ring buffer (1000 records per stream) + best-effort 24h age trim.** Approximates AWS's 24h retention; write-heavy streams may evict records younger than 24h once the bound is hit.

### Changed

- **`EnableKinesisStreamingDestination` / `DisableKinesisStreamingDestination`** — explicit `ValidationException` with message "Kinesis service is not enabled on this nanostack instance." (these live on the core DDB service, not the Streams sub-service). Previously fell through to the generic unknown-target message.

### Tests
- Zig unit tests: 472 → 489 (+17 — 11 ring-buffer + iterator tests, 5 wire parse-path tests, 1 view-type helper).
- Python conformance: 308 → 337 (+29 streams tests covering schema persistence, all four sub-service ops, view-type filtering, capture across all five write paths).
- JS conformance: 65 → 70 (+5 streams tests on `@aws-sdk/client-dynamodb-streams`).
- AWS CLI conformance: 19 → 22 (+3 streams tests on `aws dynamodbstreams`).

### Documented divergences (intentional)
- **Single open shard per stream** — no shard splitting / closed-shard lineage. Cleanly extensible later if anyone files an issue.
- **24h retention is approximate** — bound + age trim, not time-strict.
- **Records do not persist across restart** — matches LocalStack; the local-dev philosophy is "fresh server, fresh stream".

### Strategic note
This trims the DDB deferred list to PartiQL / PITR / Global Tables / DAX / Imports/Exports / TTL — five remaining patches' worth of work. The next minor (v0.3.0) is still SQS per PRD §15.

## [0.2.1] — 2026-05-17

**Patch release: DynamoDB polish — closes four post-ship gaps.**

Per the [versioning scheme](#versioning-scheme), patches mark "significant pinned cuts of work". v0.2.0 shipped DynamoDB with 18 ops; a post-ship audit surfaced four issues this release closes:

### Added
- **Items persist across nanostack restart.** v0.2.0's cold-start loader rebuilt the per-table schemas but never read items back from `<table>/items/<sha>.json`. `loadTableItems` now walks each table's items directory, parses each via `attribute_value.parseValue`, and re-inserts into `slot.items` keyed on the same composite key the write path uses. Corrupted files are skipped with a `std.log.warn`, matching the schema-load policy.
- **Reserved-words enforcement** for ConditionExpression / UpdateExpression / KeyConditionExpression / FilterExpression. New `src/wire/dynamodb/expressions/reserved_words.zig` carries the full 573-word AWS list (case-insensitive). Identifier tokens in operand position are rejected with `ValidationException` if they match; function-call identifiers (e.g. `attribute_exists`, `begins_with`, `list_append`) route through separate parse paths and remain legal. Error messages point at `ExpressionAttributeNames` as the fix.
- **JS conformance suite for DynamoDB** at `tests/conformance/js/dynamodb_*.test.ts` — 4 new test files (~14 tests) using `@aws-sdk/client-dynamodb` v3 + `@aws-sdk/util-dynamodb` marshall/unmarshall. Validates that the wire format works with the JS SDK's specific encoding of Sets, numbers, and binary.
- **AWS CLI v2 conformance suite for DynamoDB** at `tests/conformance/awscli/test_ddb_*.py` — 3 new test files (~9 tests) driving the real `aws dynamodb` v2 CLI via subprocess. Covers `create-table` / `describe-table` / `list-tables` / `put-item` / `get-item` / `update-item` / `delete-item` / `query` / `scan` with the CLI's flag-shape conventions.

### Changed
- **Python conformance backfill**: 15 new tests for expression shapes implemented in v0.2.0 but never exercised — `<>`, `<=`, `>=`, `OR`, `NOT`, parentheses, `IN`, `attribute_type`, `contains` (string + SS), `list_append`, SET subtraction, ADD on string set, DELETE from set, multi-section `SET ... REMOVE ...`, sort-key `<`/`<=`/`>=`, mixed-op TransactWriteItems (Put + Update + Delete + ConditionCheck atomically).
- **Pre-existing tests migrated off reserved attribute names** (`name`, `count`, `missing`, `items`, `drop`) to non-reserved equivalents (`label`, `tally`, `extra`, `elements`, `discard`) — these only surfaced as failures once reserved-word enforcement landed.

### Tests
- Python conformance: 286 → 308 (+22 — 1 restart + 3 reserved-word + 15 expression-shape + 1 mixed-tx + 2 fixture-derived).
- JS conformance: 51 → 65 (+14 DDB).
- AWS CLI conformance: 10 → 19 (+9 DDB).
- Zig unit tests: 461 → 465 (+4 reserved-word lookup unit tests).

### Strategic note
After v0.2.1, DynamoDB matches S3's three-SDK coverage promise — every shipped op is verified against Python (boto3), JS (aws-sdk-js v3), and the AWS CLI v2. The "accuracy beats LocalStack" claim survives SDK-specific quirks.

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
