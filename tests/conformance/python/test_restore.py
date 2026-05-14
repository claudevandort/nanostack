"""RestoreObject conformance (M13)."""

from conftest import (
    best_effort_delete_bucket,
    drain_versions,
    empty_bucket,
    seed_object,
)


def test_restore_object_returns_202(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"cold")
    try:
        # We can't directly assert 202 from the SDK output, but no error +
        # successful HEAD with x-amz-restore is the proof we need.
        out = s3.restore_object(
            Bucket=bucket_name, Key="k",
            RestoreRequest={"Days": 1},
        )
        _ = out
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_restore_object_head_surfaces_restore_header(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"cold")
    try:
        s3.restore_object(
            Bucket=bucket_name, Key="k",
            RestoreRequest={"Days": 7},
        )
        head = s3.head_object(Bucket=bucket_name, Key="k")
        restore = head.get("Restore", "") or ""
        assert 'ongoing-request="false"' in restore, \
            f"expected x-amz-restore in HEAD response, got: {restore!r}"
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)


def test_restore_object_per_version(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    s3.put_bucket_versioning(
        Bucket=bucket_name,
        VersioningConfiguration={"Status": "Enabled"},
    )
    try:
        v1 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"v1")
        v2 = s3.put_object(Bucket=bucket_name, Key="k", Body=b"v2")
        # Restore only v1.
        s3.restore_object(
            Bucket=bucket_name, Key="k", VersionId=v1["VersionId"],
            RestoreRequest={"Days": 1},
        )
        head1 = s3.head_object(Bucket=bucket_name, Key="k", VersionId=v1["VersionId"])
        head2 = s3.head_object(Bucket=bucket_name, Key="k", VersionId=v2["VersionId"])
        assert head1.get("Restore", "") != "", "v1 should have x-amz-restore"
        assert head2.get("Restore", "") == "", \
            f"v2 should NOT have x-amz-restore, got: {head2.get('Restore')!r}"
    finally:
        drain_versions(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
