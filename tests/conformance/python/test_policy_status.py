"""GetBucketPolicyStatus conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


PUBLIC_POLICY_TPL = '{"Version":"2012-10-17","Statement":[{"Sid":"PubRead","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::%s/*"}]}'
PRIVATE_POLICY_TPL = '{"Version":"2012-10-17","Statement":[{"Sid":"DenyAll","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":"arn:aws:s3:::%s/*"}]}'


def test_policy_status_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_policy_status(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "NoSuchBucketPolicy"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_policy_status_public_allow(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        policy = PUBLIC_POLICY_TPL % bucket_name
        s3.put_bucket_policy(Bucket=bucket_name, Policy=policy)
        out = s3.get_bucket_policy_status(Bucket=bucket_name)
        assert out["PolicyStatus"]["IsPublic"] is True, (
            "expected IsPublic=true with public-Allow policy"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_policy_status_deny_effect_not_public(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        policy = PRIVATE_POLICY_TPL % bucket_name
        s3.put_bucket_policy(Bucket=bucket_name, Policy=policy)
        out = s3.get_bucket_policy_status(Bucket=bucket_name)
        assert out["PolicyStatus"]["IsPublic"] is False, (
            "expected IsPublic=false with Deny-only policy"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)
