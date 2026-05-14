"""nanostack perf gate.

Spawns ReleaseFast nanostack, drives bucket-level operations through the
official AWS Python SDK (boto3), and emits a JSON report comparing every
PRD §12 metric against its budget. Exits non-zero if any gated metric
regresses past budget.

Run locally: `zig build bench` (which wraps `bench/run.sh`).
Run in CI: same.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import socket
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from botocore.client import Config


# -----------------------------------------------------------------------------
# Budget schema (matches bench/budgets.json)


def effective_target(metric: dict) -> tuple[float, str, bool]:
    """Returns (target, comparison, ok). Mirrors Go's `effectiveTarget`."""
    if metric.get("comparison") == "ge":
        tm = metric.get("target_min", 0) or 0
        if tm > 0:
            return tm, "ge", True
        return 0, "ge", False
    t = metric.get("target", 0) or 0
    if t > 0:
        return t, "le", True
    return 0, "le", False


def load_budgets(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def record_metric(metrics: list[dict], key: str, measured: float) -> list[dict]:
    for m in metrics:
        if m.get("key") != key:
            continue
        m["measured"] = measured
        target, comparison, ok = effective_target(m)
        passed = True
        if ok:
            passed = measured >= target if comparison == "ge" else measured <= target
        m["pass"] = passed
        return metrics
    return metrics


def any_gate_failed(b: dict) -> bool:
    for m in b.get("metrics", []):
        if not m.get("gate"):
            continue
        if not m.get("pass"):
            return True
    return False


# -----------------------------------------------------------------------------
# Process / measurement helpers


def spawn_nanostack(bin_path: str, port: int, extra: list[str] | None = None) -> subprocess.Popen:
    args = [bin_path, "--port", str(port)] + list(extra or [])
    # New session = new process group, so we can kill the whole tree.
    return subprocess.Popen(args, stdout=sys.stderr, stderr=sys.stderr, start_new_session=True)


def backend_args(mode: str, temp_base: str) -> list[str]:
    if mode in ("fs", ""):
        d = tempfile.mkdtemp(prefix="ns-bench-fs-", dir=temp_base)
        return ["--data-dir", d]
    raise ValueError(f"unknown --backend {mode!r} (only fs is supported)")


def wait_tcp(port: int, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.025):
                return
        except (OSError, ConnectionRefusedError):
            pass
    raise RuntimeError(f"nanostack did not bind :{port} within {timeout}s")


def kill_process_group(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), 9)  # SIGKILL
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def measure_cold_start(bin_path: str, port: int, samples: int, temp_base: str) -> float:
    """Spawns nanostack with `--self-test-ready` `samples` times; median wall time in ms."""
    durs: list[float] = []
    for i in range(samples):
        d = tempfile.mkdtemp(prefix="ns-coldstart-", dir=temp_base)
        start = time.perf_counter()
        rc = subprocess.run(
            [bin_path, "--port", str(port + i), "--self-test-ready", "--data-dir", d],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode
        if rc != 0:
            raise RuntimeError(f"self-test-ready failed (rc={rc})")
        durs.append((time.perf_counter() - start) * 1000)
    return _median(durs)


def measure_binary_size(bin_path: str) -> float:
    """Size in MB."""
    return os.path.getsize(bin_path) / (1024 * 1024)


def measure_idle_rss(pid: int, samples: int) -> float:
    """Max VmRSS in MB across `samples` samples 1s apart, after a 5s warm-up."""
    time.sleep(5)
    peak = 0.0
    for _ in range(samples):
        rss = _read_rss_mb(pid)
        if rss > peak:
            peak = rss
        time.sleep(1)
    return peak


def _read_rss_mb(pid: int) -> float:
    if platform.system() == "Linux":
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if not line.startswith("VmRSS:"):
                    continue
                kb = float(line.split()[1])
                return kb / 1024
        raise RuntimeError("VmRSS not found in /proc/<pid>/status")
    # macOS / generic fallback via ps.
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).decode().strip()
    return float(out) / 1024


