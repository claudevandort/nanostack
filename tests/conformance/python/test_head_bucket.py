"""HeadBucket conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_http_status, best_effort_delete_bucket


def test_head_bucket_existing(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.head_bucket(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_head_bucket_missing(s3, bucket_name):
    with pytest.raises(ClientError) as ei:
        s3.head_bucket(Bucket=bucket_name)
    assert aws_http_status(ei.value) == 404
