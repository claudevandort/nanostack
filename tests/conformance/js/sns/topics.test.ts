// SNS topic CRUD — JS suite (v0.4.0).
import { describe, it, expect } from "vitest";
import {
  SNSClient,
  CreateTopicCommand,
  DeleteTopicCommand,
  ListTopicsCommand,
  GetTopicAttributesCommand,
} from "@aws-sdk/client-sns";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newSns(): SNSClient {
  return new SNSClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniq(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

describe("sns topics (js)", () => {
  const c = newSns();

  it("CreateTopic returns ARN", async () => {
    const name = uniq("t");
    const out = await c.send(new CreateTopicCommand({ Name: name }));
    try {
      expect(out.TopicArn).toBe(`arn:aws:sns:us-east-1:000000000000:${name}`);
    } finally {
      await c.send(new DeleteTopicCommand({ TopicArn: out.TopicArn! }));
    }
  });

  it("ListTopics includes the created topic", async () => {
    const name = uniq("t");
    const arn = (await c.send(new CreateTopicCommand({ Name: name }))).TopicArn!;
    try {
      const out = await c.send(new ListTopicsCommand({}));
      const arns = (out.Topics ?? []).map((t) => t.TopicArn);
      expect(arns).toContain(arn);
    } finally {
      await c.send(new DeleteTopicCommand({ TopicArn: arn }));
    }
  });

  it("GetTopicAttributes returns Owner + SubscriptionsConfirmed", async () => {
    const name = uniq("t");
    const arn = (await c.send(new CreateTopicCommand({ Name: name }))).TopicArn!;
    try {
      const out = await c.send(new GetTopicAttributesCommand({ TopicArn: arn }));
      expect(out.Attributes!.TopicArn).toBe(arn);
      expect(out.Attributes!.Owner).toBe("000000000000");
      expect(out.Attributes!.SubscriptionsConfirmed).toBeDefined();
    } finally {
      await c.send(new DeleteTopicCommand({ TopicArn: arn }));
    }
  });
});
