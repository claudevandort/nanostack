"""`aws s3 ls` / `mv` / `rm --recursive` conformance.

`mv` is composite (CopyObject + DeleteObject under the hood); `rm
--recursive` exercises ListObjectsV2 + per-key DeleteObject in a loop.
Both surface bugs that boto3's low-level coverage misses.
"""

from pathlib import Path

from conftest import run_aws


def _put_key(bucket: str, key: str, body: bytes, tmp_path: Path) -> None:
    src = tmp_path / "in"
    src.write_bytes(body)
    run_aws("s3", "cp", str(src), f"s3://{bucket}/{key}")


def test_ls_lists_bucket_contents(bucket: str, tmp_path: Path):
    """`aws s3 ls s3://b/` prints every top-level key."""
    _put_key(bucket, "alpha.txt", b"a", tmp_path)
    _put_key(bucket, "beta.txt", b"bb", tmp_path)
    _put_key(bucket, "gamma.txt", b"ggg", tmp_path)

    result = run_aws("s3", "ls", f"s3://{bucket}/")
    # ls prints one line per key, e.g.:
    #   2026-05-15 ...   1 alpha.txt
    for expected in ("alpha.txt", "beta.txt", "gamma.txt"):
        assert expected in result.stdout, \
            f"expected {expected!r} in ls output, got: {result.stdout!r}"


def test_mv_moves_object(bucket: str, tmp_path: Path):
    """`aws s3 mv s3://b/src s3://b/dst` copies + deletes the source."""
    _put_key(bucket, "src", b"move-me", tmp_path)

    run_aws("s3", "mv", f"s3://{bucket}/src", f"s3://{bucket}/dst")

    # Source gone, destination present with the same bytes.
    listed = run_aws("s3api", "list-objects-v2", "--bucket", bucket,
                     json_output=True).json()
    keys = {c["Key"] for c in (listed.get("Contents") or [])}
    assert "src" not in keys, f"source still present after mv: {keys}"
    assert "dst" in keys, f"destination missing after mv: {keys}"

    dst_local = tmp_path / "out"
    run_aws("s3", "cp", f"s3://{bucket}/dst", str(dst_local))
    assert dst_local.read_bytes() == b"move-me"


def test_rm_recursive_deletes_prefix(bucket: str, tmp_path: Path):
    """`aws s3 rm s3://b/prefix/ --recursive` removes every key under prefix.

    Also seeds one key OUTSIDE the prefix to verify the recursive delete
    is correctly bounded.
    """
    _put_key(bucket, "prefix/one", b"1", tmp_path)
    _put_key(bucket, "prefix/two", b"22", tmp_path)
    _put_key(bucket, "prefix/sub/three", b"333", tmp_path)
    _put_key(bucket, "untouched", b"keep-me", tmp_path)

    run_aws("s3", "rm", f"s3://{bucket}/prefix/", "--recursive")

    listed = run_aws("s3api", "list-objects-v2", "--bucket", bucket,
                     json_output=True).json()
    keys = {c["Key"] for c in (listed.get("Contents") or [])}
    assert keys == {"untouched"}, \
        f"expected only 'untouched' to survive recursive rm, got: {keys}"
