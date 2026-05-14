"""BucketEncryption conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


def test_encryption_aes256_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_encryption(
            Bucket=bucket_name,
            ServerSideEncryptionConfiguration={
                "Rules": [
                    {"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}
                ]
            },
        )
        out = s3.get_bucket_encryption(Bucket=bucket_name)
        rule = out["ServerSideEncryptionConfiguration"]["Rules"][0]
        assert rule["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "AES256", (
            "algorithm mismatch"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_encryption_kms_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        key_id = "arn:aws:kms:us-east-1:1234:key/abc-123"
        s3.put_bucket_encryption(
            Bucket=bucket_name,
            ServerSideEncryptionConfiguration={
                "Rules": [
                    {
                        "ApplyServerSideEncryptionByDefault": {
                            "SSEAlgorithm": "aws:kms",
                            "KMSMasterKeyID": key_id,
                        },
                        "BucketKeyEnabled": True,
                    }
                ]
            },
        )
        out = s3.get_bucket_encryption(Bucket=bucket_name)
        rule = out["ServerSideEncryptionConfiguration"]["Rules"][0]
        assert rule["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "aws:kms", (
            "algorithm mismatch"
        )
        assert rule["ApplyServerSideEncryptionByDefault"]["KMSMasterKeyID"] == key_id, (
            "kms id mismatch"
        )
        assert rule.get("BucketKeyEnabled") is True, "bucket key enabled mismatch"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_encryption_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_encryption(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "ServerSideEncryptionConfigurationNotFoundError"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_encryption_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.delete_bucket_encryption(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)
