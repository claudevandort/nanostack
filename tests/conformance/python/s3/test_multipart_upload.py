"""Multipart upload conformance (Create / UploadPart / Complete / Abort / UploadPartCopy)."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    MIN_PART_SIZE,
    aws_http_status,
    best_effort_delete_bucket,
    empty_bucket,
    make_payload,
)


def test_multipart_upload_happy_path_two_parts(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(
            Bucket=bucket_name,
            Key="k",
            ContentType="application/x-foo",
            Metadata={"author": "claude"},
        )
        upload_id = init.get("UploadId")
        assert upload_id, "missing UploadId"

        part1 = make_payload(MIN_PART_SIZE, b"A")
        part2 = b"tail"

        p1 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=1, Body=part1,
        )
        p2 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=2, Body=part2,
        )

        cmpu = s3.complete_multipart_upload(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            MultipartUpload={"Parts": [
                {"ETag": p1["ETag"], "PartNumber": 1},
                {"ETag": p2["ETag"], "PartNumber": 2},
            ]},
        )
        etag = cmpu.get("ETag", "")
        assert etag and '-2"' in etag, f"expected multipart ETag ending in -2, got {etag!r}"

        # Verify the merged body matches part1 || part2.
        got = s3.get_object(Bucket=bucket_name, Key="k")
        body = got["Body"].read()
        assert len(body) == len(part1) + len(part2), \
            f"merged size mismatch: got {len(body)} want {len(part1) + len(part2)}"
        assert body[:len(part1)] == part1 and body[len(part1):] == part2, \
            "merged body content mismatch"
        assert got.get("ContentType") == "application/x-foo", \
            f"ContentType not preserved: {got.get('ContentType')!r}"
        meta = got.get("Metadata", {}) or {}
        assert meta.get("author") == "claude", f"metadata not preserved: {meta}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_upload_single_part_any_size(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]

        p1 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=1, Body=b"tiny",
        )
        out = s3.complete_multipart_upload(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            MultipartUpload={"Parts": [{"ETag": p1["ETag"], "PartNumber": 1}]},
        )
        etag = out.get("ETag", "")
        assert etag and '-1"' in etag, f"expected -1 suffix, got {etag!r}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_upload_part_number_out_of_range(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]
        try:
            with pytest.raises(ClientError) as ei:
                s3.upload_part(
                    Bucket=bucket_name, Key="k", UploadId=upload_id,
                    PartNumber=0, Body=b"x",
                )
            assert aws_http_status(ei.value) == 400, \
                f"expected 400, got {aws_http_status(ei.value)}"

            with pytest.raises(ClientError) as ei2:
                s3.upload_part(
                    Bucket=bucket_name, Key="k", UploadId=upload_id,
                    PartNumber=10001, Body=b"x",
                )
            assert aws_http_status(ei2.value) == 400, \
                f"expected 400, got {aws_http_status(ei2.value)}"
        finally:
            try:
                s3.abort_multipart_upload(Bucket=bucket_name, Key="k", UploadId=upload_id)
            except ClientError:
                pass
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_upload_abort(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]

        s3.abort_multipart_upload(Bucket=bucket_name, Key="k", UploadId=upload_id)

        # After abort, UploadPart must fail with NoSuchUpload.
        with pytest.raises(ClientError) as ei:
            s3.upload_part(
                Bucket=bucket_name, Key="k", UploadId=upload_id,
                PartNumber=1, Body=b"x",
            )
        assert aws_http_status(ei.value) == 404, \
            f"expected 404, got {aws_http_status(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_upload_conditional_complete_if_none_match_star(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        # Seed an existing object at "k".
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"orig")

        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]
        p1 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=1, Body=b"new",
        )

        with pytest.raises(ClientError) as ei:
            s3.complete_multipart_upload(
                Bucket=bucket_name, Key="k", UploadId=upload_id,
                IfNoneMatch="*",
                MultipartUpload={"Parts": [{"ETag": p1["ETag"], "PartNumber": 1}]},
            )
        assert aws_http_status(ei.value) == 412, \
            f"expected 412, got {aws_http_status(ei.value)}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_multipart_upload_upload_part_copy_whole(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        src = make_payload(MIN_PART_SIZE + 100, b"C")
        s3.put_object(Bucket=bucket_name, Key="src", Body=src)

        init = s3.create_multipart_upload(Bucket=bucket_name, Key="dst")
        upload_id = init["UploadId"]

        cp = s3.upload_part_copy(
            Bucket=bucket_name,
            Key="dst",
            UploadId=upload_id,
            PartNumber=1,
            CopySource=f"{bucket_name}/src",
        )
        result = cp.get("CopyPartResult") or {}
        assert result.get("ETag"), "missing CopyPartResult.ETag"

        s3.complete_multipart_upload(
            Bucket=bucket_name, Key="dst", UploadId=upload_id,
            MultipartUpload={"Parts": [{"ETag": result["ETag"], "PartNumber": 1}]},
        )

        got = s3.get_object(Bucket=bucket_name, Key="dst")
        body = got["Body"].read()
        assert body == src, "dst body != src body"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
