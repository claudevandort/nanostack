"""CopyObject conformance (incl. conditional copy headers)."""

from datetime import datetime, timedelta, timezone

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_error_code,
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    seed_object,
    unique_bucket,
)


def _read_body(s3, bucket: str, key: str) -> bytes:
    out = s3.get_object(Bucket=bucket, Key=key)
    return out["Body"].read()


def test_copy_object_same_bucket_happy(s3, bucket_name):
    seed_object(s3, bucket_name, "src", b"hello copy")
    try:
        out = s3.copy_object(
            Bucket=bucket_name,
            Key="dst",
            CopySource=f"{bucket_name}/src",
        )
        result = out.get("CopyObjectResult") or {}
        assert result.get("ETag"), "missing CopyObjectResult.ETag"
        body = _read_body(s3, bucket_name, "dst")
        assert body == b"hello copy", f"body mismatch: got {body!r}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_cross_bucket_preserves_metadata(s3, request):
    src = unique_bucket("cp-src", suffix=request.node.name)
    dst = unique_bucket("cp-dst", suffix=request.node.name)
    s3.create_bucket(Bucket=src)
    s3.create_bucket(Bucket=dst)
    try:
        s3.put_object(
            Bucket=src,
            Key="k",
            Body=b"payload",
            ContentType="application/x-foo",
            Metadata={"author": "claude"},
        )

        s3.copy_object(Bucket=dst, Key="k", CopySource=f"{src}/k")

        head = s3.head_object(Bucket=dst, Key="k")
        assert head.get("ContentType") == "application/x-foo", \
            f"ContentType not carried: got {head.get('ContentType')!r}"
        meta = head.get("Metadata", {}) or {}
        assert meta.get("author") == "claude", f"metadata 'author' missing: got {meta}"
    finally:
        empty_bucket(s3, src)
        empty_bucket(s3, dst)
        best_effort_delete_bucket(s3, src)
        best_effort_delete_bucket(s3, dst)


def test_copy_object_replace_directive(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(
            Bucket=bucket_name,
            Key="src",
            Body=b"payload",
            ContentType="text/plain",
            Metadata={"old": "yes"},
        )

        s3.copy_object(
            Bucket=bucket_name,
            Key="dst",
            CopySource=f"{bucket_name}/src",
            MetadataDirective="REPLACE",
            ContentType="application/json",
            Metadata={"new": "ok"},
        )

        head = s3.head_object(Bucket=bucket_name, Key="dst")
        assert head.get("ContentType") == "application/json", \
            f"REPLACE didn't change ContentType: got {head.get('ContentType')!r}"
        meta = head.get("Metadata", {}) or {}
        assert "old" not in meta, f"REPLACE leaked source metadata: {meta}"
        assert meta.get("new") == "ok", f"REPLACE missing new metadata: {meta}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_source_missing(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.copy_object(
                Bucket=bucket_name,
                Key="dst",
                CopySource=f"{bucket_name}/no-such-source",
            )
        assert aws_error_code(ei.value) == "NoSuchKey", \
            f"expected NoSuchKey, got {aws_error_code(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_invalid_metadata_directive(s3, bucket_name):
    seed_object(s3, bucket_name, "src", b"x")
    try:
        with pytest.raises(ClientError) as ei:
            s3.copy_object(
                Bucket=bucket_name,
                Key="dst",
                CopySource=f"{bucket_name}/src",
                MetadataDirective="NEITHER",
            )
        assert aws_error_code(ei.value) == "InvalidArgument", \
            f"expected InvalidArgument, got {aws_error_code(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_copy_source_if_match_ok(s3, bucket_name):
    seed_object(s3, bucket_name, "src", b"x")
    try:
        head = s3.head_object(Bucket=bucket_name, Key="src")
        etag = head["ETag"]

        s3.copy_object(
            Bucket=bucket_name,
            Key="dst",
            CopySource=f"{bucket_name}/src",
            CopySourceIfMatch=etag,
        )
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_copy_source_if_match_mismatch(s3, bucket_name):
    seed_object(s3, bucket_name, "src", b"x")
    try:
        with pytest.raises(ClientError) as ei:
            s3.copy_object(
                Bucket=bucket_name,
                Key="dst",
                CopySource=f"{bucket_name}/src",
                CopySourceIfMatch='"deadbeef"',
            )
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_copy_source_if_none_match_mismatch(s3, bucket_name):
    # If-None-Match with matching etag → 412 (precondition failed on source).
    seed_object(s3, bucket_name, "src", b"x")
    try:
        head = s3.head_object(Bucket=bucket_name, Key="src")
        etag = head["ETag"]

        with pytest.raises(ClientError) as ei:
            s3.copy_object(
                Bucket=bucket_name,
                Key="dst",
                CopySource=f"{bucket_name}/src",
                CopySourceIfNoneMatch=etag,
            )
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_copy_source_if_unmodified_since_ok(s3, bucket_name):
    seed_object(s3, bucket_name, "src", b"x")
    try:
        # One hour in the future — source was modified strictly before this.
        future = datetime.now(timezone.utc) + timedelta(hours=1)
        s3.copy_object(
            Bucket=bucket_name,
            Key="dst",
            CopySource=f"{bucket_name}/src",
            CopySourceIfUnmodifiedSince=future,
        )
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_copy_object_copy_source_if_modified_since_fail(s3, bucket_name):
    seed_object(s3, bucket_name, "src", b"x")
    try:
        # One hour in the future — source has NOT been modified since then.
        future = datetime.now(timezone.utc) + timedelta(hours=1)
        with pytest.raises(ClientError) as ei:
            s3.copy_object(
                Bucket=bucket_name,
                Key="dst",
                CopySource=f"{bucket_name}/src",
                CopySourceIfModifiedSince=future,
            )
        assert aws_http_status(ei.value) == 412, \
            f"expected HTTP 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
