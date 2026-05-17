"""BucketReplication conformance."""

import pytest
from botocore.exceptions import ClientError

from conftest import aws_error_code, best_effort_delete_bucket


def test_replication_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        # Replication requires versioning enabled on source.
        s3.put_bucket_versioning(
            Bucket=bucket_name,
            VersioningConfiguration={"Status": "Enabled"},
        )
        s3.put_bucket_replication(
            Bucket=bucket_name,
            ReplicationConfiguration={
                "Role": "arn:aws:iam::1:role/repl",
                "Rules": [
                    {
                        "ID": "r1",
                        "Status": "Enabled",
                        "Prefix": "logs/",
                        "Destination": {"Bucket": "arn:aws:s3:::dest"},
                    }
                ],
            },
        )
        out = s3.get_bucket_replication(Bucket=bucket_name)
        cfg = out["ReplicationConfiguration"]
        assert cfg["Role"] == "arn:aws:iam::1:role/repl", "role mismatch"
        assert len(cfg["Rules"]) == 1 and cfg["Rules"][0]["ID"] == "r1", "rule id mismatch"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_replication_get_on_untouched_404(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        with pytest.raises(ClientError) as ei:
            s3.get_bucket_replication(Bucket=bucket_name)
        assert aws_error_code(ei.value) == "ReplicationConfigurationNotFoundError"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_replication_delete_idempotent(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.delete_bucket_replication(Bucket=bucket_name)
    finally:
        best_effort_delete_bucket(s3, bucket_name)
