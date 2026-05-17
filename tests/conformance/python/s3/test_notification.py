"""BucketNotificationConfiguration conformance."""

from conftest import best_effort_delete_bucket


def test_notification_topic_config_round_trip(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_notification_configuration(
            Bucket=bucket_name,
            NotificationConfiguration={
                "TopicConfigurations": [
                    {
                        "TopicArn": "arn:aws:sns:us-east-1:1:t",
                        "Events": ["s3:ObjectCreated:Put"],
                    }
                ]
            },
        )
        out = s3.get_bucket_notification_configuration(Bucket=bucket_name)
        topics = out.get("TopicConfigurations", [])
        assert len(topics) == 1 and topics[0]["TopicArn"] == "arn:aws:sns:us-east-1:1:t", (
            f"topic arn mismatch: {topics}"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_notification_queue_with_filter(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        s3.put_bucket_notification_configuration(
            Bucket=bucket_name,
            NotificationConfiguration={
                "QueueConfigurations": [
                    {
                        "QueueArn": "arn:aws:sqs:us-east-1:1:q",
                        "Events": ["s3:ObjectCreated:*"],
                        "Filter": {
                            "Key": {
                                "FilterRules": [
                                    {"Name": "prefix", "Value": "uploads/"}
                                ]
                            }
                        },
                    }
                ]
            },
        )
        out = s3.get_bucket_notification_configuration(Bucket=bucket_name)
        queues = out.get("QueueConfigurations", [])
        assert len(queues) == 1, "expected 1 queue config"
        q = queues[0]
        assert "Filter" in q and "Key" in q["Filter"] and len(q["Filter"]["Key"]["FilterRules"]) == 1, (
            "filter missing"
        )
        assert q["Filter"]["Key"]["FilterRules"][0]["Value"] == "uploads/", (
            "filter value mismatch"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_notification_empty_on_untouched(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        out = s3.get_bucket_notification_configuration(Bucket=bucket_name)
        assert (
            len(out.get("TopicConfigurations", []) or []) == 0
            and len(out.get("QueueConfigurations", []) or []) == 0
            and len(out.get("LambdaFunctionConfigurations", []) or []) == 0
        ), f"expected empty config, got {out}"
    finally:
        best_effort_delete_bucket(s3, bucket_name)


def test_notification_empty_put_clears(s3, bucket_name):
    s3.create_bucket(Bucket=bucket_name)
    try:
        # Set then clear.
        s3.put_bucket_notification_configuration(
            Bucket=bucket_name,
            NotificationConfiguration={
                "TopicConfigurations": [
                    {
                        "TopicArn": "arn:aws:sns:us-east-1:1:t",
                        "Events": ["s3:ObjectCreated:Put"],
                    }
                ]
            },
        )
        s3.put_bucket_notification_configuration(
            Bucket=bucket_name, NotificationConfiguration={}
        )
        out = s3.get_bucket_notification_configuration(Bucket=bucket_name)
        assert len(out.get("TopicConfigurations", []) or []) == 0, (
            "empty Put should have cleared config"
        )
    finally:
        best_effort_delete_bucket(s3, bucket_name)
