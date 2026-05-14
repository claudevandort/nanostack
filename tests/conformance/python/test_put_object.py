"""PutObject conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, aws_http_status, best_effort_delete_bucket


def test_put_object_happy_path(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        out = s3.put_object(Bucket=bucket_name, Key="hello.txt", Body=b"hello world")
        etag = out.get("ETag", "")
        assert etag.startswith('"'), f"expected quoted ETag, got {etag!r}"
    finally:
        s3.delete_object(Bucket=bucket_name, Key="hello.txt")
        best_effort_delete_bucket(s3, bucket_name)


def test_put_object_content_type_roundtrip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="doc.json", Body=b"{}", ContentType="application/json")
        out = s3.get_object(Bucket=bucket_name, Key="doc.json")
        assert out["ContentType"] == "application/json"
    finally:
        s3.delete_object(Bucket=bucket_name, Key="doc.json")
        best_effort_delete_bucket(s3, bucket_name)


def test_put_object_user_metadata_roundtrip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"x", Metadata={"foo": "bar", "alpha": "beta"})
        out = s3.head_object(Bucket=bucket_name, Key="k")
        meta = out.get("Metadata", {})
        assert meta.get("foo") == "bar"
        assert meta.get("alpha") == "beta"
    finally:
        s3.delete_object(Bucket=bucket_name, Key="k")
        best_effort_delete_bucket(s3, bucket_name)


def test_put_object_large_body(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    body = b"A" * (1024 * 1024)
    try:
        s3.put_object(Bucket=bucket_name, Key="big", Body=body)
        out = s3.get_object(Bucket=bucket_name, Key="big")
        got = out["Body"].read()
        assert got == body, f"body mismatch: got {len(got)} bytes want {len(body)}"
    finally:
        s3.delete_object(Bucket=bucket_name, Key="big")
        best_effort_delete_bucket(s3, bucket_name)


def test_put_object_missing_bucket(s3, bucket_name):
    with pytest.raises(ClientError) as ei:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"x")
    assert aws_error_code(ei.value) == "NoSuchBucket"
    assert aws_http_status(ei.value) == 404
