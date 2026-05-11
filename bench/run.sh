#!/usr/bin/env bash
# Run the nanostack perf gate. Builds ReleaseFast + strip, then invokes the
# Go driver against the resulting binary. Exits with the driver's exit code
# (0 on pass, 1 on gate fail, 2 on harness error).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GO="${GO:-go}"

# 1. Build ReleaseFast + strip. The bench step in build.zig invokes the
#    same flags, but running run.sh directly should produce the gated binary.
echo "==> building nanostack (ReleaseFast, stripped)" >&2
zig build -Doptimize=ReleaseFast -Dstrip=true

# 2. Run the Go driver.
echo "==> running bench driver" >&2
cd bench/driver
exec "$GO" run . \
  --bin "$REPO_ROOT/zig-out/bin/nanostack" \
  --budgets "$REPO_ROOT/bench/budgets.json" \
  "$@"
