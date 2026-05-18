// SNS robustness conformance — JS suite (v0.4.1).
import { describe, it, expect } from "vitest";
import {
  SNSClient,
  CreateTopicCommand,
  DeleteTopicCommand,
  AddPermissionCommand,
  RemovePermissionCommand,
  GetTopicAttributesCommand,
  SubscribeCommand,
  PublishCommand,
  SetSubscriptionAttributesCommand,
} from "@aws-sdk/client-sns";
import {
  SQSClient,
  CreateQueueCommand,
  DeleteQueueCommand,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from "@aws-sdk/client-sqs";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newSns(): SNSClient {
  return new SNSClient({
    endpoint, region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}
function newSqs(): SQSClient {
  return new SQSClient({
    endpoint, region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}
function uniq(p: string): string {
  return `${p}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

async function drain(sqs: SQSClient, url: string, maxS = 3): Promise<any[]> {
  const deadline = Date.now() + maxS * 1000;
  const out: any[] = [];
  while (Date.now() < deadline) {
    const resp = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: url, MaxNumberOfMessages: 10, WaitTimeSeconds: 1,
    }));
    const msgs = resp.Messages ?? [];
    if (!msgs.length) {
      if (out.length) return out;
      continue;
    }
    for (const m of msgs) {
      out.push(m);
      await sqs.send(new DeleteMessageCommand({ QueueUrl: url, ReceiptHandle: m.ReceiptHandle! }));
    }
  }
  return out;
}

describe("sns robustness (js)", () => {
  const sns = newSns();
  const sqs = newSqs();

  it("AddPermission round-trips into Policy", async () => {
    const arn = (await sns.send(new CreateTopicCommand({ Name: uniq("t") }))).TopicArn!;
    try {
      await sns.send(new AddPermissionCommand({
        TopicArn: arn,
        Label: "g1",
        AWSAccountId: ["111122223333"],
        ActionName: ["Publish"],
      }));
      const attrs = (await sns.send(new GetTopicAttributesCommand({ TopicArn: arn }))).Attributes!;
      expect(attrs.Policy).toContain("g1");
      expect(attrs.Policy).toContain("sns:Publish");
    } finally {
      await sns.send(new DeleteTopicCommand({ TopicArn: arn }));
    }
  });

  it("RemovePermission drops matching statement", async () => {
    const arn = (await sns.send(new CreateTopicCommand({ Name: uniq("t") }))).TopicArn!;
    try {
      await sns.send(new AddPermissionCommand({
        TopicArn: arn, Label: "g1",
        AWSAccountId: ["111122223333"], ActionName: ["Publish"],
      }));
      await sns.send(new AddPermissionCommand({
        TopicArn: arn, Label: "g2",
        AWSAccountId: ["444455556666"], ActionName: ["Subscribe"],
      }));
      await sns.send(new RemovePermissionCommand({ TopicArn: arn, Label: "g1" }));
      const policy = (await sns.send(new GetTopicAttributesCommand({ TopicArn: arn }))).Attributes!.Policy!;
      expect(policy).not.toContain("g1");
      expect(policy).toContain("g2");
    } finally {
      await sns.send(new DeleteTopicCommand({ TopicArn: arn }));
    }
  });

  it("FilterPolicy gates delivery", async () => {
    const tname = uniq("t");
    const qname = uniq("q");
    const topicArn = (await sns.send(new CreateTopicCommand({ Name: tname }))).TopicArn!;
    const queueUrl = (await sqs.send(new CreateQueueCommand({ QueueName: qname }))).QueueUrl!;
    try {
      const subArn = (await sns.send(new SubscribeCommand({
        TopicArn: topicArn,
        Protocol: "sqs",
        Endpoint: `arn:aws:sqs:us-east-1:000000000000:${qname}`,
      }))).SubscriptionArn!;
      await sns.send(new SetSubscriptionAttributesCommand({
        SubscriptionArn: subArn,
        AttributeName: "FilterPolicy",
        AttributeValue: JSON.stringify({ category: ["news"] }),
      }));
      // Non-matching attribute → filtered out.
      await sns.send(new PublishCommand({
        TopicArn: topicArn,
        Message: "filtered",
        MessageAttributes: {
          category: { DataType: "String", StringValue: "sports" },
        },
      }));
      // Matching attribute → delivered.
      await sns.send(new PublishCommand({
        TopicArn: topicArn,
        Message: "delivered",
        MessageAttributes: {
          category: { DataType: "String", StringValue: "news" },
        },
      }));
      const msgs = await drain(sqs, queueUrl);
      expect(msgs.length).toBe(1);
      const body = JSON.parse(msgs[0].Body!);
      expect(body.Message).toBe("delivered");
    } finally {
      await sns.send(new DeleteTopicCommand({ TopicArn: topicArn }));
      await sqs.send(new DeleteQueueCommand({ QueueUrl: queueUrl }));
    }
  });
});
