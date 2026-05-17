"""DynamoDB Streams via `aws dynamodbstreams` v2 CLI (v0.2.2)."""

from __future__ import annotations

import json
import secrets

import pytest

from conftest import run_aws


@pytest.fixture
def streamed_table():
    name = f"cli-strm-{secrets.token_hex(4)}"
    run_aws(
        "dynamodb", "create-table",
        "--table-name", name,
        "--attribute-definitions", "AttributeName=id,AttributeType=S",
        "--key-schema", "AttributeName=id,KeyType=HASH",
        "--billing-mode", "PAY_PER_REQUEST",
        "--stream-specification", "StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES",
    )
    yield name
    run_aws("dynamodb", "delete-table", "--table-name", name, check=False)


def _list_arn(table: str) -> str:
    out = run_aws("dynamodbstreams", "list-streams", "--table-name", table, json_output=True).json()
    assert out["Streams"], out
    return out["Streams"][0]["StreamArn"]


def _shard(arn: str) -> str:
    out = run_aws("dynamodbstreams", "describe-stream", "--stream-arn", arn, json_output=True).json()
    return out["StreamDescription"]["Shards"][0]["ShardId"]


def test_list_streams_finds_enabled_table(streamed_table):
    out = run_aws("dynamodbstreams", "list-streams", "--table-name", streamed_table, json_output=True).json()
    assert len(out["Streams"]) == 1
    assert out["Streams"][0]["TableName"] == streamed_table
    assert out["Streams"][0]["StreamArn"].startswith(
        f"arn:aws:dynamodb:us-east-1:000000000000:table/{streamed_table}/stream/"
    )


def test_describe_stream_shape(streamed_table):
    arn = _list_arn(streamed_table)
    out = run_aws("dynamodbstreams", "describe-stream", "--stream-arn", arn, json_output=True).json()
    sd = out["StreamDescription"]
    assert sd["StreamStatus"] == "ENABLED"
    assert sd["StreamViewType"] == "NEW_AND_OLD_IMAGES"
    assert sd["TableName"] == streamed_table
    assert len(sd["Shards"]) == 1
    shard = sd["Shards"][0]
    assert shard["ShardId"].startswith("shardId-")
    # Open shard: no EndingSequenceNumber.
    assert "EndingSequenceNumber" not in shard["SequenceNumberRange"]


def test_get_records_trim_horizon(streamed_table):
    # Seed one item, then exercise the get-shard-iterator + get-records pair.
    run_aws("dynamodb", "put-item",
            "--table-name", streamed_table,
            "--item", json.dumps({"id": {"S": "x"}, "v": {"N": "1"}}))
    arn = _list_arn(streamed_table)
    shard = _shard(arn)
    it = run_aws(
        "dynamodbstreams", "get-shard-iterator",
        "--stream-arn", arn, "--shard-id", shard,
        "--shard-iterator-type", "TRIM_HORIZON",
        json_output=True,
    ).json()["ShardIterator"]
    rec = run_aws(
        "dynamodbstreams", "get-records",
        "--shard-iterator", it,
        json_output=True,
    ).json()
    assert len(rec["Records"]) == 1
    r = rec["Records"][0]
    assert r["eventName"] == "INSERT"
    assert r["dynamodb"]["Keys"] == {"id": {"S": "x"}}
    assert r["dynamodb"]["NewImage"] == {"id": {"S": "x"}, "v": {"N": "1"}}
    assert "NextShardIterator" in rec
