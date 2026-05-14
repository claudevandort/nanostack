"""ListBuckets conformance."""

from conftest import best_effort_delete_bucket


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
