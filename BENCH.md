# nanostack — Performance Gate

The PRD's "snappy" promise is enforced by a perf gate that runs in CI on every push. This document explains what we measure, the budgets we hold ourselves to, and the latest numbers from the most recent main-branch run.

## How to run

```sh
zig build bench
```

Builds nanostack in `ReleaseFast` with strip, then runs `bench/driver` (a small Go program that drives signed AWS SDK requests at the binary and measures cold start, idle RSS, request latency, and throughput). Exits 0 if every gated metric is within budget, non-zero otherwise.

## What we measure

All gated budgets come from [`docs/PRD.md`](docs/PRD.md) §12. Source of truth lives in [`bench/budgets.json`](bench/budgets.json).

| Metric | Budget | Gated in M2.5? |
|---|---|---|
| Cold start to bound listener | ≤ 500 ms | ✓ |
| Idle RSS (5 s after start) | ≤ 30 MB | ✓ |
| Stripped binary size (ReleaseFast) | ≤ 20 MB | ✓ |
| Wipe-restart (`--ephemeral`) | ≤ 100 ms | ✓ |
| Warm p50 PutObject (1 KB) | ≤ 1 ms | M3 activates |
| Warm p99 PutObject (1 KB) | ≤ 5 ms | M3 activates |
| Warm p99 GetObject (≤ 1 MB) | ≤ 5 ms | M3 activates |
| Throughput, sequential 1 KB PutObject | ≥ 50 000 req/s | M3 activates |

We also measure bucket-op latency and HeadBucket throughput as **informational**. Those numbers don't gate; they're just visible in the report so we can spot drift.

## Methodology notes

- **Cold start** is the median wall time over 5 invocations of `nanostack --self-test-ready` on rotating ports. The `--self-test-ready` flag loads the binary, parses args, **binds the TCP listener** on the configured port, then exits cleanly. We deliberately skip httpz framework setup in this mode — the bench harness measures the full "ready to accept connections" path separately (see the wipe-restart metric and the latency probe).
- **Wipe-restart** spawns nanostack, kills it, respawns on the same port, and measures time-to-first-TCP-accept. Median of 5 cycles. This is the metric users actually care about during tight test loops.
- **Idle RSS** samples `/proc/<pid>/status` `VmRSS` (Linux) or `ps -o rss=` (macOS) three times at 1 s intervals after a 5 s warm-up, takes the max. Reported in MB.
- **Latencies / throughput** drive signed requests via `aws-sdk-go-v2` so the numbers include the SDK round-trip + SigV4 verification cost — i.e. what users see.

## Current baseline

Measured on the most recent main-branch CI run (Linux, ReleaseFast + strip).

| Metric | Measured | Budget | Margin |
|---|---|---|---|
| Cold start | ~1.2 ms | 500 ms | ~400× headroom |
| Idle RSS | ~11 MB | 30 MB | ~2.7× headroom |
| Binary size | ~0.55 MB | 20 MB | ~36× headroom |
| Wipe-restart | ~1.5 ms | 100 ms | ~65× headroom |
| HeadBucket p50 | ~0.27 ms | — | informational |
| HeadBucket p99 | ~0.56 ms | — | informational |
| ListBuckets p99 | ~0.62 ms | — | informational |
| HeadBucket throughput | ~11 000 req/s (4 workers) | — | informational |

These are dev-machine numbers; CI runners will differ. The point of the gate is to catch regressions, not to certify absolute performance — the headroom on every gated metric is large enough that a real regression will still be obvious even on a slow runner.

## Negative smoke

To confirm the gate fails on regression, drop a `time.sleep(200ms)` into the request handler on a throwaway branch. The latency metrics still aren't gated, so this won't trip a build today; once M3 lands, p99 PutObject will.

## What the gate catches today

A regression in any of:
- `--self-test-ready` startup time (binary load + arg parse + port bind).
- Idle memory footprint of the binary.
- Stripped binary size (catches accidental debug-info leaks or dependency bloat).
- Wipe-restart time (catches lock contention, stale file handle issues, slow `defer` paths).

What it doesn't catch yet: per-request latency growth. M3 lights up the PutObject/GetObject budgets at the same time as the operations themselves.
