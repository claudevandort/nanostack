"""DynamoDB Streams conformance — Phase 1 of v0.2.2.

Phase 1 covers the schema layer: parsing `StreamSpecification` on
CreateTable / UpdateTable, echoing it (plus LatestStreamLabel +
LatestStreamArn) on DescribeTable, and persistence across server
restart.

Later phases add the Streams sub-service (ListStreams, DescribeStream,
GetShardIterator, GetRecords) and actual capture at write time.
"""

from __future__ import annotations

import os
import re
import socket
import subprocess
import tempfile
import time
import uuid

import boto3
import botocore.exceptions
import pytest
from botocore.config import Config

from conftest import endpoint


def _make_ddb(ep: str | None = None):
    return boto3.client(
        "dynamodb",
        endpoint_url=ep or endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def ddb():
    return _make_ddb()


def _unique_table(prefix: str) -> str:
    # Table names must be 3–255 chars, [a-zA-Z0-9_.-].
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@pytest.fixture
def created_table(ddb):
    """Yields a callable that creates a table with the given
    StreamSpecification kwargs and registers cleanup."""
    created: list[str] = []

    def make(stream_spec: dict | None = None) -> str:
        name = _unique_table("stream")
        kwargs = {
            "TableName": name,
            "KeySchema": [{"AttributeName": "id", "KeyType": "HASH"}],
            "AttributeDefinitions": [{"AttributeName": "id", "AttributeType": "S"}],
            "BillingMode": "PAY_PER_REQUEST",
        }
        if stream_spec is not None:
            kwargs["StreamSpecification"] = stream_spec
        ddb.create_table(**kwargs)
        created.append(name)
        return name

    yield make

    for name in created:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass


# ---------------------------------------------------------------------------
# CreateTable + DescribeTable round-trip


def test_create_without_streams_omits_spec(created_table, ddb):
    name = created_table(stream_spec=None)
    desc = ddb.describe_table(TableName=name)["Table"]
    assert "StreamSpecification" not in desc
    assert "LatestStreamLabel" not in desc
    assert "LatestStreamArn" not in desc


def test_create_with_streams_enabled_echoes_spec(created_table, ddb):
    name = created_table({
        "StreamEnabled": True,
        "StreamViewType": "NEW_AND_OLD_IMAGES",
    })
    desc = ddb.describe_table(TableName=name)["Table"]
    spec = desc["StreamSpecification"]
    assert spec["StreamEnabled"] is True
    assert spec["StreamViewType"] == "NEW_AND_OLD_IMAGES"


def test_create_disabled_streams_echoes_disabled_spec(created_table, ddb):
    # StreamEnabled=False is a no-op effectively, but AWS echoes the spec
    # back so clients can verify the configured state.
    name = created_table({"StreamEnabled": False})
    desc = ddb.describe_table(TableName=name)["Table"]
    spec = desc["StreamSpecification"]
    assert spec["StreamEnabled"] is False
    # AWS does not emit Label/Arn when disabled.
    assert "LatestStreamLabel" not in desc
    assert "LatestStreamArn" not in desc


@pytest.mark.parametrize("view_type", [
    "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES", "KEYS_ONLY",
])
def test_all_view_types_round_trip(created_table, ddb, view_type):
    name = created_table({"StreamEnabled": True, "StreamViewType": view_type})
    desc = ddb.describe_table(TableName=name)["Table"]
    assert desc["StreamSpecification"]["StreamViewType"] == view_type


def test_latest_stream_label_and_arn_shape(created_table, ddb):
    name = created_table({"StreamEnabled": True, "StreamViewType": "NEW_IMAGE"})
    desc = ddb.describe_table(TableName=name)["Table"]
    label = desc["LatestStreamLabel"]
    arn = desc["LatestStreamArn"]
    # AWS-observed shape: "YYYY-MM-DDTHH:MM:SS.sss"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}", label), label
    # ARN shape: arn:aws:dynamodb:<region>:<account>:table/<name>/stream/<label>
    assert arn == f"arn:aws:dynamodb:us-east-1:000000000000:table/{name}/stream/{label}"


def test_invalid_view_type_returns_validation_exception(ddb):
    name = _unique_table("badview")
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
            StreamSpecification={"StreamEnabled": True, "StreamViewType": "BOGUS"},
        )
    err = ei.value.response["Error"]
    # boto3 client-side validates the view-type before sending — accept
    # either client-side ParamValidationError or server ValidationException.
    assert err["Code"] in ("ValidationException", "ParamValidationError")


# ---------------------------------------------------------------------------
# UpdateTable: enable + disable


def test_update_table_enables_streams(created_table, ddb):
    name = created_table(stream_spec=None)
    ddb.update_table(
        TableName=name,
        StreamSpecification={"StreamEnabled": True, "StreamViewType": "KEYS_ONLY"},
    )
    desc = ddb.describe_table(TableName=name)["Table"]
    assert desc["StreamSpecification"]["StreamEnabled"] is True
    assert desc["StreamSpecification"]["StreamViewType"] == "KEYS_ONLY"
    assert "LatestStreamLabel" in desc


def test_update_table_disables_streams(created_table, ddb):
    name = created_table({"StreamEnabled": True, "StreamViewType": "OLD_IMAGE"})
    ddb.update_table(
        TableName=name,
        StreamSpecification={"StreamEnabled": False},
    )
    desc = ddb.describe_table(TableName=name)["Table"]
    assert desc["StreamSpecification"]["StreamEnabled"] is False
    assert "LatestStreamLabel" not in desc


# ---------------------------------------------------------------------------
# Persistence across restart


def _spawn_nanostack(bin_path: str, data_dir: str, port: int) -> subprocess.Popen:
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "s3,dynamodb"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    import requests
    deadline = time.time() + 5
    url = f"http://127.0.0.1:{port}/"
    while time.time() < deadline:
        try:
            requests.get(url, timeout=1)
            return proc
        except requests.RequestException:
            time.sleep(0.1)
    proc.kill()
    raise AssertionError(f"nanostack did not bind :{port} within 5s")


def test_stream_spec_persists_across_restart():
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set; skipping restart conformance test")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    data_dir = tempfile.mkdtemp(prefix="ns-streams-restart-")
    ep = f"http://127.0.0.1:{port}"
    name = _unique_table("persist")

    # Pass 1: create with streams enabled.
    proc = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = _make_ddb(ep)
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
            StreamSpecification={"StreamEnabled": True, "StreamViewType": "NEW_AND_OLD_IMAGES"},
        )
        first = ddb.describe_table(TableName=name)["Table"]
        assert first["StreamSpecification"]["StreamEnabled"] is True
        original_label = first["LatestStreamLabel"]
    finally:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass

    # Pass 2: restart, spec + label must survive.
    proc2 = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = _make_ddb(ep)
        desc = ddb.describe_table(TableName=name)["Table"]
        assert desc["StreamSpecification"]["StreamEnabled"] is True
        assert desc["StreamSpecification"]["StreamViewType"] == "NEW_AND_OLD_IMAGES"
        assert desc["LatestStreamLabel"] == original_label
    finally:
        proc2.kill()
        try:
            proc2.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        import shutil
        shutil.rmtree(data_dir, ignore_errors=True)