def measure_wipe_restart(bin_path: str, port: int, samples: int, extra: list[str]
                         ) -> tuple[float, subprocess.Popen | None]:
    """Kill+respawn `samples` times; returns (median time-to-bind ms, final live proc)."""
    durs: list[float] = []
    current: subprocess.Popen | None = None
    for _ in range(samples):
        if current is not None:
            kill_process_group(current)
            time.sleep(0.02)
        start = time.perf_counter()
        cmd = spawn_nanostack(bin_path, port, extra)
        try:
            wait_tcp(port, 5)
        except RuntimeError:
            kill_process_group(cmd)
            raise
        durs.append((time.perf_counter() - start) * 1000)
        current = cmd
    return _median(durs), current


# -----------------------------------------------------------------------------
# Latency / throughput via AWS SDK (real signed requests)


def new_s3_client(port: int):
    return boto3.client(
        "s3",
        endpoint_url=f"http://127.0.0.1:{port}",
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            retries={"max_attempts": 1, "mode": "standard"},
            connect_timeout=5,
            read_timeout=10,
            max_pool_connections=64,
        ),
    )


def measure_latency_head_bucket(c, bucket: str, n: int) -> tuple[float, float]:
    durs: list[float] = []
    for _ in range(n):
        start = time.perf_counter()
        try:
            c.head_bucket(Bucket=bucket)
        except Exception:
            continue
        durs.append((time.perf_counter() - start) * 1000)
    return _percentile(durs, 50), _percentile(durs, 99)


def measure_list_buckets_latency(c, n: int) -> tuple[float, float]:
    durs: list[float] = []
    for _ in range(n):
        start = time.perf_counter()
        try:
            c.list_buckets()
        except Exception:
            continue
        durs.append((time.perf_counter() - start) * 1000)
    return _percentile(durs, 50), _percentile(durs, 99)


def measure_head_bucket_throughput(port: int, bucket: str, workers: int, duration: float) -> float:
    """Worker count threads, each with its OWN boto3 client (shared client serialises)."""
    ops = 0
    ops_lock = threading.Lock()
    end_at = time.monotonic() + duration

    def worker():
        nonlocal ops
        c = new_s3_client(port)
        local = 0
        while time.monotonic() < end_at:
            try:
                c.head_bucket(Bucket=bucket)
                local += 1
            except Exception:
                pass
        with ops_lock:
            ops += local

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(worker) for _ in range(workers)]
        for f in futs:
            f.result()
    return ops / duration


def measure_put_object_latency(c, bucket: str, body: bytes, n: int) -> tuple[float, float]:
    durs: list[float] = []
    for i in range(n):
        key = f"p/{i}"
        start = time.perf_counter()
        try:
            c.put_object(Bucket=bucket, Key=key, Body=body)
        except Exception:
            continue
        durs.append((time.perf_counter() - start) * 1000)
    return _percentile(durs, 50), _percentile(durs, 99)


def measure_get_object_latency(c, bucket: str, body: bytes, n: int) -> float:
    """Seed one key, loop GetObject n times against it; returns p99 ms."""
    key = "g/probe"
    try:
        c.put_object(Bucket=bucket, Key=key, Body=body)
    except Exception:
        return float("nan")
    durs: list[float] = []
    for _ in range(n):
        start = time.perf_counter()
        try:
            out = c.get_object(Bucket=bucket, Key=key)
            out["Body"].read()
            out["Body"].close()
        except Exception:
            continue
        durs.append((time.perf_counter() - start) * 1000)
    return _percentile(durs, 99)


