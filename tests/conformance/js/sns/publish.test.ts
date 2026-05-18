// SNS Publish + fan-out to SQS — JS suite (v0.4.0).
import { describe, it, expect } from "vitest";
import {
  SNSClient,
  CreateTopicCommand,
  DeleteTopicCommand,
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

async function drain(sqs: SQSClient, url: string, maxS = 5): Promise<any[]> {
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

describe("sns publish (js)", () => {
  const sns = newSns();
  const sqs = newSqs();

  it("Publish delivers envelope to SQS subscriber", async () => {
    const tname = uniq("t");
    const qname = uniq("q");
    const topicArn = (await sns.send(new CreateTopicCommand({ Name: tname }))).TopicArn!;
    const queueUrl = (await sqs.send(new CreateQueueCommand({ QueueName: qname }))).QueueUrl!;
    try {
      await sns.send(new SubscribeCommand({
        TopicArn: topicArn,
        Protocol: "sqs",
        Endpoint: `arn:aws:sqs:us-east-1:000000000000:${qname}`,
      }));
      await sns.send(new PublishCommand({ TopicArn: topicArn, Message: "hello" }));
      const msgs = await drain(sqs, queueUrl);
      expect(msgs.length).toBe(1);
      const body = JSON.parse(msgs[0].Body!);
      expect(body.Type).toBe("Notification");
      expect(body.Message).toBe("hello");
    } finally {
      await sns.send(new DeleteTopicCommand({ TopicArn: topicArn }));
      await sqs.send(new DeleteQueueCommand({ QueueUrl: queueUrl }));
    }
  });

  it("Publish with RawMessageDelivery delivers raw bytes", async () => {
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
        AttributeName: "RawMessageDelivery",
        AttributeValue: "true",
      }));
      await sns.send(new PublishCommand({ TopicArn: topicArn, Message: "raw-bytes" }));
      const msgs = await drain(sqs, queueUrl);
      expect(msgs[0].Body).toBe("raw-bytes");
    } finally {
      await sns.send(new DeleteTopicCommand({ TopicArn: topicArn }));
      await sqs.send(new DeleteQueueCommand({ QueueUrl: queueUrl }));
    }
  });

  it("Publish fans out to multiple SQS subs", async () => {
    const tname = uniq("t");
    const q1n = uniq("q");
    const q2n = uniq("q");
    const topicArn = (await sns.send(new CreateTopicCommand({ Name: tname }))).TopicArn!;
    const u1 = (await sqs.send(new CreateQueueCommand({ QueueName: q1n }))).QueueUrl!;
    const u2 = (await sqs.send(new CreateQueueCommand({ QueueName: q2n }))).QueueUrl!;
    try {
      await sns.send(new SubscribeCommand({ TopicArn: topicArn, Protocol: "sqs", Endpoint: `arn:aws:sqs:us-east-1:000000000000:${q1n}` }));
      await sns.send(new SubscribeCommand({ TopicArn: topicArn, Protocol: "sqs", Endpoint: `arn:aws:sqs:us-east-1:000000000000:${q2n}` }));
      await sns.send(new PublishCommand({ TopicArn: topicArn, Message: "fan-out" }));
      expect((await drain(sqs, u1)).length).toBe(1);
      expect((await drain(sqs, u2)).length).toBe(1);
    } finally {
      await sns.send(new DeleteTopicCommand({ TopicArn: topicArn }));
      await sqs.send(new DeleteQueueCommand({ QueueUrl: u1 }));
      await sqs.send(new DeleteQueueCommand({ QueueUrl: u2 }));
    }
  });
});
