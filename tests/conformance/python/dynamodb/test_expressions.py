"""DynamoDB ConditionExpression + UpdateExpression conformance (M15-expressions).

Covers UpdateItem (SET / REMOVE / ADD / DELETE actions, if_not_exists,
list_append, atomic counters) and ConditionExpression on PutItem /
DeleteItem / UpdateItem (comparison ops, attribute_exists /
attribute_not_exists, begins_with, contains, BETWEEN, IN, AND / OR / NOT).
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


def _unique(prefix, request):
    safe = request.node.name.replace("[", "-").replace("]", "")[:80]
    return f"{prefix}-{safe}"


@pytest.fixture
def table(ddb, request):
    name = _unique("expr", request)
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


# ---------------------------------------------------------------------------
# UpdateExpression — SET

def test_update_set_assigns_new_attribute(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET label = :v",
        ExpressionAttributeValues={":v": {"S": "x"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["label"] == {"S": "x"}


def test_update_set_overwrites_existing(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "v": {"S": "old"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET v = :n",
        ExpressionAttributeValues={":n": {"S": "new"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["v"] == {"S": "new"}


def test_update_set_arithmetic_counter(ddb, table):
    """Atomic counter: SET x = x + :v."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "tally": {"N": "10"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET #c = #c + :inc",
        ExpressionAttributeNames={"#c": "tally"},
        ExpressionAttributeValues={":inc": {"N": "5"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["tally"]["N"] in {"15", "15.0"}


def test_update_set_if_not_exists(ddb, table):
    """if_not_exists keeps existing value when set, otherwise uses fallback."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "name": {"S": "Bob"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET #n = if_not_exists(#n, :v)",
        ExpressionAttributeNames={"#n": "name"},
        ExpressionAttributeValues={":v": {"S": "Anon"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["name"] == {"S": "Bob"}  # unchanged


# ---------------------------------------------------------------------------
# UpdateExpression — REMOVE / ADD / DELETE

def test_update_remove_attribute(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "a": {"S": "1"}, "b": {"S": "2"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="REMOVE a",
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert "a" not in got["Item"]
    assert got["Item"]["b"] == {"S": "2"}


def test_update_add_counter_creates_when_missing(ddb, table):
    """ADD on a missing attribute initialises it."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="ADD tally :inc",
        ExpressionAttributeValues={":inc": {"N": "1"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["tally"]["N"] in {"1", "1.0"}


def test_update_add_increments_existing(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "tally": {"N": "10"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="ADD tally :inc",
        ExpressionAttributeValues={":inc": {"N": "3"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["tally"]["N"] in {"13", "13.0"}


# ---------------------------------------------------------------------------
# UpdateItem ReturnValues

def test_update_return_values_all_new(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "v": {"S": "old"}})
    out = ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET v = :n",
        ExpressionAttributeValues={":n": {"S": "new"}},
        ReturnValues="ALL_NEW",
    )
    assert out["Attributes"]["v"] == {"S": "new"}


def test_update_return_values_all_old(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "v": {"S": "old"}})
    out = ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET v = :n",
        ExpressionAttributeValues={":n": {"S": "new"}},
        ReturnValues="ALL_OLD",
    )
    assert out["Attributes"]["v"] == {"S": "old"}


# ---------------------------------------------------------------------------
# ConditionExpression — PutItem

def test_put_with_attribute_not_exists_succeeds_when_absent(ddb, table):
    """Idempotent insert: only put if the key doesn't already exist."""
    ddb.put_item(
        TableName=table,
        Item={"id": {"S": "fresh"}, "v": {"S": "x"}},
        ConditionExpression="attribute_not_exists(id)",
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "fresh"}})
    assert got["Item"]["v"] == {"S": "x"}


def test_put_with_attribute_not_exists_fails_when_present(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "v": {"S": "old"}})
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.put_item(
            TableName=table,
            Item={"id": {"S": "k"}, "v": {"S": "new"}},
            ConditionExpression="attribute_not_exists(id)",
        )
    assert ei.value.response["Error"]["Code"] == "ConditionalCheckFailedException"


def test_put_with_comparison_condition(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "version": {"N": "1"}})
    # version > :v passes when version=1, :v=0
    ddb.put_item(
        TableName=table,
        Item={"id": {"S": "k"}, "version": {"N": "2"}},
        ConditionExpression="version > :prev",
        ExpressionAttributeValues={":prev": {"N": "0"}},
    )
    # ...and fails when :v >= current
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.put_item(
            TableName=table,
            Item={"id": {"S": "k"}, "version": {"N": "3"}},
            ConditionExpression="version > :prev",
            ExpressionAttributeValues={":prev": {"N": "99"}},
        )
    assert ei.value.response["Error"]["Code"] == "ConditionalCheckFailedException"


