"""Bucket + object tagging conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    MIN_PART_SIZE,
    aws_error_code,
    aws_http_status,
    best_effort_delete_bucket,
    drain_versions,
    empty_bucket,
    make_payload,
    seed_object,
)


def _tags_to_map(tags: list[dict]) -> dict[str, str]:
    return {t["Key"]: t["Value"] for t in tags or []}


def test_tagging_bucket_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_tagging(
            Bucket=bucket_name,
            Tagging={"TagSet": [
                {"Key": "env", "Value": "prod"},
                {"Key": "team", "Value": "alpha"},
            ]},
        )

        out = s3.get_bucket_tagging(Bucket=bucket_name)
        got = _tags_to_map(out.get("TagSet", []))
        assert got.get("env") == "prod" and got.get("team") == "alpha", \
            f"tags mismatch: {got}"

        s3.delete_bucket_tagging(Bucket=bucket_name)
        with pytest.raises(ClientError):
            s3.get_bucket_tagging(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_bucket_get_on_untagged_no_such_tag_set(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_tagging(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "NoSuchTagSet", \
            f"expected NoSuchTagSet, got {aws_error_code(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_object_round_trip(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"v")
    try:
        s3.put_object_tagging(
            Bucket=bucket_name,
            Key="k",
            Tagging={"TagSet": [{"Key": "env", "Value": "prod"}]},
        )
        out = s3.get_object_tagging(Bucket=bucket_name, Key="k")
        got = _tags_to_map(out.get("TagSet", []))
        assert got.get("env") == "prod", f"tags mismatch: {got}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_object_get_on_untagged_empty_tag_set(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"v")
    try:
        out = s3.get_object_tagging(Bucket=bucket_name, Key="k")
        tags = out.get("TagSet", []) or []
        assert len(tags) == 0, f"expected empty TagSet, got {tags}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_put_object_inline_header(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(
            Bucket=bucket_name,
            Key="k",
            Body=b"hi",
            Tagging="team=alpha&env=prod",
        )
        out = s3.get_object_tagging(Bucket=bucket_name, Key="k")
        got = _tags_to_map(out.get("TagSet", []))
        assert got.get("team") == "alpha" and got.get("env") == "prod", \
            f"inline tags mismatch: {got}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_copy_object_directive_copy_carries_tags(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(
            Bucket=bucket_name, Key="src", Body=b"v",
            Tagging="env=prod",
        )

        s3.copy_object(
            Bucket=bucket_name,
            Key="dst",
            CopySource=f"{bucket_name}/src",
            # TaggingDirective defaults to COPY.
        )
        out = s3.get_object_tagging(Bucket=bucket_name, Key="dst")
        got = _tags_to_map(out.get("TagSet", []))
        assert got.get("env") == "prod", f"COPY directive didn't carry tags: {out.get('TagSet')}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_copy_object_directive_replace_overrides_tags(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_object(
            Bucket=bucket_name, Key="src", Body=b"v",
            Tagging="env=prod&team=alpha",
        )

        s3.copy_object(
            Bucket=bucket_name,
            Key="dst",
            CopySource=f"{bucket_name}/src",
            TaggingDirective="REPLACE",
            Tagging="phase=replace",
        )
        out = s3.get_object_tagging(Bucket=bucket_name, Key="dst")
        got = _tags_to_map(out.get("TagSet", []))
        assert got.get("env", "") == "" and got.get("team", "") == "", \
            f"REPLACE leaked source tags: {got}"
        assert got.get("phase") == "replace", f"REPLACE missing new tag: {got}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_too_many_tags_invalid_tag(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        tags = []
        for i in range(11):
            tags.append({"Key": chr(ord("a") + i), "Value": "v"})
        with pytest.raises(ClientError) as ei:
            s3.put_bucket_tagging(
                Bucket=bucket_name,
                Tagging={"TagSet": tags},
            )
        assert aws_error_code(ei.value) == "InvalidTag", \
            f"expected InvalidTag, got {aws_error_code(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_aws_prefix_invalid_tag(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.put_bucket_tagging(
                Bucket=bucket_name,
                Tagging={"TagSet": [{"Key": "aws:internal", "Value": "x"}]},
            )
        assert aws_http_status(ei.value) == 400, \
            f"expected 400, got {aws_http_status(ei.value)}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_per_version(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    s3.put_bucket_versioning(
        Bucket=bucket_name,
        VersioningConfiguration={"Status": "Enabled"},
    )
    try:
        v1 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"first")
        v2 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"second")

        # Tag only v1.
        s3.put_object_tagging(
            Bucket=bucket_name, Key="k", VersionId=v1["VersionId"],
            Tagging={"TagSet": [{"Key": "rev", "Value": "1"}]},
        )

        # v1 has the tag; v2 does not.
        out1 = s3.get_object_tagging(Bucket=bucket_name, Key="k", VersionId=v1["VersionId"])
        got1 = _tags_to_map(out1.get("TagSet", []))
        assert got1.get("rev") == "1", f"v1 missing tag: {out1.get('TagSet')}"

        out2 = s3.get_object_tagging(Bucket=bucket_name, Key="k", VersionId=v2["VersionId"])
        tags2 = out2.get("TagSet", []) or []
        assert len(tags2) == 0, f"v2 should have no tags, got {tags2}"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_tagging_multipart_create_with_tags(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        init = s3.create_multipart_upload(
            Bucket=bucket_name, Key="k",
            Tagging="env=prod",
        )
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
        out = s3.get_object_tagging(Bucket=bucket_name, Key="k")
        got = _tags_to_map(out.get("TagSet", []))
        assert got.get("env") == "prod", f"multipart didn't carry tags: {out.get('TagSet')}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
