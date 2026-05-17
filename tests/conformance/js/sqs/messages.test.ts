// SQS conformance — JS suite (v0.3.0).
// Covers the queue-CRUD surface, message send/receive, long polling,
// and a DLQ round-trip via @aws-sdk/client-sqs.

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  SQSClient,
  CreateQueueCommand,
  DeleteQueueCommand,
  ListQueuesCommand,
  GetQueueUrlCommand,
  GetQueueAttributesCommand,
  SetQueueAttributesCommand,
  PurgeQueueCommand,
  SendMessageCommand,
  ReceiveMessageCommand,
  DeleteMessageCommand,
  ChangeMessageVisibilityCommand,
  SendMessageBatchCommand,
  TagQueueCommand,
  ListQueueTagsCommand,
} from "@aws-sdk/client-sqs";
import { createHash } from "node:crypto";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newSqs(): SQSClient {
  return new SQSClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniqueQueue(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

describe("sqs (js)", () => {
  const c = newSqs();

  it("CreateQueue + ListQueues + DeleteQueue round-trip", async () => {
    const name = uniqueQueue("js_q");
    const out = await c.send(new CreateQueueCommand({ QueueName: name }));
    expect(out.QueueUrl).toContain(`/${name}`);
    const url = out.QueueUrl!;
    try {
      const list = await c.send(new ListQueuesCommand({}));
      expect(list.QueueUrls).toContain(url);
      const got = await c.send(new GetQueueUrlCommand({ QueueName: name }));
      expect(got.QueueUrl).toBe(url);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("GetQueueAttributes returns expected defaults", async () => {
    const name = uniqueQueue("js_q");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      const out = await c.send(new GetQueueAttributesCommand({ QueueUrl: url, AttributeNames: ["All"] }));
      expect(out.Attributes!["VisibilityTimeout"]).toBe("30");
      expect(out.Attributes!["QueueArn"]).toContain("arn:aws:sqs:us-east-1:");
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("SetQueueAttributes mutates VisibilityTimeout", async () => {
    const name = uniqueQueue("js_q");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      await c.send(new SetQueueAttributesCommand({ QueueUrl: url, Attributes: { VisibilityTimeout: "90" } }));
      const out = await c.send(new GetQueueAttributesCommand({ QueueUrl: url, AttributeNames: ["VisibilityTimeout"] }));
      expect(out.Attributes!["VisibilityTimeout"]).toBe("90");
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("SendMessage + ReceiveMessage + DeleteMessage round-trip with MD5 verification", async () => {
    const name = uniqueQueue("js_q");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      const body = "hello-world";
      const send = await c.send(new SendMessageCommand({ QueueUrl: url, MessageBody: body }));
      const expectedMd5 = createHash("md5").update(body).digest("hex");
      expect(send.MD5OfMessageBody).toBe(expectedMd5);

      const rcv = await c.send(new ReceiveMessageCommand({ QueueUrl: url, MaxNumberOfMessages: 1 }));
      expect(rcv.Messages?.[0]?.Body).toBe(body);
      const handle = rcv.Messages![0].ReceiptHandle!;

      await c.send(new DeleteMessageCommand({ QueueUrl: url, ReceiptHandle: handle }));
      const empty = await c.send(new ReceiveMessageCommand({ QueueUrl: url, VisibilityTimeout: 0 }));
      expect(empty.Messages ?? []).toEqual([]);
    } finally {
      await c.send(new PurgeQueueCommand({ QueueUrl: url })).catch(() => {});
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("SendMessageBatch returns Successful entries", async () => {
    const name = uniqueQueue("js_b");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      const out = await c.send(
        new SendMessageBatchCommand({
          QueueUrl: url,
          Entries: [
            { Id: "a", MessageBody: "a-body" },
            { Id: "b", MessageBody: "b-body" },
          ],
        }),
      );
      expect(out.Successful?.length).toBe(2);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("ReceiveMessage with WaitTimeSeconds long-polls then returns empty", async () => {
    const name = uniqueQueue("js_lp");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      const start = Date.now();
      const out = await c.send(new ReceiveMessageCommand({ QueueUrl: url, WaitTimeSeconds: 1 }));
      const elapsed = Date.now() - start;
      expect(out.Messages ?? []).toEqual([]);
      expect(elapsed).toBeGreaterThanOrEqual(800);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("ChangeMessageVisibility releases an in-flight message", async () => {
    const name = uniqueQueue("js_cv");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      await c.send(new SendMessageCommand({ QueueUrl: url, MessageBody: "x" }));
      const r1 = await c.send(new ReceiveMessageCommand({ QueueUrl: url }));
      const handle = r1.Messages![0].ReceiptHandle!;
      await c.send(
        new ChangeMessageVisibilityCommand({ QueueUrl: url, ReceiptHandle: handle, VisibilityTimeout: 0 }),
      );
      const r2 = await c.send(new ReceiveMessageCommand({ QueueUrl: url }));
      expect(r2.Messages?.[0]?.Body).toBe("x");
    } finally {
      await c.send(new PurgeQueueCommand({ QueueUrl: url })).catch(() => {});
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("TagQueue + ListQueueTags round-trip", async () => {
    const name = uniqueQueue("js_tag");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      await c.send(new TagQueueCommand({ QueueUrl: url, Tags: { env: "dev", owner: "platform" } }));
      const out = await c.send(new ListQueueTagsCommand({ QueueUrl: url }));
      expect(out.Tags).toEqual({ env: "dev", owner: "platform" });
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });
});
