"""DynamoDB TTL conformance — v0.2.3.

Phase 1 covers the wire surface: UpdateTimeToLive + DescribeTimeToLive,
persistence across restart. Phase 2 adds the background sweeper tests.
Phase 3 asserts on the userIdentity field of sweeper-evicted records
in the stream.
"""

from __future__ import annotations

import os
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
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@pytest.fixture
def created_table(ddb):
    created: list[str] = []

    def make() -> str:
        name = _unique_table("ttl")
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        created.append(name)
        return name

    yield make
    for name in created:
        try:
            ddb.delete_table(TableName=name)
        except botocore.exceptions.ClientError:
            pass


# ---------------------------------------------------------------------------
# UpdateTimeToLive + DescribeTimeToLive


def test_describe_never_configured_returns_disabled(created_table, ddb):
    name = created_table()
    desc = ddb.describe_time_to_live(TableName=name)["TimeToLiveDescription"]
    assert desc["TimeToLiveStatus"] == "DISABLED"
    assert "AttributeName" not in desc


def test_enable_then_describe(created_table, ddb):
    name = created_table()
    # AWS-real: UpdateTimeToLive returns {TimeToLiveSpecification: {Enabled, AttributeName}}
    # — a different shape from DescribeTimeToLive's {TimeToLiveDescription: {TimeToLiveStatus, AttributeName}}.
    out = ddb.update_time_to_live(
        TableName=name,
        TimeToLiveSpecification={"Enabled": True, "AttributeName": "expires_at"},
    )["TimeToLiveSpecification"]
    assert out["Enabled"] is True
    assert out["AttributeName"] == "expires_at"

    desc = ddb.describe_time_to_live(TableName=name)["TimeToLiveDescription"]
    assert desc["TimeToLiveStatus"] == "ENABLED"
    assert desc["AttributeName"] == "expires_at"


def test_disable_after_enable(created_table, ddb):
    name = created_table()
    ddb.update_time_to_live(
        TableName=name,
        TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
    )
    out = ddb.update_time_to_live(
        TableName=name,
        TimeToLiveSpecification={"Enabled": False, "AttributeName": "ttl"},
    )["TimeToLiveSpecification"]
    assert out["Enabled"] is False

    desc = ddb.describe_time_to_live(TableName=name)["TimeToLiveDescription"]
    assert desc["TimeToLiveStatus"] == "DISABLED"
    # AWS keeps the attribute name visible after disable.
    assert desc["AttributeName"] == "ttl"


def test_re_enable_with_different_attribute(created_table, ddb):
    name = created_table()
    ddb.update_time_to_live(
        TableName=name,
        TimeToLiveSpecification={"Enabled": True, "AttributeName": "a"},
    )
    ddb.update_time_to_live(
        TableName=name,
        TimeToLiveSpecification={"Enabled": True, "AttributeName": "b"},
    )
    desc = ddb.describe_time_to_live(TableName=name)["TimeToLiveDescription"]
    assert desc["AttributeName"] == "b"


def test_update_on_missing_table_returns_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.update_time_to_live(
            TableName="nonexistent_ttl_table_xyz",
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
        )
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_describe_on_missing_table_returns_not_found(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.describe_time_to_live(TableName="nonexistent_ttl_table_xyz")
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


# ---------------------------------------------------------------------------
# Persistence across restart


def _spawn_nanostack(bin_path: str, data_dir: str, port: int, *extra: str) -> subprocess.Popen:
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "s3,dynamodb", *extra],
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


# ---------------------------------------------------------------------------
# Phase 2: background sweeper eviction
#
# All sweeper tests spawn a dedicated nanostack with --ttl-sweep-interval-seconds=1
# so the assertion only needs to sleep ~1.5s for the sweep to fire.


def _ttl_table(ddb, attr: str = "exp") -> str:
    name = _unique_table("sweep")
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    ddb.update_time_to_live(
        TableName=name,
        TimeToLiveSpecification={"Enabled": True, "AttributeName": attr},
    )
    return name


