"""Conditional GET/HEAD conformance (If-Match / If-None-Match / If-*-Since)."""

from datetime import datetime, timedelta, timezone

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    seed_object,
)


def _seed_and_get_etag(s3, bucket: str, key: str, body: bytes) -> str:
    seed_object(s3, bucket, key, body)
    head = s3.head_object(Bucket=bucket, Key=key)
    return head["ETag"]


def test_conditional_get_if_match_mismatch(s3, bucket_name):
    _ = _seed_and_get_etag(s3, bucket_name, "k", b"x")
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_object(Bucket=bucket_name, Key="k", IfMatch='"deadbeef"')
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_get_if_none_match_match(s3, bucket_name):
    etag = _seed_and_get_etag(s3, bucket_name, "k", b"x")
    try:
        # SDK turns 304 into a NotModified error; check via HTTP status.
        with pytest.raises(ClientError) as ei:
            s3.get_object(Bucket=bucket_name, Key="k", IfNoneMatch=etag)
        assert aws_http_status(ei.value) == 304, \
            f"expected HTTP 304, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_get_if_modified_since_future_returns_304(s3, bucket_name):
    _ = _seed_and_get_etag(s3, bucket_name, "k", b"x")
    try:
        future = datetime.now(timezone.utc) + timedelta(hours=1)
        with pytest.raises(ClientError) as ei:
            s3.get_object(Bucket=bucket_name, Key="k", IfModifiedSince=future)
        assert aws_http_status(ei.value) == 304, \
            f"expected HTTP 304, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_get_if_unmodified_since_past_returns_412(s3, bucket_name):
    _ = _seed_and_get_etag(s3, bucket_name, "k", b"x")
    try:
        past = datetime(1970, 1, 1, tzinfo=timezone.utc)
        with pytest.raises(ClientError) as ei:
            s3.get_object(Bucket=bucket_name, Key="k", IfUnmodifiedSince=past)
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_get_if_match_happy_path_body_returned(s3, bucket_name):
    etag = _seed_and_get_etag(s3, bucket_name, "k", b"happy")
    try:
        out = s3.get_object(Bucket=bucket_name, Key="k", IfMatch=etag)
        got = out["Body"].read()
        assert got == b"happy", "body mismatch"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_head_if_none_match_match_returns_304(s3, bucket_name):
    etag = _seed_and_get_etag(s3, bucket_name, "k", b"x")
    try:
        with pytest.raises(ClientError) as ei:
            s3.head_object(Bucket=bucket_name, Key="k", IfNoneMatch=etag)
        assert aws_http_status(ei.value) == 304, \
            f"expected HTTP 304 on HEAD, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
