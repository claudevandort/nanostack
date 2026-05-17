"""BucketCors conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


def test_cors_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_cors(
            Bucket=bucket_name,
            CORSConfiguration={
                "CORSRules": [
                    {
                        "AllowedMethods": ["GET", "PUT"],
                        "AllowedOrigins": ["https://example.com"],
                        "AllowedHeaders": ["*"],
                        "ExposeHeaders": ["x-amz-version-id"],
                        "MaxAgeSeconds": 3000,
                    }
                ]
            },
        )
        out = s3.get_bucket_cors(Bucket=bucket_name)
        rules = out["CORSRules"]
        assert len(rules) == 1, f"expected 1 rule, got {len(rules)}"
        r = rules[0]
        assert len(r["AllowedMethods"]) == 2 and r["AllowedMethods"][0] == "GET", (
            f"methods mismatch: {r['AllowedMethods']}"
        )
        assert r.get("MaxAgeSeconds") == 3000, f"max-age mismatch: {r.get('MaxAgeSeconds')}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_cors_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_cors(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "NoSuchCORSConfiguration"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_cors_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.delete_bucket_cors(Bucket=bucket_name)
        s3.put_bucket_cors(
            Bucket=bucket_name,
            CORSConfiguration={
                "CORSRules": [{"AllowedMethods": ["GET"], "AllowedOrigins": ["*"]}]
            },
        )
        s3.delete_bucket_cors(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)
