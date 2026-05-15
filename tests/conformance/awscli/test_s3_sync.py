"""`aws s3 sync` conformance (up, down, idempotency).

The idempotency test is the headline case here: `sync` runs a client-side
diff against the destination (HEAD on each key, compare ETag + size) and
skips transfers when the source already matches. If our server's
HEAD/ListObjectsV2 responses drift from AWS, the second sync will
re-transfer files and the stdout assertion will catch it.
"""

import os
import time
from pathlib import Path

from conftest import run_aws


def _seed_dir(root: Path) -> dict[str, bytes]:
    """Three files of varying size under `root`. Returns name → bytes map.

    Each file's mtime is explicitly stamped to a whole-second value 60 s in
    the past. AWS S3 `LastModified` is second-precision (matches real AWS,
    which always emits `.000Z`). If we let the OS pick the source mtime
    naturally, macOS APFS gives sub-second precision, and on a fast
    localhost loop the upload happens in the same wall-clock second as the
    file write — `sync`'s diff then sees `src=N.123 > dest=N.000` and
    re-uploads, breaking idempotency. Real AWS users don't hit this because
    network latency always pushes the upload to a later whole second. We
    sidestep the artifact by forcing source mtimes to integer seconds
    safely in the past.
    """
    files = {
        "alpha.txt": b"a" * 10,
        "beta.bin": b"\x00\x01\x02\x03" * 8,
        "gamma.md": b"# header\n" * 4,
    }
    root.mkdir(parents=True, exist_ok=True)
    past = int(time.time()) - 60
    for name, body in files.items():
        path = root / name
        path.write_bytes(body)
        os.utime(path, (past, past))
    return files


def test_sync_uploads_directory(bucket: str, tmp_path: Path):
    """`aws s3 sync <dir> s3://b/p/` uploads every file."""
    src = tmp_path / "src"
    files = _seed_dir(src)

    run_aws("s3", "sync", str(src), f"s3://{bucket}/p/")

    listed = run_aws("s3api", "list-objects-v2", "--bucket", bucket,
                     "--prefix", "p/", json_output=True).json()
    contents = {c["Key"]: c["Size"] for c in (listed.get("Contents") or [])}
    expected = {f"p/{name}": len(body) for name, body in files.items()}
    assert contents == expected, f"sync upload mismatch: {contents}"


def test_sync_downloads_directory(bucket: str, tmp_path: Path):
    """`aws s3 sync s3://b/p/ <dir>` materialises remote keys to local files."""
    src = tmp_path / "src"
    files = _seed_dir(src)
    run_aws("s3", "sync", str(src), f"s3://{bucket}/p/")

    dst = tmp_path / "dst"
    run_aws("s3", "sync", f"s3://{bucket}/p/", str(dst))

    for name, body in files.items():
        assert (dst / name).read_bytes() == body, f"sync download mismatch on {name}"


def test_sync_second_run_is_noop(bucket: str, tmp_path: Path):
    """A second `aws s3 sync` against an unchanged source transfers nothing.

    Exercises the CLI's client-side diff (HEAD + size compare). If our
    HEAD-object response shape drifts from AWS, the diff misfires and
    the CLI re-uploads — which would surface as `upload:` lines in stdout.
    """
    src = tmp_path / "src"
    _seed_dir(src)

    # First sync: should transfer all three files.
    first = run_aws("s3", "sync", str(src), f"s3://{bucket}/p/")
    assert "upload:" in first.stdout, \
        f"first sync should report uploads, got stdout: {first.stdout!r}"

    # Second sync: must be a no-op. AWS CLI emits no upload/copy/delete lines
    # when source already matches destination.
    second = run_aws("s3", "sync", str(src), f"s3://{bucket}/p/")
    transferred = [line for line in second.stdout.splitlines()
                   if any(verb in line for verb in ("upload:", "copy:", "delete:"))]
    assert not transferred, \
        f"second sync should be a no-op, got transfer lines: {transferred!r}\n" \
        f"full stdout: {second.stdout!r}"
