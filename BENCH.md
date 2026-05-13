# nanostack — Performance Gate

**Version:** v0.0.1 (2026-05-13)

The PRD's "snappy" promise is enforced by a perf gate that runs in CI on every push. This document explains what we measure, the budgets we hold ourselves to, and the latest numbers from the most recent main-branch run.

**Note on CI numbers:** GitHub-hosted runners typically come in ~2× slower than the dev-machine baseline below (slower disks, shared CPU). All budgets allow for this — the numbers below have ~3× headroom on every gated metric.

## How to run

```sh
zig build bench
```

Builds nanostack in `ReleaseFast` with strip, then runs `bench/driver` (a small Go program that drives signed AWS SDK requests at the binary and measures cold start, idle RSS, request latency, and throughput). Exits 0 if every gated metric is within budget, non-zero otherwise.

The harness spawns nanostack with `--data-dir <mktemp>` so every run starts from a clean state. The pre-M7 in-memory backend was removed (see PRD §17a, 2026-05-13).

## What we measure

All gated budgets come from [`docs/PRD.md`](docs/PRD.md) §12. Source of truth lives in [`bench/budgets.json`](bench/budgets.json).

| Metric | Budget |
|---|---|
| Cold start to bound listener | ≤ 500 ms |
| Idle RSS (5 s after start) | ≤ 30 MB |
| Stripped binary size (ReleaseFast) | ≤ 20 MB |
| Wipe-restart | ≤ 500 ms |
| Warm p50 PutObject (1 KB) | ≤ 3 ms |
| Warm p99 PutObject (1 KB) | ≤ 5 ms |
| Warm p99 GetObject (≤ 1 MB) | ≤ 5 ms |
| Concurrent PutObject 1 KB throughput | ≥ 500 req/s |
| Multipart upload p99 (5 × 5 MiB, concurrent) | ≤ 500 ms |

We also measure bucket-op latency, HeadBucket throughput, and multipart p50 as **informational**. Those numbers don't gate; they're just visible in the report so we can spot drift.

## Methodology notes

- **Cold start** is the median wall time over 5 invocations of `nanostack --self-test-ready` on rotating ports + fresh per-probe `--data-dir`. The `--self-test-ready` flag loads the binary, parses args, **binds the TCP listener** on the configured port, then exits cleanly. We deliberately skip httpz framework setup in this mode — the bench harness measures the full "ready to accept connections" path separately (see the wipe-restart metric and the latency probe).
- **Wipe-restart** spawns nanostack, kills it, respawns on the same port, and measures time-to-first-TCP-accept. Median of 5 cycles. This is the metric users actually care about during tight test loops.
- **Idle RSS** samples `/proc/<pid>/status` `VmRSS` (Linux) or `ps -o rss=` (macOS) three times at 1 s intervals after a 5 s warm-up, takes the max. Reported in MB.
- **Latencies / throughput** drive signed requests via `aws-sdk-go-v2` so the numbers include the SDK round-trip + SigV4 verification cost — i.e. what users see.
- **Multipart** runs 20 iterations of {InitiateMPU → 5 concurrent UploadParts of 5 MiB each → CompleteMPU} and records total wall-time per iteration. The budget is ~3× the locally-measured baseline to allow for CI-runner disk variance.

## Current baseline (post-cleanup dev machine, Linux, ReleaseFast + strip)

| Metric | Measured | Budget |
|---|---|---|
| Cold start | ~1.9 ms | 500 ms |
| Idle RSS | ~11.5 MB | 30 MB |
| Binary size | ~0.82 MB | 20 MB |
| Wipe-restart | ~175 ms | 500 ms |
| Put p50 (1 KB) | ~0.81 ms | 3 ms |
| Put p99 (1 KB) | ~1.29 ms | 5 ms |
| Get p99 (1 KB) | ~0.57 ms | 5 ms |
| Put throughput (32 workers) | ~1 760 req/s | 500 req/s |
| Multipart p99 (5 × 5 MiB) | ~156 ms | 500 ms |
| HeadBucket p99 (info) | ~0.49 ms | — |

These are dev-machine numbers; CI runners will differ. The point of the gate is to catch regressions, not certify absolute performance. The headroom on every gated metric is wide enough that a real regression will still be obvious even on a slow runner.

## Negative smoke

To confirm the gate fails on regression, drop a `time.sleep(200ms)` into the request handler on a throwaway branch. The latency budget on PutObject p99 will trip the gate.

## What the gate catches

A regression in any of:
- `--self-test-ready` startup time (binary load + arg parse + port bind).
- Idle memory footprint of the binary.
- Stripped binary size (catches accidental debug-info leaks or dependency bloat).
- Wipe-restart time (catches lock contention, stale file handle issues, slow `defer` paths).
- PutObject / GetObject latency (catches per-request slowdowns).
- PutObject throughput (catches concurrency regressions).
- Multipart upload p99 (catches multipart-specific regressions in chunked write paths).
