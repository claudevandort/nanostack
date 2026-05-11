# nanostack — Performance Gate

The PRD's "snappy" promise is enforced by a perf gate that runs in CI on every push. This document explains what we measure, the budgets we hold ourselves to, and the latest numbers from the most recent main-branch run.

## How to run

```sh
zig build bench
```

Builds nanostack in `ReleaseFast` with strip, then runs `bench/driver` (a small Go program that drives signed AWS SDK requests at the binary and measures cold start, idle RSS, request latency, and throughput). Exits 0 if every gated metric is within budget, non-zero otherwise.

## How to run a specific backend

```sh
zig build bench -- --backend mem   # default; ephemeral in-memory state
zig build bench -- --backend fs    # filesystem-backed; uses a temp dir
```

CI runs both. Each backend can have a different budget for metrics where the physics genuinely differ (`fs` pays an fsync per write, `mem` doesn't).

## What we measure

All gated budgets come from [`docs/PRD.md`](docs/PRD.md) §12. Source of truth lives in [`bench/budgets.json`](bench/budgets.json).

| Metric | mem | fs |
|---|---|---|
| Cold start to bound listener | ≤ 500 ms | ≤ 500 ms |
| Idle RSS (5 s after start) | ≤ 30 MB | ≤ 30 MB |
| Stripped binary size (ReleaseFast) | ≤ 20 MB | ≤ 20 MB |
| Wipe-restart | ≤ 100 ms | ≤ 500 ms |
| Warm p50 PutObject (1 KB) | ≤ 1 ms | ≤ 3 ms |
| Warm p99 PutObject (1 KB) | ≤ 5 ms | ≤ 5 ms |
| Warm p99 GetObject (≤ 1 MB) | ≤ 5 ms | ≤ 5 ms |
| Concurrent PutObject 1 KB throughput | ≥ 5 000 req/s | ≥ 500 req/s |

All eight budgets are gated as of M3.

We also measure bucket-op latency and HeadBucket throughput as **informational**. Those numbers don't gate; they're just visible in the report so we can spot drift.

## Methodology notes

- **Cold start** is the median wall time over 5 invocations of `nanostack --self-test-ready` on rotating ports. The `--self-test-ready` flag loads the binary, parses args, **binds the TCP listener** on the configured port, then exits cleanly. We deliberately skip httpz framework setup in this mode — the bench harness measures the full "ready to accept connections" path separately (see the wipe-restart metric and the latency probe).
- **Wipe-restart** spawns nanostack, kills it, respawns on the same port, and measures time-to-first-TCP-accept. Median of 5 cycles. This is the metric users actually care about during tight test loops.
- **Idle RSS** samples `/proc/<pid>/status` `VmRSS` (Linux) or `ps -o rss=` (macOS) three times at 1 s intervals after a 5 s warm-up, takes the max. Reported in MB.
- **Latencies / throughput** drive signed requests via `aws-sdk-go-v2` so the numbers include the SDK round-trip + SigV4 verification cost — i.e. what users see.

## Current baseline (M3 dev machine, Linux, ReleaseFast + strip)

| Metric | mem | fs | mem budget | fs budget |
|---|---|---|---|---|
| Cold start | ~1.2 ms | ~1.3 ms | 500 ms | 500 ms |
| Idle RSS | ~11 MB | ~11 MB | 30 MB | 30 MB |
| Binary size | ~0.65 MB | ~0.65 MB | 20 MB | 20 MB |
| Wipe-restart | ~1.5 ms | ~180 ms | 100 ms | 500 ms |
| Put p50 (1 KB) | ~0.31 ms | ~1.05 ms | 1 ms | 3 ms |
| Put p99 (1 KB) | ~0.74 ms | ~2.05 ms | 5 ms | 5 ms |
| Get p99 (1 KB) | ~0.63 ms | ~0.63 ms | 5 ms | 5 ms |
| Put throughput (32 workers) | ~10 600 req/s | ~1 350 req/s | 5 000 req/s | 500 req/s |
| HeadBucket p99 (info) | ~0.58 ms | ~0.55 ms | — | — |

These are dev-machine numbers; CI runners will differ. The point of the gate is to catch regressions, not certify absolute performance. The headroom on every gated metric is wide enough that a real regression will still be obvious even on a slow runner.

## Negative smoke

To confirm the gate fails on regression, drop a `time.sleep(200ms)` into the request handler on a throwaway branch. The latency metrics still aren't gated, so this won't trip a build today; once M3 lands, p99 PutObject will.

## What the gate catches today

A regression in any of:
- `--self-test-ready` startup time (binary load + arg parse + port bind).
- Idle memory footprint of the binary.
- Stripped binary size (catches accidental debug-info leaks or dependency bloat).
- Wipe-restart time (catches lock contention, stale file handle issues, slow `defer` paths).

What it doesn't catch yet: per-request latency growth. M3 lights up the PutObject/GetObject budgets at the same time as the operations themselves.
