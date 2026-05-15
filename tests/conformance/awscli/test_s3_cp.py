"""`aws s3 cp` conformance (single-object + recursive)."""

from pathlib import Path

from conftest import run_aws


def test_cp_upload_then_download_roundtrip(bucket: str, tmp_path: Path):
    """Round-trip a single object through `aws s3 cp` both directions."""
    payload = b"hello from awscli\nline two\n"
    src = tmp_path / "src.txt"
    src.write_bytes(payload)

    # Upload.
    run_aws("s3", "cp", str(src), f"s3://{bucket}/k")

    # Download to a new path.
    dst = tmp_path / "dst.txt"
    run_aws("s3", "cp", f"s3://{bucket}/k", str(dst))

    assert dst.read_bytes() == payload, "round-tripped bytes mismatch"


def test_cp_recursive_uploads_directory(bucket: str, tmp_path: Path):
    """`aws s3 cp <dir> s3://b/p/ --recursive` uploads every file under the dir."""
    src = tmp_path / "src"
    src.mkdir()
    (src / "alpha.txt").write_bytes(b"a")
    (src / "beta.txt").write_bytes(b"bb")
    nested = src / "sub"
    nested.mkdir()
    (nested / "gamma.txt").write_bytes(b"ggg")

    run_aws("s3", "cp", str(src), f"s3://{bucket}/prefix/", "--recursive")

    # List + verify the three keys exist with the right sizes.
    listed = run_aws("s3api", "list-objects-v2", "--bucket", bucket,
                     "--prefix", "prefix/", json_output=True).json()
    contents = {c["Key"]: c["Size"] for c in (listed.get("Contents") or [])}
    assert contents == {
        "prefix/alpha.txt": 1,
        "prefix/beta.txt": 2,
        "prefix/sub/gamma.txt": 3,
    }, f"unexpected upload result: {contents}"


def test_cp_recursive_downloads_directory(bucket: str, tmp_path: Path):
    """`aws s3 cp s3://b/p/ <dir> --recursive` materialises remote keys to local files."""
    # Seed three keys directly via the CLI.
    src = tmp_path / "seed"
    src.mkdir()
    (src / "one.txt").write_bytes(b"1")
    (src / "two.txt").write_bytes(b"22")
    (src / "three.txt").write_bytes(b"333")
    run_aws("s3", "cp", str(src), f"s3://{bucket}/p/", "--recursive")

    dst = tmp_path / "dst"
    run_aws("s3", "cp", f"s3://{bucket}/p/", str(dst), "--recursive")

    assert (dst / "one.txt").read_bytes() == b"1"
    assert (dst / "two.txt").read_bytes() == b"22"
    assert (dst / "three.txt").read_bytes() == b"333"
