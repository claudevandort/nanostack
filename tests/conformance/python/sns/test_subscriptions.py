"""SNS subscription conformance — Phase C of v0.4.0."""

from __future__ import annotations

import secrets

import boto3
import pytest
from botocore.config import Config

from conftest import endpoint


def _make_sns():
    return boto3.client(
        "sns", endpoint_url=endpoint(), region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


def _make_sqs():
    return boto3.client(
        "sqs", endpoint_url=endpoint(), region_name="us-east-1",
        aws_access_key_id="test", aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 1}),
    )


@pytest.fixture
def sns():
    return _make_sns()


@pytest.fixture
def sqs():
    return _make_sqs()


def _topic(sns):
    name = f"t_{secrets.token_hex(4)}"
    arn = sns.create_topic(Name=name)["TopicArn"]
    return name, arn


def _queue(sqs):
    name = f"q_{secrets.token_hex(4)}"
    url = sqs.create_queue(QueueName=name)["QueueUrl"]
    arn = f"arn:aws:sqs:us-east-1:000000000000:{name}"
    return name, url, arn


def test_subscribe_returns_arn_immediately(sns, sqs):
    _, topic_arn = _topic(sns)
    _, qurl, qarn = _queue(sqs)
    try:
        out = sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=qarn)
        # AWS-real returns either an ARN (auto-confirmed) or "PendingConfirmation"
        # for http/email. For SQS, we auto-confirm so the ARN starts with arn:.
        assert out["SubscriptionArn"].startswith("arn:aws:sns:")
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=qurl)


def test_list_subscriptions_by_topic_includes_sub(sns, sqs):
    _, topic_arn = _topic(sns)
    _, qurl, qarn = _queue(sqs)
    try:
        sub_arn = sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=qarn)["SubscriptionArn"]
        out = sns.list_subscriptions_by_topic(TopicArn=topic_arn)
        arns = [s["SubscriptionArn"] for s in out["Subscriptions"]]
        assert sub_arn in arns
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=qurl)


def test_list_subscriptions_includes_sub(sns, sqs):
    _, topic_arn = _topic(sns)
    _, qurl, qarn = _queue(sqs)
    try:
        sub_arn = sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=qarn)["SubscriptionArn"]
        out = sns.list_subscriptions()
        arns = [s["SubscriptionArn"] for s in out["Subscriptions"]]
        assert sub_arn in arns
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=qurl)


def test_get_subscription_attributes(sns, sqs):
    _, topic_arn = _topic(sns)
    _, qurl, qarn = _queue(sqs)
    try:
        sub_arn = sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=qarn)["SubscriptionArn"]
        out = sns.get_subscription_attributes(SubscriptionArn=sub_arn)
        attrs = out["Attributes"]
        assert attrs["TopicArn"] == topic_arn
        assert attrs["Protocol"] == "sqs"
        assert attrs["Endpoint"] == qarn
        assert attrs["RawMessageDelivery"] == "false"
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=qurl)


def test_set_subscription_raw_message_delivery(sns, sqs):
    _, topic_arn = _topic(sns)
    _, qurl, qarn = _queue(sqs)
    try:
        sub_arn = sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=qarn)["SubscriptionArn"]
        sns.set_subscription_attributes(
            SubscriptionArn=sub_arn,
            AttributeName="RawMessageDelivery",
            AttributeValue="true",
        )
        out = sns.get_subscription_attributes(SubscriptionArn=sub_arn)
        assert out["Attributes"]["RawMessageDelivery"] == "true"
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=qurl)


def test_unsubscribe_removes_sub(sns, sqs):
    _, topic_arn = _topic(sns)
    _, qurl, qarn = _queue(sqs)
    try:
        sub_arn = sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=qarn)["SubscriptionArn"]
        sns.unsubscribe(SubscriptionArn=sub_arn)
        out = sns.list_subscriptions_by_topic(TopicArn=topic_arn)
        arns = [s["SubscriptionArn"] for s in out["Subscriptions"]]
        assert sub_arn not in arns
    finally:
        sns.delete_topic(TopicArn=topic_arn)
        sqs.delete_queue(QueueUrl=qurl)


def test_lambda_protocol_stored_but_never_fires(sns):
    """lambda subs are accept-store-roundtrip (no Lambda service to deliver to)."""
    _, topic_arn = _topic(sns)
    try:
        sub_arn = sns.subscribe(
            TopicArn=topic_arn,
            Protocol="lambda",
            Endpoint="arn:aws:lambda:us-east-1:000000000000:function:foo",
        )["SubscriptionArn"]
        out = sns.list_subscriptions_by_topic(TopicArn=topic_arn)
        arns = [s["SubscriptionArn"] for s in out["Subscriptions"]]
        assert sub_arn in arns
    finally:
        sns.delete_topic(TopicArn=topic_arn)
