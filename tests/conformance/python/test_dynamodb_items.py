"""DynamoDB item-CRUD conformance (M15-items, Phase 3).

GetItem / PutItem / DeleteItem without expressions. ReturnValues
NONE / ALL_OLD only — UPDATED_* and conditional updates land in
Phase 4 (M15-expressions).
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import time

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


def _unique_name(prefix: str, request) -> str:
    safe = request.node.name.replace("[", "-").replace("]", "").replace(":", "_")[:80]
    return f"{prefix}-{safe}"


@pytest.fixture
def hash_table(ddb, request):
    name = _unique_name("items-hash", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


@pytest.fixture
def composite_table(ddb, request):
    name = _unique_name("items-comp", request)
    ddb.create_table(
        TableName=name,
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "N"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    yield name
    try:
        ddb.delete_table(TableName=name)
    except botocore.exceptions.ClientError:
        pass


# ---------------------------------------------------------------------------
# PutItem + GetItem round-trip

def test_put_get_roundtrip(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={
        "id": {"S": "k1"},
        "name": {"S": "Bob"},
        "age": {"N": "42"},
    })
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    assert out["Item"]["name"] == {"S": "Bob"}
    assert out["Item"]["age"] == {"N": "42"}


def test_get_missing_returns_no_item_key(ddb, hash_table):
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "absent"}})
    assert "Item" not in out


def test_put_overwrites_existing(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "first"}})
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "second"}})
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    assert out["Item"]["v"] == {"S": "second"}


def test_put_with_return_values_all_old(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "first"}})
    out = ddb.put_item(
        TableName=hash_table,
        Item={"id": {"S": "k1"}, "v": {"S": "second"}},
        ReturnValues="ALL_OLD",
    )
    assert out.get("Attributes") == {"id": {"S": "k1"}, "v": {"S": "first"}}


def test_put_new_with_return_values_all_old_returns_no_attributes(ddb, hash_table):
    """ALL_OLD on a fresh key should NOT include the Attributes field."""
    out = ddb.put_item(
        TableName=hash_table,
        Item={"id": {"S": "fresh"}, "v": {"S": "x"}},
        ReturnValues="ALL_OLD",
    )
    assert "Attributes" not in out


# ---------------------------------------------------------------------------
# Composite-key (HASH + RANGE)

def test_composite_key_distinguishes_items(ddb, composite_table):
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"N": "1"}, "v": {"S": "a"}})
    ddb.put_item(TableName=composite_table, Item={"pk": {"S": "p1"}, "sk": {"N": "2"}, "v": {"S": "b"}})
    out1 = ddb.get_item(TableName=composite_table, Key={"pk": {"S": "p1"}, "sk": {"N": "1"}})
    out2 = ddb.get_item(TableName=composite_table, Key={"pk": {"S": "p1"}, "sk": {"N": "2"}})
    assert out1["Item"]["v"] == {"S": "a"}
    assert out2["Item"]["v"] == {"S": "b"}


# ---------------------------------------------------------------------------
# AttributeValue type coverage

def test_attribute_value_full_type_coverage(ddb, hash_table):
    item = {
        "id": {"S": "types"},
        "s": {"S": "hello"},
        "n": {"N": "123.456789012345678901234567890123456789"},  # 38-digit precision
        "b": {"B": b"binary-bytes"},
        "bool_true": {"BOOL": True},
        "bool_false": {"BOOL": False},
        "null_val": {"NULL": True},
        "list": {"L": [{"S": "a"}, {"N": "1"}]},
        "map": {"M": {"inner": {"S": "x"}}},
        "ss": {"SS": ["a", "b", "c"]},
        "ns": {"NS": ["1", "2", "3"]},
    }
    ddb.put_item(TableName=hash_table, Item=item)
    got = ddb.get_item(TableName=hash_table, Key={"id": {"S": "types"}})["Item"]
    # Check each type round-trips. (Sets may be in any order — compare as sets.)
    assert got["s"] == {"S": "hello"}
    assert got["n"]["N"] == "123.456789012345678901234567890123456789"
    assert got["b"]["B"] == b"binary-bytes"
    assert got["bool_true"]["BOOL"] is True
    assert got["bool_false"]["BOOL"] is False
    assert got["null_val"]["NULL"] is True
    assert got["list"]["L"] == [{"S": "a"}, {"N": "1"}]
    assert got["map"]["M"] == {"inner": {"S": "x"}}
    assert set(got["ss"]["SS"]) == {"a", "b", "c"}
    assert set(got["ns"]["NS"]) == {"1", "2", "3"}


# ---------------------------------------------------------------------------
# DeleteItem

def test_delete_item_removes_it(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "x"}})
    ddb.delete_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    out = ddb.get_item(TableName=hash_table, Key={"id": {"S": "k1"}})
    assert "Item" not in out


def test_delete_item_return_all_old(ddb, hash_table):
    ddb.put_item(TableName=hash_table, Item={"id": {"S": "k1"}, "v": {"S": "x"}})
    out = ddb.delete_item(
        TableName=hash_table,
        Key={"id": {"S": "k1"}},
        ReturnValues="ALL_OLD",
    )
    assert out["Attributes"] == {"id": {"S": "k1"}, "v": {"S": "x"}}


def test_delete_missing_item_is_idempotent(ddb, hash_table):
    """AWS-correct: DeleteItem on a missing key is a no-op success."""
    ddb.delete_item(TableName=hash_table, Key={"id": {"S": "never-existed"}})


# ---------------------------------------------------------------------------
# Table-not-found

def test_put_into_missing_table(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.put_item(TableName="no-such-table-items", Item={"id": {"S": "x"}})
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def test_get_from_missing_table(ddb):
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.get_item(TableName="no-such-table-items", Key={"id": {"S": "x"}})
    assert ei.value.response["Error"]["Code"] == "ResourceNotFoundException"


def _spawn_nanostack(bin_path: str, data_dir: str, port: int) -> subprocess.Popen:
    proc = subprocess.Popen(
        [bin_path, "--port", str(port), "--data-dir", data_dir, "--services", "s3,dynamodb"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    # Wait for the port to accept connections.
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


def test_items_persist_across_nanostack_restart():
    """v0.2.1: items written to disk survive a nanostack restart.

    Spawns a dedicated nanostack instance on a free port, creates a
    table + puts 5 items, kills the server, restarts pointing at the
    same --data-dir, and verifies all 5 items are queryable again.
    """
    bin_path = os.environ.get("NANOSTACK_BIN")
    if not bin_path:
        pytest.skip("NANOSTACK_BIN not set; skipping restart conformance test")

    # Pick a free port.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    data_dir = tempfile.mkdtemp(prefix="ns-restart-")
    ep = f"http://127.0.0.1:{port}"

    def ddb_client():
        return boto3.client(
            "dynamodb",
            endpoint_url=ep,
            region_name="us-east-1",
            aws_access_key_id="test",
            aws_secret_access_key="test",
            config=Config(retries={"max_attempts": 1}),
        )

    # Pass 1: seed + write.
    proc = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = ddb_client()
        ddb.create_table(
            TableName="Survivors",
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        for i in range(5):
            ddb.put_item(TableName="Survivors", Item={
                "id": {"S": f"k{i}"},
                "n": {"N": str(i)},
                "tag": {"S": "alive"},
            })
        # Sanity: 5 items live in the running instance.
        out = ddb.scan(TableName="Survivors")
        assert out["Count"] == 5
    finally:
        proc.kill()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass

    # Pass 2: restart, verify items survive.
    proc2 = _spawn_nanostack(bin_path, data_dir, port)
    try:
        ddb = ddb_client()
        out = ddb.scan(TableName="Survivors")
        assert out["Count"] == 5, f"expected 5 items after restart, got {out['Count']}"
        ids = sorted(it["id"]["S"] for it in out["Items"])
        assert ids == [f"k{i}" for i in range(5)]

        # Spot-check via GetItem that AttributeValue round-trips.
        item = ddb.get_item(TableName="Survivors", Key={"id": {"S": "k2"}})["Item"]
        assert item["n"] == {"N": "2"}
        assert item["tag"] == {"S": "alive"}
    finally:
        proc2.kill()
        try:
            proc2.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        shutil.rmtree(data_dir, ignore_errors=True)
