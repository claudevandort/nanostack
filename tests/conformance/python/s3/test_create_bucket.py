"""CreateBucket conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, aws_http_status, best_effort_delete_bucket


def test_create_bucket_happy_path(s3, bucket_name):
    try:
        out = s3.create_bucket(Bucket=bucket_name)
        loc = out.get("Location", "")
        assert loc, f"expected non-empty Location, got {loc!r}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_create_bucket_duplicate_owned_by_you(s3, bucket_name):
    try:
        s3.create_bucket(Bucket=bucket_name)
        with pytest.raises(ClientError) as ei:
            s3.create_bucket(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "BucketAlreadyOwnedByYou"
        assert aws_http_status(ei.value) == 409
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_create_bucket_invalid_name(s3):
    with pytest.raises(ClientError) as ei:
        # Underscore is not allowed.
        s3.create_bucket(Bucket="Invalid_Name_Here")
    assert aws_error_code(ei.value) == "InvalidBucketName"


def test_create_bucket_mismatched_location_constraint_returns_400(s3, bucket_name):
    """AWS: <LocationConstraint> in CreateBucket body must match the
    endpoint's region; mismatch → IllegalLocationConstraintException (400).
    Drift table row 20. nanostack ships configured with `us-east-1` by
    default; supplying `us-west-2` here is the mismatch case.
    """
    try:
        with pytest.raises(ClientError) as ei:
            s3.create_bucket(
                Bucket=bucket_name,
                CreateBucketConfiguration={"LocationConstraint": "us-west-2"},
            )
        assert aws_error_code(ei.value) == "IllegalLocationConstraintException", \
            f"got {aws_error_code(ei.value)}"
        assert aws_http_status(ei.value) == 400
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_create_bucket_matching_location_constraint_ok(s3, bucket_name):
    """Constraint that matches the server's region is accepted."""
    try:
        out = s3.create_bucket(
            Bucket=bucket_name,
            CreateBucketConfiguration={"LocationConstraint": "us-east-1"},
        )
        assert out.get("Location"), "expected non-empty Location"
    finally:
        best_effort_delete_bucket(s3, bucket_name)
