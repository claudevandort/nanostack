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


def _make_streams(ep: str | None = None):
    return boto3.client(
        "dynamodbstreams",
        endpoint_url=ep or endpoint(),
        region_name="us-east-1",
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def ddb():
    return _make_ddb()


@pytest.fixture
def streams():
    return _make_streams()


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


# ---------------------------------------------------------------------------
# Streams sub-service: ListStreams + DescribeStream + GetShardIterator + GetRecords


def _create_streamed(ddb, view_type: str = "NEW_AND_OLD_IMAGES") -> str:
    name = _unique_table("subs")
    ddb.create_table(
        TableName=name,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
        StreamSpecification={"StreamEnabled": True, "StreamViewType": view_type},
    )
    return name


def test_list_streams_returns_only_enabled(ddb, streams):
    # One enabled, one disabled.
    enabled = _create_streamed(ddb)
    disabled = _unique_table("nostream")
    ddb.create_table(
        TableName=disabled,
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    try:
        names = {s["TableName"] for s in streams.list_streams()["Streams"]}
        assert enabled in names
        assert disabled not in names
    finally:
        ddb.delete_table(TableName=enabled)
        ddb.delete_table(TableName=disabled)


def test_list_streams_filters_by_table_name(ddb, streams):
    a = _create_streamed(ddb)
    b = _create_streamed(ddb)
    try:
        only_a = streams.list_streams(TableName=a)["Streams"]
        assert len(only_a) == 1
        assert only_a[0]["TableName"] == a
    finally:
        ddb.delete_table(TableName=a)
        ddb.delete_table(TableName=b)


def test_describe_stream_returns_open_shard(ddb, streams):
    name = _create_streamed(ddb)
    try:
        ddb.put_item(TableName=name, Item={"id": {"S": "k1"}})
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        sd = streams.describe_stream(StreamArn=arn)["StreamDescription"]
        assert sd["StreamStatus"] == "ENABLED"
        assert sd["StreamViewType"] == "NEW_AND_OLD_IMAGES"
        assert sd["TableName"] == name
        assert len(sd["KeySchema"]) == 1
        assert sd["KeySchema"][0]["AttributeName"] == "id"
        assert len(sd["Shards"]) == 1
        shard = sd["Shards"][0]
        assert shard["ShardId"].startswith("shardId-")
        rng = shard["SequenceNumberRange"]
        assert "StartingSequenceNumber" in rng
        # Open shard → no EndingSequenceNumber.
        assert "EndingSequenceNumber" not in rng
    finally:
        ddb.delete_table(TableName=name)


def test_describe_stream_invalid_arn_returns_validation(streams):
    # boto3 client-side requires min length 37; pass something long enough
    # to reach our server-side parser, which then rejects the malformed ARN.
    bogus = "arn:aws:dynamodb:us-east-1:000000000000:not-a-stream-arn"
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        streams.describe_stream(StreamArn=bogus)
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_get_records_trim_horizon_yields_inserts(ddb, streams):
    name = _create_streamed(ddb)
    try:
        for i in range(3):
            ddb.put_item(TableName=name, Item={"id": {"S": f"k{i}"}, "v": {"N": str(i)}})
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        out = streams.get_records(ShardIterator=it)
        assert len(out["Records"]) == 3
        assert [r["eventName"] for r in out["Records"]] == ["INSERT", "INSERT", "INSERT"]
        assert out["Records"][0]["dynamodb"]["NewImage"] == {"id": {"S": "k0"}, "v": {"N": "0"}}
        assert "NextShardIterator" in out
    finally:
        ddb.delete_table(TableName=name)


def test_get_records_after_modify_and_delete(ddb, streams):
    name = _create_streamed(ddb)
    try:
        ddb.put_item(TableName=name, Item={"id": {"S": "a"}, "v": {"N": "1"}})
        ddb.update_item(
            TableName=name,
            Key={"id": {"S": "a"}},
            UpdateExpression="SET v = :v",
            ExpressionAttributeValues={":v": {"N": "2"}},
        )
        ddb.delete_item(TableName=name, Key={"id": {"S": "a"}})

        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        out = streams.get_records(ShardIterator=it)
        kinds = [r["eventName"] for r in out["Records"]]
        assert kinds == ["INSERT", "MODIFY", "REMOVE"]
        # MODIFY carries both images.
        m = out["Records"][1]["dynamodb"]
        assert m["OldImage"] == {"id": {"S": "a"}, "v": {"N": "1"}}
        assert m["NewImage"] == {"id": {"S": "a"}, "v": {"N": "2"}}
        # REMOVE carries OldImage only.
        r = out["Records"][2]["dynamodb"]
        assert r["OldImage"] == {"id": {"S": "a"}, "v": {"N": "2"}}
        assert "NewImage" not in r
    finally:
        ddb.delete_table(TableName=name)


def test_get_records_latest_skips_backlog(ddb, streams):
    name = _create_streamed(ddb)
    try:
        ddb.put_item(TableName=name, Item={"id": {"S": "before"}})
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="LATEST")["ShardIterator"]
        ddb.put_item(TableName=name, Item={"id": {"S": "after"}})
        out = streams.get_records(ShardIterator=it)
        keys = [r["dynamodb"]["Keys"]["id"]["S"] for r in out["Records"]]
        assert keys == ["after"]
    finally:
        ddb.delete_table(TableName=name)


def test_get_records_after_sequence_number(ddb, streams):
    name = _create_streamed(ddb)
    try:
        for i in range(4):
            ddb.put_item(TableName=name, Item={"id": {"S": f"k{i}"}})
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        # Read all to pick up a known sequence number, then continue after it.
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        all_recs = streams.get_records(ShardIterator=it)["Records"]
        target_seq = all_recs[1]["dynamodb"]["SequenceNumber"]
        it2 = streams.get_shard_iterator(
            StreamArn=arn, ShardId=shard,
            ShardIteratorType="AFTER_SEQUENCE_NUMBER",
            SequenceNumber=target_seq,
        )["ShardIterator"]
        rest = streams.get_records(ShardIterator=it2)["Records"]
        assert len(rest) == 2
        assert rest[0]["dynamodb"]["SequenceNumber"] > target_seq
    finally:
        ddb.delete_table(TableName=name)


def test_get_records_at_sequence_number(ddb, streams):
    name = _create_streamed(ddb)
    try:
        for i in range(3):
            ddb.put_item(TableName=name, Item={"id": {"S": f"k{i}"}})
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        all_recs = streams.get_records(ShardIterator=it)["Records"]
        target_seq = all_recs[1]["dynamodb"]["SequenceNumber"]
        it2 = streams.get_shard_iterator(
            StreamArn=arn, ShardId=shard,
            ShardIteratorType="AT_SEQUENCE_NUMBER",
            SequenceNumber=target_seq,
        )["ShardIterator"]
        from_here = streams.get_records(ShardIterator=it2)["Records"]
        assert len(from_here) == 2
        assert from_here[0]["dynamodb"]["SequenceNumber"] == target_seq
    finally:
        ddb.delete_table(TableName=name)


@pytest.mark.parametrize("view_type,wants_new,wants_old", [
    ("NEW_IMAGE", True, False),
    ("OLD_IMAGE", False, True),
    ("NEW_AND_OLD_IMAGES", True, True),
    ("KEYS_ONLY", False, False),
])
def test_view_type_filters_images(ddb, streams, view_type, wants_new, wants_old):
    name = _create_streamed(ddb, view_type=view_type)
    try:
        ddb.put_item(TableName=name, Item={"id": {"S": "a"}, "v": {"N": "1"}})
        ddb.update_item(
            TableName=name, Key={"id": {"S": "a"}},
            UpdateExpression="SET v = :v",
            ExpressionAttributeValues={":v": {"N": "2"}},
        )
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        recs = streams.get_records(ShardIterator=it)["Records"]
        modify = recs[1]["dynamodb"]
        assert ("NewImage" in modify) == wants_new
        assert ("OldImage" in modify) == wants_old
        # Keys always present.
        assert modify["Keys"] == {"id": {"S": "a"}}
    finally:
        ddb.delete_table(TableName=name)


def test_capture_through_batch_write_item(ddb, streams):
    name = _create_streamed(ddb)
    try:
        ddb.batch_write_item(RequestItems={name: [
            {"PutRequest": {"Item": {"id": {"S": "b1"}}}},
            {"PutRequest": {"Item": {"id": {"S": "b2"}}}},
        ]})
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        recs = streams.get_records(ShardIterator=it)["Records"]
        assert {r["dynamodb"]["Keys"]["id"]["S"] for r in recs} == {"b1", "b2"}
        assert all(r["eventName"] == "INSERT" for r in recs)
    finally:
        ddb.delete_table(TableName=name)


def test_capture_through_transact_write_items(ddb, streams):
    name = _create_streamed(ddb)
    try:
        ddb.transact_write_items(TransactItems=[
            {"Put": {"TableName": name, "Item": {"id": {"S": "t1"}}}},
            {"Put": {"TableName": name, "Item": {"id": {"S": "t2"}}}},
        ])
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        recs = streams.get_records(ShardIterator=it)["Records"]
        assert {r["dynamodb"]["Keys"]["id"]["S"] for r in recs} == {"t1", "t2"}
        assert all(r["eventName"] == "INSERT" for r in recs)
    finally:
        ddb.delete_table(TableName=name)


def test_get_records_next_iterator_replays_no_records(ddb, streams):
    """After reading all records, NextShardIterator returns the same
    position; calling GetRecords on it returns an empty page (the shard
    is still open). This is the long-polling fallback consumers use."""
    name = _create_streamed(ddb)
    try:
        ddb.put_item(TableName=name, Item={"id": {"S": "only"}})
        arn = streams.list_streams(TableName=name)["Streams"][0]["StreamArn"]
        shard = streams.describe_stream(StreamArn=arn)["StreamDescription"]["Shards"][0]["ShardId"]
        it = streams.get_shard_iterator(StreamArn=arn, ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
        first = streams.get_records(ShardIterator=it)
        assert len(first["Records"]) == 1
        next_it = first["NextShardIterator"]
        second = streams.get_records(ShardIterator=next_it)
        assert second["Records"] == []
        # Open shard → always supplies the next iterator.
        assert "NextShardIterator" in second
    finally:
        ddb.delete_table(TableName=name)


def test_kinesis_destination_ops_are_rejected(ddb, created_table):
    # These two live on the core DDB service (not Streams). We deny them
    # explicitly because Kinesis isn't emulated.
    name = created_table(stream_spec=None)
    for op in ("enable_kinesis_streaming_destination", "disable_kinesis_streaming_destination"):
        with pytest.raises(botocore.exceptions.ClientError) as ei:
            getattr(ddb, op)(
                TableName=name,
                StreamArn=f"arn:aws:kinesis:us-east-1:000000000000:stream/{name}-kinesis",
            )
        err = ei.value.response["Error"]
        assert err["Code"] == "ValidationException", err
        assert "Kinesis" in err["Message"], err


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
