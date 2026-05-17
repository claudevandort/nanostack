"""ListBuckets conformance."""

import pytest

from conftest import best_effort_delete_bucket, sign_and_send, unique_bucket


def test_list_buckets_after_create(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        out = s3.list_buckets()
        names = [b.get("Name") for b in out.get("Buckets", []) or []]
        assert bucket_name in names, f"ListBuckets did not include {bucket_name!r}, got {names}"
        # The just-created bucket must have a CreationDate populated.
        b = next(b for b in out["Buckets"] if b["Name"] == bucket_name)
        assert b.get("CreationDate") is not None
        # Owner block populated.
        owner = out.get("Owner") or {}
        assert owner.get("ID"), f"expected non-empty Owner.ID, got {owner}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_list_buckets_emits_bucket_region(s3, bucket_name):
    """AWS 2023 addition: each <Bucket> in ListBuckets includes <BucketRegion>.
    Newer SDKs use this for cross-region routing decisions. Drift table row 11.
    """
    s3.create_bucket(Bucket=bucket_name)
    try:
        # boto3 1.40+ surfaces BucketRegion directly when the server emits it.
        out = s3.list_buckets()
        b = next((b for b in out.get("Buckets", []) or [] if b.get("Name") == bucket_name), None)
        assert b is not None, f"bucket {bucket_name} missing from ListBuckets"
        assert b.get("BucketRegion") == "us-east-1", \
            f"expected BucketRegion='us-east-1', got {b.get('BucketRegion')!r}"

        # Belt-and-suspenders: parse the raw XML body to confirm the
        # element exists even if boto3 changes how it surfaces the field.
        resp = sign_and_send("GET", "/")
        assert resp.status_code == 200
        assert "<BucketRegion>us-east-1</BucketRegion>" in resp.text, \
            f"expected <BucketRegion> element in body, got: {resp.text}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_list_buckets_pagination(s3):
    """AWS 2023: ListBuckets honours ?prefix, ?max-buckets, ?continuation-token.
    Drift table row 22. Create three buckets with a shared prefix, page
    through them with max=2, and confirm the continuation token works.
    """
    prefix = f"t-wave3-pg-{abs(hash('seed')) % 100000}-"
    names = sorted([f"{prefix}a", f"{prefix}b", f"{prefix}c"])
    for n in names:
        s3.create_bucket(Bucket=n)
    try:
        # First page — 2 buckets.
        page1 = s3.list_buckets(Prefix=prefix, MaxBuckets=2)
        b1 = [b["Name"] for b in page1.get("Buckets", []) or []]
        assert b1 == names[:2], f"first page expected {names[:2]}, got {b1}"
        token = page1.get("ContinuationToken")
        assert token, f"expected ContinuationToken on truncated page, got {page1}"

        # Second page — last bucket only, no more token.
        page2 = s3.list_buckets(Prefix=prefix, MaxBuckets=2, ContinuationToken=token)
        b2 = [b["Name"] for b in page2.get("Buckets", []) or []]
        assert b2 == names[2:], f"second page expected {names[2:]}, got {b2}"
        assert not page2.get("ContinuationToken"), \
            f"expected no ContinuationToken on final page, got {page2.get('ContinuationToken')!r}"
    finally:
        for n in names:
            best_effort_delete_bucket(s3, n)


def test_list_buckets_prefix_filters(s3):
    """Prefix filter excludes non-matching buckets."""
    p1 = f"alpha-wave3-{abs(hash('p1')) % 100000}-"
    p2 = f"beta-wave3-{abs(hash('p2')) % 100000}-"
    a = f"{p1}1"
    b = f"{p2}1"
    s3.create_bucket(Bucket=a)
    s3.create_bucket(Bucket=b)
    try:
        out = s3.list_buckets(Prefix=p1)
        names = [b.get("Name") for b in out.get("Buckets", []) or []]
        assert a in names, f"expected {a} in results, got {names}"
        assert b not in names, f"prefix {p1!r} should have excluded {b}, got {names}"
    finally:
        for n in (a, b):
            best_effort_delete_bucket(s3, n)
