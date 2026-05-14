#!/usr/bin/env bash
# Run the nanostack perf gate. Builds ReleaseFast + strip, then invokes the
# Python driver against the resulting binary. Exits with the driver's exit
# code (0 on pass, 1 on gate fail, 2 on harness error).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PYTHON="${PYTHON:-python3}"

# 1. Build ReleaseFast + strip. The bench step in build.zig invokes the
#    same flags, but running run.sh directly should produce the gated binary.
echo "==> building nanostack (ReleaseFast, stripped)" >&2
zig build -Doptimize=ReleaseFast -Dstrip=true

# 2. Make sure the bench deps are present in the active interpreter. If
#    you want to use a venv, set PYTHON=/path/to/venv/bin/python.
echo "==> ensuring boto3 is available" >&2
if ! "$PYTHON" -c "import boto3" 2>/dev/null; then
  echo "boto3 not found in $("$PYTHON" -c 'import sys;print(sys.executable)'); install with: $PYTHON -m pip install -r bench/requirements.txt" >&2
  exit 2
fi

# 3. Run the Python driver.
echo "==> running bench driver" >&2
exec "$PYTHON" "$REPO_ROOT/bench/driver.py" \
  --bin "$REPO_ROOT/zig-out/bin/nanostack" \
  --budgets "$REPO_ROOT/bench/budgets.json" \
  "$@"
