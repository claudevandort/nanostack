"""BucketOwnershipControls conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


def test_ownership_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_ownership_controls(
            Bucket=bucket_name,
            OwnershipControls={"Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]},
        )
        out = s3.get_bucket_ownership_controls(Bucket=bucket_name)
        rules = out["OwnershipControls"]["Rules"]
        assert len(rules) == 1 and rules[0]["ObjectOwnership"] == "BucketOwnerEnforced", (
            f"ownership mismatch: {out['OwnershipControls']}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_ownership_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_ownership_controls(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "OwnershipControlsNotFoundError"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_ownership_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.delete_bucket_ownership_controls(Bucket=bucket_name)
        s3.put_bucket_ownership_controls(
            Bucket=bucket_name,
            OwnershipControls={"Rules": [{"ObjectOwnership": "ObjectWriter"}]},
        )
        s3.delete_bucket_ownership_controls(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)
