"""HeadObject conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    seed_object,
)


def test_head_object_happy_path(s3, bucket_name):
    body = b"hello world"
    seed_object(s3, bucket_name, "k", body)
    try:
        out = s3.head_object(Bucket=bucket_name, Key="k")
        assert out.get("ContentLength") == len(body), f"ContentLength mismatch: got {out.get('ContentLength')} want {len(body)}"
        assert out.get("AcceptRanges") == "bytes", f"expected Accept-Ranges: bytes, got {out.get('AcceptRanges')!r}"
        assert out.get("ETag"), "expected ETag header"
        assert out.get("LastModified") is not None, "expected Last-Modified"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_head_object_missing_key(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.head_object(Bucket=bucket_name, Key="nope")
        assert aws_http_status(ei.value) == 404
    finally:
        best_effort_delete_bucket(s3, bucket_name)


# Sanity: HEAD body is empty (RFC 9110) but Content-Length still matches.
def test_head_object_no_body(s3, bucket_name):
    body = b"X" * 100
    seed_object(s3, bucket_name, "k", body)
    try:
        out = s3.head_object(Bucket=bucket_name, Key="k")
        assert out.get("ContentLength") == 100, \
            f"ContentLength should equal 100 (the would-be GET body size), got {out.get('ContentLength')}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
