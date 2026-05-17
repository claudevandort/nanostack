"""UpdateObjectEncryption conformance — boto3 does not expose this 2025 op,
so we drive it via raw SigV4 PUT /bucket/key?encryption."""

from conftest import (
    best_effort_delete_bucket,
    empty_bucket,
    seed_object,
    sign_and_send,
)


def test_update_object_encryption_aes256_head_round_trip(s3, bucket_name):
    seed_object(s3, bucket_name, "k", b"plain")
    try:
        body = b"<ServerSideEncryption><Algorithm>AES256</Algorithm></ServerSideEncryption>"
        resp = sign_and_send(
            "PUT",
            f"/{bucket_name}/k?encryption",
            body=body,
            headers={"Content-Type": "application/xml"},
        )
        assert resp.status_code == 200, f"expected 200, got {resp.status_code}"

        head = s3.head_object(Bucket=bucket_name, Key="k")
        assert head.get("ServerSideEncryption") == "AES256", (
            f"expected SSE=AES256 in HEAD response, got {head.get('ServerSideEncryption')!r}"
        )
    finally:
        empty_bucket(s3, bucket_name)
        best_effort_delete_bucket(s3, bucket_name)