def measure_multipart_concurrent(port: int, bucket: str, parts: int, part_size: int, n: int
                                 ) -> tuple[float, float]:
    """Per-iter: Initiate → `parts` concurrent UploadParts → Complete. Returns (p50, p99) wall."""
    body = b"A" * part_size
    durs: list[float] = []
    primary = new_s3_client(port)

    def upload_one_part(client_ref: dict, key: str, upload_id: str, pn: int) -> tuple[int, str | None]:
        # Per-thread client: boto3 client is technically thread-safe, but
        # mirror the Go driver's "one client per worker for unsynchronised
        # concurrency" by re-using one shared client here (cheap) and
        # relying on max_pool_connections.
        c = client_ref["c"]
        out = c.upload_part(Bucket=bucket, Key=key, UploadId=upload_id,
                            PartNumber=pn, Body=body)
        return pn, out["ETag"]

    for i in range(n):
        key = f"mp/{i}"
        start = time.perf_counter()
        try:
            init = primary.create_multipart_upload(Bucket=bucket, Key=key)
        except Exception:
            continue
        upload_id = init["UploadId"]

        client_ref = {"c": primary}
        results: list[tuple[int, str | None]] = []
        failed = False
        with ThreadPoolExecutor(max_workers=parts) as ex:
            futs = [ex.submit(upload_one_part, client_ref, key, upload_id, pn + 1)
                    for pn in range(parts)]
            for f in as_completed(futs):
                try:
                    results.append(f.result())
                except Exception:
                    failed = True
        if failed:
            continue

        results.sort(key=lambda x: x[0])
        completed = [{"ETag": etag, "PartNumber": pn} for pn, etag in results]
        try:
            primary.complete_multipart_upload(
                Bucket=bucket, Key=key, UploadId=upload_id,
                MultipartUpload={"Parts": completed},
            )
        except Exception:
            continue
        durs.append((time.perf_counter() - start) * 1000)
    return _percentile(durs, 50), _percentile(durs, 99)


def measure_put_object_throughput(port: int, bucket: str, body: bytes,
                                  workers: int, duration: float) -> float:
    ops = 0
    ops_lock = threading.Lock()
    end_at = time.monotonic() + duration

    def worker(w: int):
        nonlocal ops
        c = new_s3_client(port)
        local = 0
        while time.monotonic() < end_at:
            key = f"t/{w}/{local}"
            try:
                c.put_object(Bucket=bucket, Key=key, Body=body)
                local += 1
            except Exception:
                pass
        with ops_lock:
            ops += local

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(worker, w) for w in range(workers)]
        for f in futs:
            f.result()
    return ops / duration


# -----------------------------------------------------------------------------
# Stats helpers


def _median(xs: list[float]) -> float:
    return _percentile(xs, 50)


