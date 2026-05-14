"""Bucket policy conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


SAMPLE_POLICY = '{"Version":"2012-10-17","Statement":[{"Sid":"DenyAll","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::example/*"}]}'


def test_policy_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_policy(Bucket=bucket_name, Policy=SAMPLE_POLICY)
        out = s3.get_bucket_policy(Bucket=bucket_name)
        assert out["Policy"] == SAMPLE_POLICY, (
            f"policy mismatch: got {out['Policy']!r} want {SAMPLE_POLICY!r}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_policy_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_policy(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "NoSuchBucketPolicy"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_policy_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        # Delete-before-Put is idempotent.
        s3.delete_bucket_policy(Bucket=bucket_name)
        # Set, then delete twice.
        s3.put_bucket_policy(Bucket=bucket_name, Policy=SAMPLE_POLICY)
        s3.delete_bucket_policy(Bucket=bucket_name)
        s3.delete_bucket_policy(Bucket=bucket_name)
        with pytest.raises(ClientError):
            s3.get_bucket_policy(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_policy_malformed_400(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.put_bucket_policy(Bucket=bucket_name, Policy="not json")
        assert "MalformedPolicy" in aws_error_code(ei.value), (
            f"expected MalformedPolicy, got {aws_error_code(ei.value)}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)
