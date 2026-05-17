"""Conditional PUT conformance (If-Match / If-None-Match: *)."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    seed_object,
)


def test_conditional_put_if_none_match_star_absent_ok(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"first", IfNoneMatch="*")
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_put_if_none_match_star_existing_returns_412(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"v")
    try:
        with pytest.raises(ClientError) as ei:
            s3.put_object(Bucket=bucket_name, Key="k", Body=b"overwrite", IfNoneMatch="*")
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_put_if_match_match_overwrites(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"orig")
    try:
        head = s3.head_object(Bucket=bucket_name, Key="k")
        etag = head["ETag"]

        s3.put_object(Bucket=bucket_name, Key="k", Body=b"new", IfMatch=etag)
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_put_if_match_stale_returns_412(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"orig")
    try:
        with pytest.raises(ClientError) as ei:
            s3.put_object(Bucket=bucket_name, Key="k", Body=b"new", IfMatch='"deadbeef"')
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_conditional_put_if_match_absent_returns_412(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.put_object(Bucket=bucket_name, Key="k", Body=b"v", IfMatch='"deadbeef"')
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)
