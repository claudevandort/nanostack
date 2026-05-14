"""CreateBucket conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, aws_http_status, best_effort_delete_bucket


def test_create_bucket_happy_path(s3, bucket_name):
    try:
        out = s3.create_bucket(Bucket=bucket_name)
        loc = out.get("Location", "")
        assert loc, f"expected non-empty Location, got {loc!r}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_create_bucket_duplicate_owned_by_you(s3, bucket_name):
    try:
        s3.create_bucket(Bucket=bucket_name)
        with pytest.raises(ClientError) as ei:
            s3.create_bucket(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "BucketAlreadyOwnedByYou"
        assert aws_http_status(ei.value) == 409
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_create_bucket_invalid_name(s3):
    with pytest.raises(ClientError) as ei:
        # Underscore is not allowed.
        s3.create_bucket(Bucket="Invalid_Name_Here")
    assert aws_error_code(ei.value) == "InvalidBucketName"
