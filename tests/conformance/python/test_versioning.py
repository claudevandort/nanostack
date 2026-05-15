"""Bucket versioning conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import (
    aws_http_status,
    best_effort_delete_bucket,
    drain_versions,
    sign_and_send,
)


def _enable_versioning(s3, bucket: str) -> None:
    s3.put_bucket_versioning(
        Bucket=bucket,
        VersioningConfiguration={"Status": "Enabled"},
    )


def test_versioning_put_get_status(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        # Default = empty Status.
        out = s3.get_bucket_versioning(Bucket=bucket_name)
        assert out.get("Status", "") == "", f"default status: got {out.get('Status')!r} want \"\""

        _enable_versioning(s3, bucket_name)
        out = s3.get_bucket_versioning(Bucket=bucket_name)
        assert out.get("Status") == "Enabled", f"got {out.get('Status')!r} want Enabled"

        s3.put_bucket_versioning(
            Bucket=bucket_name,
            VersioningConfiguration={"Status": "Suspended"},
        )
        out = s3.get_bucket_versioning(Bucket=bucket_name)
        assert out.get("Status") == "Suspended", f"got {out.get('Status')!r} want Suspended"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_three_puts_list_versions(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        version_ids: list[str] = []
        for body in (b"v1", b"v2", b"v3"):
            out = s3.put_object(Bucket=bucket_name, Key="k", Body=body)
            vid = out.get("VersionId")
            assert vid, f"missing VersionId on Put {body!r}"
            version_ids.append(vid)

        listed = s3.list_object_versions(Bucket=bucket_name)
        versions = listed.get("Versions", []) or []
        assert len(versions) == 3, f"expected 3 versions, got {len(versions)}"
        assert versions[0].get("IsLatest") is True, "first listed should be IsLatest=true"
        assert versions[0].get("VersionId") == version_ids[2], \
            f"latest version mismatch: got {versions[0].get('VersionId')!r} want {version_ids[2]!r}"
    finally:
        # Drain every version + delete marker so the bucket is empty.
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_get_by_explicit_version_id(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        p1 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"first")
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"second")

        got = s3.get_object(Bucket=bucket_name, Key="k", VersionId=p1["VersionId"])
        body = got["Body"].read()
        assert body == b"first", f"got {body!r} want b'first'"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_delete_creates_marker_get_returns_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v")

        delete = s3.delete_object(Bucket=bucket_name, Key="k")
        assert delete.get("DeleteMarker") is True, \
            f"expected DeleteMarker=true, got {delete.get('DeleteMarker')!r}"
        assert delete.get("VersionId"), "expected VersionId on delete-marker response"

        with pytest.raises(ClientError) as ei:
            s3.get_object(Bucket=bucket_name, Key="k")
        assert aws_http_status(ei.value) == 404, \
            f"expected 404, got {aws_http_status(ei.value)}"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_remove_marker_prior_version_reappears(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"alive")
        delete = s3.delete_object(Bucket=bucket_name, Key="k")
        # Now permanently delete the delete-marker.
        s3.delete_object(Bucket=bucket_name, Key="k", VersionId=delete["VersionId"])

        # GetObject should now return the original version.
        got = s3.get_object(Bucket=bucket_name, Key="k")
        body = got["Body"].read()
        assert body == b"alive", f"got {body!r} want b'alive'"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_delete_version_permanent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        p1 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"v1")
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v2")

        s3.delete_object(Bucket=bucket_name, Key="k", VersionId=p1["VersionId"])

        # Verify v1 is gone but v2 remains.
        with pytest.raises(ClientError):
            s3.get_object(Bucket=bucket_name, Key="k", VersionId=p1["VersionId"])
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_suspended_put_gets_null_version_id(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    s3.put_bucket_versioning(
        Bucket=bucket_name,
        VersioningConfiguration={"Status": "Suspended"},
    )
    try:
        out = s3.put_object(Bucket=bucket_name, Key="k", Body=b"x")
        assert out.get("VersionId") == "null", \
            f"expected versionId=\"null\" on Suspended write, got {out.get('VersionId')!r}"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_copy_object_version_id_roundtrip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        src = s3.put_object(Bucket=bucket_name, Key="src", Body=b"hello")
        assert src.get("VersionId"), "source missing VersionId"

        out = s3.copy_object(
            Bucket=bucket_name,
            Key="dst",
            CopySource=f"{bucket_name}/src",
        )
        assert out.get("VersionId"), "dest missing VersionId"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_head_on_delete_marker_returns_405(s3, bucket_name):
    """AWS-exact: HEAD on a delete marker → 405 + Allow: DELETE.

    GET on the same key returns 404 + x-amz-delete-marker (verified in
    `test_versioning_delete_creates_marker_get_returns_404`). HEAD diverges
    on status. Drift table row 3. boto3's head_object swallows non-200
    response headers, so we drop to a raw signed HTTP request.
    """
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v")
        s3.delete_object(Bucket=bucket_name, Key="k")

        resp = sign_and_send("HEAD", f"/{bucket_name}/k")
        assert resp.status_code == 405, \
            f"expected 405 on HEAD-of-delete-marker, got {resp.status_code}"
        assert resp.headers.get("Allow") == "DELETE", \
            f"expected `Allow: DELETE`, got {resp.headers.get('Allow')!r}"
        assert resp.headers.get("x-amz-delete-marker") == "true", \
            f"expected x-amz-delete-marker: true, got {resp.headers.get('x-amz-delete-marker')!r}"
        assert resp.headers.get("x-amz-version-id"), \
            "expected x-amz-version-id header"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_versioning_list_versions_surfaces_owner_per_entry(s3, bucket_name):
    """AWS-exact: every <Version> and <DeleteMarker> in ListVersionsResult
    carries an <Owner> block. Drift table row 7.
    """
    s3.create_bucket(Bucket=bucket_name)
    _enable_versioning(s3, bucket_name)
    try:
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v1")
        s3.put_object(Bucket=bucket_name, Key="k", Body=b"v2")
        s3.delete_object(Bucket=bucket_name, Key="k")  # creates delete marker

        out = s3.list_object_versions(Bucket=bucket_name)
        versions = out.get("Versions", []) or []
        markers = out.get("DeleteMarkers", []) or []
        assert len(versions) == 2, f"expected 2 versions, got {len(versions)}"
        assert len(markers) == 1, f"expected 1 delete marker, got {len(markers)}"

        for entry in versions + markers:
            owner = entry.get("Owner") or {}
            assert owner.get("ID"), \
                f"missing Owner.ID on entry {entry!r}"
            assert owner.get("DisplayName"), \
                f"missing Owner.DisplayName on entry {entry!r}"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
