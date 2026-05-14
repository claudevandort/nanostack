"""DeleteObjects (batch) conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    best_effort_delete_bucket,
    empty_bucket,
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
