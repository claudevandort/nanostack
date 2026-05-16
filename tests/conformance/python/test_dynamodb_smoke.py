"""DynamoDB smoke conformance — Phase 1 (M15-scaffold).

Phase 1 ships only `ListTables` as a stub returning an empty list, plus
the service-dispatch wiring (X-Amz-Target detection, JSON error shape,
SigV4-with-service=dynamodb).

Subsequent phases extend this file with table CRUD, item CRUD, etc.
"""

from __future__ import annotations

import pytest
import boto3
import botocore.exceptions
from botocore.config import Config

from conftest import endpoint


def _make_ddb():
    return boto3.client(
        "dynamodb",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def ddb():
    return _make_ddb()


def test_list_tables_returns_empty_list(ddb):
    """Phase 1 stub: nanostack always returns an empty table list."""
    out = ddb.list_tables()
    assert out["TableNames"] == []
    assert out["ResponseMetadata"]["HTTPStatusCode"] == 200


def test_list_tables_response_content_type_is_dynamodb_json(ddb):
    """DDB responses must use application/x-amz-json-1.0, not application/xml."""
    out = ddb.list_tables()
    ct = out["ResponseMetadata"]["HTTPHeaders"].get("content-type", "")
    assert "x-amz-json-1.0" in ct, f"expected DDB JSON content type, got {ct!r}"


def test_list_tables_emits_aws_request_id_header(ddb):
    """DDB clients key on x-amz-request-id AND x-amzn-RequestId. Both are emitted."""
    out = ddb.list_tables()
    hdrs = out["ResponseMetadata"]["HTTPHeaders"]
    assert hdrs.get("x-amz-request-id") or hdrs.get("x-amzn-requestid"), \
        f"expected one of x-amz-request-id / x-amzn-RequestId, got {hdrs}"


def test_unsupported_target_returns_validation_exception(ddb):
    """Phase 1 only implements ListTables. CreateTable (and any other) →
    400 ValidationException with the target name in the message."""
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.create_table(
            TableName="t",
            KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
    err = ei.value.response["Error"]
    assert err["Code"] == "ValidationException"
    assert ei.value.response["ResponseMetadata"]["HTTPStatusCode"] == 400
    assert "CreateTable" in err.get("Message", ""), \
        f"expected target name in message, got {err.get('Message')!r}"


def test_s3_still_works_when_dynamodb_is_enabled():
    """Multi-service: S3 ops on the same port keep working with DDB enabled."""
    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )
    # ListBuckets — trivially exercised by every other test, but assert here
    # explicitly so the multi-service path is in our regression suite.
    out = s3.list_buckets()
    assert "Buckets" in out
