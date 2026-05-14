"""BucketWebsite conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


def test_website_index_and_error_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_website(
            Bucket=bucket_name,
            WebsiteConfiguration={
                "IndexDocument": {"Suffix": "index.html"},
                "ErrorDocument": {"Key": "404.html"},
            },
        )
        out = s3.get_bucket_website(Bucket=bucket_name)
        assert out["IndexDocument"]["Suffix"] == "index.html", "index suffix mismatch"
        assert out["ErrorDocument"]["Key"] == "404.html", "error key mismatch"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_website_redirect_all_requests_to(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_website(
            Bucket=bucket_name,
            WebsiteConfiguration={
                "RedirectAllRequestsTo": {
                    "HostName": "example.com",
                    "Protocol": "https",
                }
            },
        )
        out = s3.get_bucket_website(Bucket=bucket_name)
        assert out["RedirectAllRequestsTo"]["HostName"] == "example.com", "host mismatch"
        assert out["RedirectAllRequestsTo"]["Protocol"] == "https", "protocol mismatch"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_website_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_website(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "NoSuchWebsiteConfiguration"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_website_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.delete_bucket_website(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)
