"""GetObjectAttributes conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    MIN_PART_SIZE,
    aws_error_code,
    best_effort_delete_bucket,
    drain_versions,
    empty_bucket,
    make_payload,
    seed_object,
)


def test_object_attributes_single(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"hello")
    try:
        out = s3.get_object_attributes(
            Bucket=bucket_name,
            Key="k",
            ObjectAttributes=["ETag"],
        )
        assert out.get("ETag"), "expected non-empty ETag"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_object_attributes_object_size(s3, bucket_name):
    # NOTE: The Go SDK sends one `X-Amz-Object-Attributes` HTTP header per
    # requested attribute. Our SigV4 canonical-headers handling currently
    # only sees the first occurrence (pre-existing limitation documented
    # in SUPPORT.md). So we exercise one attribute per call here.
    seed_object(s3, bucket_name, "k", b"hello world")
    try:
        out = s3.get_object_attributes(
            Bucket=bucket_name,
            Key="k",
            ObjectAttributes=["ObjectSize"],
        )
        assert out.get("ObjectSize") == 11, f"expected size 11, got {out.get('ObjectSize')}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_object_attributes_storage_class(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"x")
    try:
        out = s3.get_object_attributes(
            Bucket=bucket_name,
            Key="k",
            ObjectAttributes=["StorageClass"],
        )
        assert out.get("StorageClass") == "STANDARD", \
            f"expected STANDARD storage class, got {out.get('StorageClass')!r}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_object_attributes_no_such_key(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_object_attributes(
                Bucket=bucket_name,
                Key="missing",
                ObjectAttributes=["ETag"],
            )
        assert aws_error_code(ei.value) == "NoSuchKey", \
            f"expected NoSuchKey, got {aws_error_code(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_object_attributes_multipart_object_parts(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(Bucket=bucket_name, Key="k")
        upload_id = init["UploadId"]
        payload = make_payload(MIN_PART_SIZE, b"A")
        p1 = s3.upload_part(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            PartNumber=1, Body=payload,
        )
        s3.complete_multipart_upload(
            Bucket=bucket_name, Key="k", UploadId=upload_id,
            MultipartUpload={"Parts": [{"ETag": p1["ETag"], "PartNumber": 1}]},
        )

        out = s3.get_object_attributes(
            Bucket=bucket_name, Key="k",
            ObjectAttributes=["ObjectParts"],
        )
        parts = out.get("ObjectParts")
        assert parts is not None and parts.get("TotalPartsCount") == 1, \
            f"expected ObjectParts.TotalPartsCount=1, got {parts!r}"

        # ETag with -1 suffix is verifiable independently via HeadObject.
        head = s3.head_object(Bucket=bucket_name, Key="k")
        etag = head["ETag"]
        assert etag.endswith('-1"'), f"expected multipart ETag with -1 suffix, got {etag}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_object_attributes_per_version(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    s3.put_bucket_versioning(
        Bucket=bucket_name,
        VersioningConfiguration={"Status": "Enabled"},
    )
    try:
        v1 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"first")
        v2 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"second-longer")

        out1 = s3.get_object_attributes(
            Bucket=bucket_name, Key="k", VersionId=v1["VersionId"],
            ObjectAttributes=["ObjectSize"],
        )
        out2 = s3.get_object_attributes(
            Bucket=bucket_name, Key="k", VersionId=v2["VersionId"],
            ObjectAttributes=["ObjectSize"],
        )
        assert out1.get("ObjectSize") == 5 and out2.get("ObjectSize") == 13, \
            f"per-version sizes wrong: v1={out1.get('ObjectSize')} v2={out2.get('ObjectSize')}"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