def _percentile(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    s = sorted(xs)
    rank = (p / 100.0) * (len(s) - 1)
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return s[lo]
    frac = rank - lo
    return s[lo] * (1 - frac) + s[hi] * frac


# -----------------------------------------------------------------------------
# Pretty-print


def print_table(b: dict) -> None:
    print(file=sys.stderr)
    print(f"nanostack perf gate (backend={b.get('backend', '')})", file=sys.stderr)
    print("-" * 92, file=sys.stderr)
    print(f"{'metric':<30} {'measured':>12} {'target':>14} {'gate':>10} result", file=sys.stderr)
    print("-" * 92, file=sys.stderr)
    for m in b.get("metrics", []):
        _print_row(m)
    info = b.get("informational_metrics", [])
    if info:
        print(file=sys.stderr)
        print("informational (no gate)", file=sys.stderr)
        print("-" * 92, file=sys.stderr)
        for m in info:
            _print_row(m)


def _print_row(m: dict) -> None:
    measured = "-"
    if "measured" in m:
        measured = f"{m['measured']:.3f} {m['unit']}"
    target_s = "-"
    t, comp, ok = effective_target(m)
    if ok:
        if comp == "ge":
            target_s = f"≥ {t:.0f} {m['unit']}"
        else:
            target_s = f"≤ {t:.3f} {m['unit']}"
    gate = "yes" if m.get("gate") else "no"
    result = "n/a"
    if "pass" in m:
        result = "PASS" if m["pass"] else "FAIL"
    print(f"{m['key']:<30} {measured:>12} {target_s:>14} {gate:>10} {result}", file=sys.stderr)


# -----------------------------------------------------------------------------
# Main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="zig-out/bin/nanostack", help="path to ReleaseFast nanostack")
    ap.add_argument("--budgets", default="bench/budgets.json")
    ap.add_argument("--out", default="", help="if set, write JSON to this path (default stdout)")
    ap.add_argument("--port", type=int, default=14990)
    ap.add_argument("--backend", default="fs", help="storage backend (only fs is supported)")
    args = ap.parse_args()

    b = load_budgets(args.budgets)
    b["backend"] = args.backend

    temp_base = os.environ.get("RUNNER_TEMP") or os.path.join(tempfile.gettempdir(), "nanostack-bench")
    os.makedirs(temp_base, exist_ok=True)
    extra = backend_args(args.backend, temp_base)

    # 1. Binary size.
    b["metrics"] = record_metric(b["metrics"], "binary_size_mb", measure_binary_size(args.bin))

    # 2. Cold start.
    cs = measure_cold_start(args.bin, args.port + 10, 5, temp_base)
    b["metrics"] = record_metric(b["metrics"], "cold_start_ms", cs)

    # 3. Long-lived nanostack for idle-RSS + latency + throughput.
    live = spawn_nanostack(args.bin, args.port, extra)
    try:
        wait_tcp(args.port, 5)
        client = new_s3_client(args.port)
        bucket = "bench-bucket"
        client.create_bucket(Bucket=bucket)

        # 4. Idle RSS.
        rss = measure_idle_rss(live.pid, 3)
        b["metrics"] = record_metric(b["metrics"], "idle_rss_mb", rss)

        # 5. Informational bucket-op latency / throughput.
        hb_p50, hb_p99 = measure_latency_head_bucket(client, bucket, 10_000)
        b["informational_metrics"] = record_metric(b["informational_metrics"], "head_bucket_p50_ms", hb_p50)
        b["informational_metrics"] = record_metric(b["informational_metrics"], "head_bucket_p99_ms", hb_p99)

        _, lb_p99 = measure_list_buckets_latency(client, 1000)
        b["informational_metrics"] = record_metric(b["informational_metrics"], "list_buckets_p99_ms", lb_p99)

        hb_rps = measure_head_bucket_throughput(args.port, bucket, 4, 5)
        b["informational_metrics"] = record_metric(b["informational_metrics"], "head_bucket_throughput_rps", hb_rps)

        # 5b. Object-op latency + throughput (1 KiB body per PRD §12).
        body = b"x" * 1024
        po_p50, po_p99 = measure_put_object_latency(client, bucket, body, 10_000)
        b["metrics"] = record_metric(b["metrics"], "put_object_p50_ms", po_p50)
        b["metrics"] = record_metric(b["metrics"], "put_object_p99_ms", po_p99)

        go_p99 = measure_get_object_latency(client, bucket, body, 10_000)
        b["metrics"] = record_metric(b["metrics"], "get_object_p99_ms", go_p99)

        po_rps = measure_put_object_throughput(args.port, bucket, body, 32, 5)
        b["metrics"] = record_metric(b["metrics"], "put_object_throughput_rps", po_rps)

        # 5c. Multipart upload — 5 parts × 5 MiB concurrent. 20 iters for stable p99.
        mp_p50, mp_p99 = measure_multipart_concurrent(args.port, bucket, 5, 5 * 1024 * 1024, 20)
        b["informational_metrics"] = record_metric(b["informational_metrics"], "multipart_5x5mib_p50_ms", mp_p50)
        b["metrics"] = record_metric(b["metrics"], "multipart_5x5mib_p99_ms", mp_p99)
    finally:
        kill_process_group(live)
        live = None

    # 6. Wipe-restart on the same port + backend.
    wr, final_cmd = measure_wipe_restart(args.bin, args.port, 5, extra)
    b["metrics"] = record_metric(b["metrics"], "wipe_restart_ms", wr)
    kill_process_group(final_cmd)

    # 7. Emit JSON.
    out_json = json.dumps(b, indent=2)
    if args.out:
        with open(args.out, "w") as f:
            f.write(out_json + "\n")
    else:
        sys.stdout.write(out_json + "\n")

    # 8. Pretty table to stderr + exit code.
    print_table(b)
    if any_gate_failed(b):
        print("\nGATE FAILED", file=sys.stderr)
        return 1
    print("\nall gated metrics within budget", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