@pytest.fixture
def sweep_nanostack():
    """Spawn a dedicated nanostack with --ttl-sweep-interval-seconds 1
    so eviction tests don't need to wait the default 5s tick."""
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set; skipping sweeper conformance tests")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    data_dir = tempfile.mkdtemp(prefix="ns-ttl-sweep-")
    ep = f"http://127.0.0.1:{port}"
    proc = _spawn_nanostack(bin_path, data_dir, port, "--ttl-sweep-interval-seconds", "1")
    try:
        yield ep
    finally:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        import shutil
        shutil.rmtree(data_dir, ignore_errors=True)


def test_sweeper_evicts_expired_item(sweep_nanostack):
    ddb = _make_ddb(sweep_nanostack)
    name = _ttl_table(ddb)
    past = int(time.time()) - 60
    ddb.put_item(TableName=name, Item={"id": {"S": "stale"}, "exp": {"N": str(past)}})
    # Sweep runs at 1s; allow >= 1.5s for eviction.
    time.sleep(1.6)
    assert ddb.scan(TableName=name)["Count"] == 0


def test_sweeper_keeps_unexpired_item(sweep_nanostack):
    ddb = _make_ddb(sweep_nanostack)
    name = _ttl_table(ddb)
    future = int(time.time()) + 600
    ddb.put_item(TableName=name, Item={"id": {"S": "fresh"}, "exp": {"N": str(future)}})
    time.sleep(1.6)
    assert ddb.scan(TableName=name)["Count"] == 1


def test_sweeper_ignores_item_with_no_ttl_attribute(sweep_nanostack):
    ddb = _make_ddb(sweep_nanostack)
    name = _ttl_table(ddb)
    ddb.put_item(TableName=name, Item={"id": {"S": "no_exp"}})
    time.sleep(1.6)
    assert ddb.scan(TableName=name)["Count"] == 1


def test_sweeper_ignores_wrong_type_ttl_attribute(sweep_nanostack):
    # AWS: items whose TTL attribute is not a Number are kept.
    ddb = _make_ddb(sweep_nanostack)
    name = _ttl_table(ddb)
    past = str(int(time.time()) - 60)
    # Put the expiry timestamp as a string (S), not number (N).
    ddb.put_item(TableName=name, Item={"id": {"S": "wrong_type"}, "exp": {"S": past}})
    time.sleep(1.6)
    assert ddb.scan(TableName=name)["Count"] == 1


def test_sweeper_ignores_disabled_tables(sweep_nanostack):
    ddb = _make_ddb(sweep_nanostack)
    name = _unique_table("sweep_dis")
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    # TTL never enabled → past-expiry item is kept indefinitely.
    past = int(time.time()) - 60
    ddb.put_item(TableName=name, Item={"id": {"S": "stale"}, "exp": {"N": str(past)}})
    time.sleep(1.6)
    assert ddb.scan(TableName=name)["Count"] == 1


def test_sweeper_evicts_multiple_items_one_tick(sweep_nanostack):
    ddb = _make_ddb(sweep_nanostack)
    name = _ttl_table(ddb)
    past = int(time.time()) - 60
    for i in range(5):
        ddb.put_item(TableName=name, Item={"id": {"S": f"k{i}"}, "exp": {"N": str(past)}})
    time.sleep(1.6)
    assert ddb.scan(TableName=name)["Count"] == 0


def test_ttl_spec_persists_across_restart():
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set; skipping restart conformance test")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    data_dir = tempfile.mkdtemp(prefix="ns-ttl-restart-")
    ep = f"http://127.0.0.1:{port}"
    name = _unique_table("persist")

    proc = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = _make_ddb(ep)
        ddb.create_table(
            TableName=name,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        ddb.update_time_to_live(
            TableName=name,
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "expires_at"},
        )
    finally:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass

    proc2 = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = _make_ddb(ep)
        desc = ddb.describe_time_to_live(TableName=name)["TimeToLiveDescription"]
        assert desc["TimeToLiveStatus"] == "ENABLED"
        assert desc["AttributeName"] == "expires_at"
    finally:
        proc2.kill()
        try:
            proc2.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        import shutil
        shutil.rmtree(data_dir, ignore_errors=True)