# ---------------------------------------------------------------------------
# ConditionExpression — DeleteItem

def test_delete_with_condition(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "version": {"N": "5"}})
    ddb.delete_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        ConditionExpression="version = :v",
        ExpressionAttributeValues={":v": {"N": "5"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert "Item" not in got


def test_delete_failing_condition_keeps_item(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "version": {"N": "5"}})
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.delete_item(
            TableName=table,
            Key={"id": {"S": "k"}},
            ConditionExpression="version = :v",
            ExpressionAttributeValues={":v": {"N": "99"}},
        )
    assert ei.value.response["Error"]["Code"] == "ConditionalCheckFailedException"
    # Item still there
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["version"] == {"N": "5"}


# ---------------------------------------------------------------------------
# ConditionExpression — function shapes

def test_condition_begins_with(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "name": {"S": "Alice"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET flag = :v",
        ConditionExpression="begins_with(#n, :p)",
        ExpressionAttributeNames={"#n": "name"},
        ExpressionAttributeValues={":v": {"S": "ok"}, ":p": {"S": "Al"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["flag"] == {"S": "ok"}


def test_condition_and_chain(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "a": {"S": "1"}, "b": {"S": "2"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET flag = :v",
        ConditionExpression="a = :a AND b = :b",
        ExpressionAttributeValues={":v": {"S": "ok"}, ":a": {"S": "1"}, ":b": {"S": "2"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["flag"] == {"S": "ok"}


def test_condition_between(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "n": {"N": "5"}})
    ddb.update_item(
        TableName=table,
        Key={"id": {"S": "k"}},
        UpdateExpression="SET ok = :v",
        ConditionExpression="n BETWEEN :lo AND :hi",
        ExpressionAttributeValues={":v": {"S": "y"}, ":lo": {"N": "1"}, ":hi": {"N": "10"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["ok"] == {"S": "y"}


# ---------------------------------------------------------------------------
# Reserved-word enforcement (v0.2.1)

def test_condition_with_reserved_word_rejected(ddb, table):
    """`Status` is an AWS reserved word; bare use must be rejected."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "Status": {"S": "pending"}})
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.scan(
            TableName=table,
            FilterExpression="Status = :v",
            ExpressionAttributeValues={":v": {"S": "pending"}},
        )
    assert ei.value.response["Error"]["Code"] == "ValidationException"


def test_condition_with_reserved_word_via_placeholder_ok(ddb, table):
    """`#s` aliased to `Status` works."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "Status": {"S": "pending"}})
    out = ddb.scan(
        TableName=table,
        FilterExpression="#s = :v",
        ExpressionAttributeNames={"#s": "Status"},
        ExpressionAttributeValues={":v": {"S": "pending"}},
    )
    assert out["Count"] == 1


def test_update_expression_reserved_word_rejected(ddb, table):
    """UpdateExpression rejects bare reserved words too."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "Name": {"S": "Bob"}})
    with pytest.raises(botocore.exceptions.ClientError) as ei:
        ddb.update_item(
            TableName=table,
            Key={"id": {"S": "k"}},
            UpdateExpression="SET Name = :v",  # Name is reserved
            ExpressionAttributeValues={":v": {"S": "Alice"}},
        )
    assert ei.value.response["Error"]["Code"] == "ValidationException"


# ---------------------------------------------------------------------------
# Backfill (v0.2.1): expression shapes implemented in v0.2.0 but untested.

def test_condition_ne(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "v": {"S": "x"}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET flag = :on",
        ConditionExpression="v <> :different",
        ExpressionAttributeValues={":on": {"S": "y"}, ":different": {"S": "other"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["flag"] == {"S": "y"}


def test_condition_le_and_ge(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "n": {"N": "5"}})
    # <= passes
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET tag = :t",
        ConditionExpression="n <= :hi",
        ExpressionAttributeValues={":t": {"S": "le"}, ":hi": {"N": "5"}},
    )
    # >= passes
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET tag = :t",
        ConditionExpression="n >= :lo",
        ExpressionAttributeValues={":t": {"S": "ge"}, ":lo": {"N": "5"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["tag"] == {"S": "ge"}


def test_condition_or_chain(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "a": {"S": "x"}, "b": {"S": "y"}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET ok = :v",
        ConditionExpression="a = :wrong OR b = :right",
        ExpressionAttributeValues={":v": {"S": "yes"}, ":wrong": {"S": "z"}, ":right": {"S": "y"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["ok"] == {"S": "yes"}


def test_condition_not_inverts(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "v": {"S": "x"}})
    # NOT v = :other → true → passes
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET ok = :v",
        ConditionExpression="NOT v = :other",
        ExpressionAttributeValues={":v": {"S": "yes"}, ":other": {"S": "z"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["ok"] == {"S": "yes"}


def test_condition_parens_precedence(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "a": {"S": "x"}, "b": {"S": "y"}})
    # (a = :wrong OR b = :right) AND a = :wrong → false (because (T) AND F = F)
    # Without parens AND binds tighter: a = :wrong OR (b = :right AND a = :wrong) → T OR F = T
    with pytest.raises(botocore.exceptions.ClientError):
        ddb.update_item(
            TableName=table, Key={"id": {"S": "k"}},
            UpdateExpression="SET ok = :v",
            ConditionExpression="(a = :wrong OR b = :right) AND a = :wrong",
            ExpressionAttributeValues={":v": {"S": "x"}, ":wrong": {"S": "z"}, ":right": {"S": "y"}},
        )


def test_condition_in_operator(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "tier": {"S": "gold"}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET ok = :v",
        ConditionExpression="tier IN (:a, :b, :c)",
        ExpressionAttributeValues={":v": {"S": "y"}, ":a": {"S": "bronze"}, ":b": {"S": "silver"}, ":c": {"S": "gold"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["ok"] == {"S": "y"}


def test_condition_attribute_type(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "n": {"N": "5"}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET ok = :v",
        ConditionExpression="attribute_type(n, :t)",
        ExpressionAttributeValues={":v": {"S": "y"}, ":t": {"S": "N"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["ok"] == {"S": "y"}


def test_condition_contains_string(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "title": {"S": "hello world"}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET ok = :v",
        ConditionExpression="contains(title, :needle)",
        ExpressionAttributeValues={":v": {"S": "y"}, ":needle": {"S": "world"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["ok"] == {"S": "y"}


def test_condition_contains_string_set(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "tags": {"SS": ["red", "blue"]}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET ok = :v",
        ConditionExpression="contains(tags, :elem)",
        ExpressionAttributeValues={":v": {"S": "y"}, ":elem": {"S": "blue"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})
    assert got["Item"]["ok"] == {"S": "y"}


def test_update_list_append(ddb, table):
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "elements": {"L": [{"S": "a"}]}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET elements = list_append(elements, :more)",
        ExpressionAttributeValues={":more": {"L": [{"S": "b"}, {"S": "c"}]}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})["Item"]
    elements = [e["S"] for e in got["elements"]["L"]]
    assert elements == ["a", "b", "c"]


def test_update_set_subtraction(ddb, table):
    """SET x = x - :v."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "tally": {"N": "10"}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET tally = tally - :n",
        ExpressionAttributeValues={":n": {"N": "3"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})["Item"]
    assert got["tally"]["N"] in {"7", "7.0"}


def test_update_add_on_string_set(ddb, table):
    """ADD on string set = set-union."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "tags": {"SS": ["red"]}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="ADD tags :more",
        ExpressionAttributeValues={":more": {"SS": ["blue", "red", "green"]}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})["Item"]
    assert set(got["tags"]["SS"]) == {"red", "blue", "green"}


def test_update_delete_from_set(ddb, table):
    """DELETE on string set = set-subtract."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "tags": {"SS": ["red", "blue", "green"]}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="DELETE tags :gone",
        ExpressionAttributeValues={":gone": {"SS": ["red", "blue"]}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})["Item"]
    assert got["tags"]["SS"] == ["green"]


def test_update_multi_section_set_and_remove(ddb, table):
    """SET ... REMOVE ... in one expression."""
    ddb.put_item(TableName=table, Item={"id": {"S": "k"}, "keep": {"S": "x"}, "discard": {"S": "y"}})
    ddb.update_item(
        TableName=table, Key={"id": {"S": "k"}},
        UpdateExpression="SET added = :v REMOVE discard",
        ExpressionAttributeValues={":v": {"S": "new"}},
    )
    got = ddb.get_item(TableName=table, Key={"id": {"S": "k"}})["Item"]
    assert got["added"] == {"S": "new"}
    assert got["keep"] == {"S": "x"}
    assert "discard" not in got
