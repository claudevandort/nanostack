"""ListBuckets conformance."""

from conftest import best_effort_delete_bucket, sign_and_send


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
