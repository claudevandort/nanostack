"""Multipart upload error-path conformance."""

import pytest
import requests
from botocore.exceptions import ClientError

from conftest import (
    MIN_PART_SIZE,
    aws_error_code,
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    make_payload,
    sign_and_send,
)


def test_multipart_entity_too_small_non_final_undersized(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    upload_id = None
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]

        # Two small parts → first part is non-final and < 5 MiB → EntityTooSmall.
        p1 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=1, Body=b"small1",
        )
        p2 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=2, Body=b"small2",
        )

        with pytest.raises(ClientError) as ei:
            s3.complete_multipart_upload(
                Bucket=bucket_name, Key="k", UploadId=upload_id,
                MultipartUpload={"Parts": [
                    {"ETag": p1["ETag"], "PartNumber": 1},
                    {"ETag": p2["ETag"], "PartNumber": 2},
                ]},
            )
        assert aws_error_code(ei.value) == "EntityTooSmall", \
            f"expected EntityTooSmall, got {aws_error_code(ei.value)}"
    finally:
        if upload_id is not None:
            try:
                s3.abort_multipart_upload(Bucket=bucket_name, Key="k", UploadId=upload_id)
            except ClientError:
                pass
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_final_part_any_size_ok(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]

        big = make_payload(MIN_PART_SIZE, b"A")
        tail = b"tail"

        p1 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=1, Body=big,
        )
        p2 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=2, Body=tail,
        )

        s3.complete_multipart_upload(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            MultipartUpload={"Parts": [
                {"ETag": p1["ETag"], "PartNumber": 1},
                {"ETag": p2["ETag"], "PartNumber": 2},
            ]},
        )
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_no_such_upload(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.upload_part(
                Bucket=bucket_name, Key="k", UploadId="ghost-upload-id",
                PartNumber=1, Body=b"x",
            )
        assert aws_http_status(ei.value) == 404, \
            f"expected 404, got {aws_http_status(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_invalid_part_unknown_number(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    upload_id = None
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]

        # Claim a part number that was never uploaded.
        with pytest.raises(ClientError) as ei:
            s3.complete_multipart_upload(
                Bucket=bucket_name, Key="k", UploadId=upload_id,
                MultipartUpload={"Parts": [{"ETag": '"deadbeef"', "PartNumber": 1}]},
            )
        assert aws_error_code(ei.value) == "InvalidPart", \
            f"expected InvalidPart, got {aws_error_code(ei.value)}"
        assert aws_http_status(ei.value) == 400, \
            f"expected 400, got {aws_http_status(ei.value)}"
    finally:
        if upload_id is not None:
            try:
                s3.abort_multipart_upload(Bucket=bucket_name, Key="k", UploadId=upload_id)
            except ClientError:
                pass
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_complete_with_unknown_upload_id_returns_no_such_upload(s3, bucket_name):
    """AWS: CompleteMultipartUpload on a dead upload id → 404 NoSuchUpload.

    Regression: previously we collapsed this onto 400 InvalidPart because the
    storage backend raised NoSuchUpload for both "upload missing" and
    "part etag mismatch". Drift table row 1.
    """
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]
        s3.abort_multipart_upload(Bucket=bucket_name, Key="k", UploadId=upload_id)

        with pytest.raises(ClientError) as ei:
            s3.complete_multipart_upload(
                Bucket=bucket_name, Key="k", UploadId=upload_id,
                MultipartUpload={"Parts": [{"ETag": '"deadbeef"', "PartNumber": 1}]},
            )
        assert aws_error_code(ei.value) == "NoSuchUpload", \
            f"expected NoSuchUpload, got {aws_error_code(ei.value)}"
        assert aws_http_status(ei.value) == 404, \
            f"expected 404, got {aws_http_status(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_complete_part_list_over_10000_returns_invalid_request(s3, bucket_name):
    """AWS caps the part list at 10000. Drift table row 13.

    Build a fabricated CompleteMultipartUpload body with 10001 <Part> entries
    and send it directly (boto3 would happily forward the oversized list).
    The cap check fires before nanostack tries to look up actual part sizes,
    so the fake ETags don't matter.
    """
    s3.create_bucket(Bucket=bucket_name)
    upload_id = None
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]

        parts_xml = "".join(
            f"<Part><PartNumber>{n}</PartNumber><ETag>\"deadbeef\"</ETag></Part>"
            for n in range(1, 10002)
        )
        body = f"<CompleteMultipartUpload>{parts_xml}</CompleteMultipartUpload>".encode()

        resp = sign_and_send(
            "POST", f"/{bucket_name}/k?uploadId={upload_id}",
            body=body,
            headers={"content-type": "application/xml"},
        )
        assert resp.status_code == 400, f"expected 400, got {resp.status_code}: {resp.text}"
        assert "<Code>InvalidRequest</Code>" in resp.text
    finally:
        if upload_id is not None:
            try:
                s3.abort_multipart_upload(Bucket=bucket_name, Key="k", UploadId=upload_id)
            except ClientError:
                pass
        best_effort_delete_bucket(s3, bucket_name)
