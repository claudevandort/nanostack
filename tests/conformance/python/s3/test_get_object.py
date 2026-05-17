"""GetObject conformance (incl. range requests + Accept-Ranges header)."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    seed_object,
    sign_and_send,
)


def test_get_object_full_body(s3, bucket_name):
    body = b"hello world this is nanostack"
    seed_object(s3, bucket_name, "k", body)
    try:
        out = s3.get_object(Bucket=bucket_name, Key="k")
        assert out.get("AcceptRanges") == "bytes"
        assert out["Body"].read() == body
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_get_object_range_prefix(s3, bucket_name):
    body = b"0123456789abcdef"
    seed_object(s3, bucket_name, "k", body)
    try:
        out = s3.get_object(Bucket=bucket_name, Key="k", Range="bytes=0-4")
        assert out.get("ContentRange") == f"bytes 0-4/{len(body)}"
        assert out["Body"].read() == b"01234"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_get_object_range_suffix(s3, bucket_name):
    body = b"0123456789abcdef"  # 16 bytes
    seed_object(s3, bucket_name, "k", body)
    try:
        out = s3.get_object(Bucket=bucket_name, Key="k", Range="bytes=-5")
        assert out["Body"].read() == b"bcdef"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_get_object_open_range(s3, bucket_name):
    body = b"0123456789abcdef"
    seed_object(s3, bucket_name, "k", body)
    try:
        out = s3.get_object(Bucket=bucket_name, Key="k", Range="bytes=10-")
        assert out["Body"].read() == b"abcdef"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_get_object_out_of_range(s3, bucket_name):
    body = b"short"
    seed_object(s3, bucket_name, "k", body)
    try:
        # boto3 doesn't surface 416 cleanly; sign + send raw HTTP so we
        # can read the status verbatim.
        resp = sign_and_send("GET", f"/{bucket_name}/k", headers={"Range": "bytes=999-"})
        assert resp.status_code == 416
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_get_object_missing_key(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_object(Bucket=bucket_name, Key="nope")
        assert aws_http_status(ei.value) == 404
    finally:
        best_effort_delete_bucket(s3, bucket_name)
