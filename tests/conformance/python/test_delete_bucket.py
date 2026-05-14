"""DeleteBucket conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, aws_http_status


def test_delete_bucket_happy_path(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    s3.delete_bucket(Bucket=bucket_name)
    # Confirm gone via HEAD.
    with pytest.raises(ClientError):
        s3.head_bucket(Bucket=bucket_name)


def test_delete_bucket_missing(s3, bucket_name):
    with pytest.raises(ClientError) as ei:
        s3.delete_bucket(Bucket=bucket_name)
    assert aws_error_code(ei.value) == "NoSuchBucket"
    assert aws_http_status(ei.value) == 404
