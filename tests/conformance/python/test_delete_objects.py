"""DeleteObjects (batch) conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    best_effort_delete_bucket,
    drain_versions,
    empty_bucket,
)


def _enable_versioning(s3, bucket: str) -> None:
    s3.put_bucket_versioning(
        Bucket=bucket,
        VersioningConfiguration={"Status": "Enabled"},
    )


def test_delete_objects_batch(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        keys = ["a", "b", "c"]
        for k in keys:
            s3.put_object(Bucket=bucket_name, Key=k, Body=b"v")

        out = s3.delete_objects(
            Bucket=bucket_name,
            Delete={"Objects": [{"Key": k} for k in keys]},
        )
        deleted = out.get("Deleted", []) or []
        assert len(deleted) == len(keys), f"expected {len(keys)} deleted entries, got {len(deleted)}"

        # All keys should be gone.
        for k in keys:
            with pytest.raises(ClientError):
                s3.head_object(Bucket=bucket_name, Key=k)
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


# AWS includes missing keys in `Deleted` (no Error) — DeleteObjects is
# idempotent per-key. Nanostack mirrors this.
def test_delete_objects_mixed_exist_missing(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="exists", Body=b"v")

        out = s3.delete_objects(
            Bucket=bucket_name,
            Delete={"Objects": [{"Key": "exists"}, {"Key": "never-existed"}]},
        )
        deleted = out.get("Deleted", []) or []
        errors = out.get("Errors", []) or []
        assert len(deleted) == 2, f"both keys should be in Deleted; got {len(deleted)} entries"
        assert len(errors) == 0, f"expected no per-key errors, got {len(errors)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_delete_objects_with_explicit_version_ids(s3, bucket_name):
    """AWS-exact: per-Object <VersionId> in DeleteObjects deletes exactly that
    version (not the current one). Other versions remain. Response echoes
    <VersionId> per <Deleted> entry. Drift table row 5.
    """
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        v1 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"first")["VersionId"]
        v2 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"second")["VersionId"]
        assert v1 and v2 and v1 != v2

        # Delete v1 explicitly. v2 must survive.
        out = s3.delete_objects(
            Bucket=bucket_name,
            Delete={"Objects": [{"Key": "k", "VersionId": v1}]},
        )
        deleted = out.get("Deleted", []) or []
        assert len(deleted) == 1, f"expected 1 deleted entry, got {len(deleted)}"
        assert deleted[0].get("Key") == "k"
        assert deleted[0].get("VersionId") == v1, \
            f"expected VersionId={v1} echoed, got {deleted[0].get('VersionId')!r}"
        # Not a delete-marker creation — should be absent or False.
        assert not deleted[0].get("DeleteMarker"), \
            f"unexpected DeleteMarker on per-version delete: {deleted[0]!r}"

        # Confirm versions: v2 alive, v1 gone.
        versions = {v["VersionId"] for v in s3.list_object_versions(Bucket=bucket_name).get("Versions", []) or []}
        assert v2 in versions, f"v2 should still exist: {versions}"
        assert v1 not in versions, f"v1 should be permanently deleted: {versions}"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
