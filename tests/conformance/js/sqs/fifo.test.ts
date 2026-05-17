// SQS FIFO conformance — JS suite (v0.3.1).
// Covers: queue creation with FifoQueue attribute, MessageGroupId
// validation, dedup window, and per-group ordering.

import { describe, it, expect } from "vitest";
import {
  SQSClient,
  CreateQueueCommand,
  DeleteQueueCommand,
  SendMessageCommand,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from "@aws-sdk/client-sqs";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newSqs(): SQSClient {
  return new SQSClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniqueFifoQueue(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}.fifo`;
}

describe("sqs FIFO (js)", () => {
  const c = newSqs();

  it("creates a FIFO queue with ContentBasedDeduplication", async () => {
    const name = uniqueFifoQueue("fifo_create");
    const out = await c.send(
      new CreateQueueCommand({
        QueueName: name,
        Attributes: { FifoQueue: "true", ContentBasedDeduplication: "true" },
      }),
    );
    try {
      expect(out.QueueUrl).toContain(name);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: out.QueueUrl! }));
    }
  });

  it("send returns SequenceNumber and dedupes identical bodies under CBD", async () => {
    const name = uniqueFifoQueue("fifo_dedup");
    const { QueueUrl } = await c.send(
      new CreateQueueCommand({
        QueueName: name,
        Attributes: { FifoQueue: "true", ContentBasedDeduplication: "true" },
      }),
    );
    try {
      const a = await c.send(
        new SendMessageCommand({
          QueueUrl,
          MessageBody: "payload",
          MessageGroupId: "g1",
        }),
      );
      expect(a.SequenceNumber).toBeDefined();
      const b = await c.send(
        new SendMessageCommand({
          QueueUrl,
          MessageBody: "payload",
          MessageGroupId: "g1",
        }),
      );
      // Dupe collapses to the original send.
      expect(b.MessageId).toEqual(a.MessageId);
      expect(b.SequenceNumber).toEqual(a.SequenceNumber);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl }));
    }
  });

  it("head-of-line blocking within a group", async () => {
    const name = uniqueFifoQueue("fifo_hol");
    const { QueueUrl } = await c.send(
      new CreateQueueCommand({
        QueueName: name,
        Attributes: { FifoQueue: "true", ContentBasedDeduplication: "true" },
      }),
    );
    try {
      for (const body of ["a", "b", "c"]) {
        await c.send(
          new SendMessageCommand({
            QueueUrl,
            MessageBody: body,
            MessageGroupId: "g1",
          }),
        );
      }
      const r1 = await c.send(
        new ReceiveMessageCommand({ QueueUrl, MaxNumberOfMessages: 10 }),
      );
      expect(r1.Messages?.length).toBe(1);
      expect(r1.Messages![0].Body).toBe("a");

      await c.send(
        new DeleteMessageCommand({
          QueueUrl,
          ReceiptHandle: r1.Messages![0].ReceiptHandle!,
        }),
      );
      const r2 = await c.send(
        new ReceiveMessageCommand({ QueueUrl, MaxNumberOfMessages: 10 }),
      );
      expect(r2.Messages![0].Body).toBe("b");
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl }));
    }
  });

  it("rejects FIFO send without MessageGroupId", async () => {
    const name = uniqueFifoQueue("fifo_no_gid");
    const { QueueUrl } = await c.send(
      new CreateQueueCommand({
        QueueName: name,
        Attributes: { FifoQueue: "true", ContentBasedDeduplication: "true" },
      }),
    );
    try {
      let caught: any = null;
      try {
        await c.send(new SendMessageCommand({ QueueUrl, MessageBody: "hi" }));
      } catch (e: any) {
        caught = e;
      }
      expect(caught).not.toBeNull();
      expect(caught.name).toBe("MissingParameter");
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl }));
    }
  });
});
