"""PublicAccessBlock conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


def test_public_access_block_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_public_access_block(
            Bucket=bucket_name,
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": True,
                "IgnorePublicAcls": True,
                "BlockPublicPolicy": True,
                "RestrictPublicBuckets": True,
            },
        )
        out = s3.get_public_access_block(Bucket=bucket_name)
        cfg = out["PublicAccessBlockConfiguration"]
        assert cfg.get("BlockPublicAcls") is True and cfg.get("RestrictPublicBuckets") is True, (
            f"PAB mismatch: {cfg}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_public_access_block_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_public_access_block(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "NoSuchPublicAccessBlockConfiguration"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_public_access_block_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.delete_public_access_block(Bucket=bucket_name)
        s3.put_public_access_block(
            Bucket=bucket_name,
            PublicAccessBlockConfiguration={"BlockPublicAcls": True},
        )
        s3.delete_public_access_block(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)
