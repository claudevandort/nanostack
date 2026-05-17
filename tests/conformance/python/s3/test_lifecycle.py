"""BucketLifecycleConfiguration conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


def test_lifecycle_single_rule_expiration(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_lifecycle_configuration(
            Bucket=bucket_name,
            LifecycleConfiguration={
                "Rules": [
                    {
                        "ID": "r1",
                        "Status": "Enabled",
                        "Filter": {"Prefix": "tmp/"},
                        "Expiration": {"Days": 7},
                    }
                ]
            },
        )
        out = s3.get_bucket_lifecycle_configuration(Bucket=bucket_name)
        assert out["Rules"][0]["ID"] == "r1", "id mismatch"
        assert out["Rules"][0]["Expiration"]["Days"] == 7, "expiration days mismatch"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_lifecycle_transition_and_noncurrent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_lifecycle_configuration(
            Bucket=bucket_name,
            LifecycleConfiguration={
                "Rules": [
                    {
                        "Status": "Enabled",
                        "Filter": {"Prefix": ""},
                        "Transitions": [
                            {"Days": 30, "StorageClass": "GLACIER"}
                        ],
                        "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
                    }
                ]
            },
        )
        out = s3.get_bucket_lifecycle_configuration(Bucket=bucket_name)
        assert out["Rules"][0]["Transitions"][0]["StorageClass"] == "GLACIER", (
            "transition storage class mismatch"
        )
        assert out["Rules"][0]["NoncurrentVersionExpiration"]["NoncurrentDays"] == 90, (
            "noncurrent days mismatch"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_lifecycle_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_lifecycle_configuration(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "NoSuchLifecycleConfiguration"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_lifecycle_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.delete_bucket_lifecycle(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)
