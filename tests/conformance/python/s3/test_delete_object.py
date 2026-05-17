"""DeleteObject conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    seed_object,
)


def test_delete_object_happy_path(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"v")
    try:
        s3.delete_object(Bucket=bucket_name, Key="k")

        with pytest.raises(ClientError) as ei:
            s3.head_object(Bucket=bucket_name, Key="k")
        assert aws_http_status(ei.value) == 404, f"expected 404, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


# AWS DeleteObject is idempotent — deleting a missing key returns 204.
def test_delete_object_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        # Should succeed without error.
        s3.delete_object(Bucket=bucket_name, Key="never-existed")
    finally:
        best_effort_delete_bucket(s3, bucket_name)
