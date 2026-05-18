// SQS robustness conformance — JS suite (v0.3.2).
// Covers cold-start rehydration, ListDeadLetterSourceQueues,
// AddPermission / RemovePermission, and StartMessageMoveTask.

import { describe, it, expect } from "vitest";
import {
  SQSClient,
  CreateQueueCommand,
  DeleteQueueCommand,
  SendMessageCommand,
  ReceiveMessageCommand,
  SetQueueAttributesCommand,
  GetQueueAttributesCommand,
  ListDeadLetterSourceQueuesCommand,
  AddPermissionCommand,
  RemovePermissionCommand,
  StartMessageMoveTaskCommand,
  ListMessageMoveTasksCommand,
} from "@aws-sdk/client-sqs";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newSqs(): SQSClient {
  return new SQSClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniq(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

describe("sqs robustness (js)", () => {
  const c = newSqs();

  it("ListDeadLetterSourceQueues returns matching sources", async () => {
    const dlqName = uniq("dlq_js");
    const dlqUrl = (await c.send(new CreateQueueCommand({ QueueName: dlqName }))).QueueUrl!;
    const srcUrl = (await c.send(new CreateQueueCommand({ QueueName: uniq("src_js") }))).QueueUrl!;
    try {
      const dlqArn = `arn:aws:sqs:us-east-1:000000000000:${dlqName}`;
      await c.send(new SetQueueAttributesCommand({
        QueueUrl: srcUrl,
        Attributes: {
          RedrivePolicy: JSON.stringify({ deadLetterTargetArn: dlqArn, maxReceiveCount: 3 }),
        },
      }));
      const out = await c.send(new ListDeadLetterSourceQueuesCommand({ QueueUrl: dlqUrl }));
      expect(out.queueUrls).toEqual([srcUrl]);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: srcUrl }));
      await c.send(new DeleteQueueCommand({ QueueUrl: dlqUrl }));
    }
  });

  it("AddPermission round-trips into Policy attribute", async () => {
    const url = (await c.send(new CreateQueueCommand({ QueueName: uniq("q_js") }))).QueueUrl!;
    try {
      await c.send(new AddPermissionCommand({
        QueueUrl: url,
        Label: "grant1",
        AWSAccountIds: ["111122223333"],
        Actions: ["SendMessage"],
      }));
      const attrs = await c.send(new GetQueueAttributesCommand({
        QueueUrl: url,
        AttributeNames: ["Policy"],
      }));
      expect(attrs.Attributes!.Policy).toContain("grant1");
      expect(attrs.Attributes!.Policy).toContain("sqs:SendMessage");
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("RemovePermission drops the matching statement", async () => {
    const url = (await c.send(new CreateQueueCommand({ QueueName: uniq("q_js2") }))).QueueUrl!;
    try {
      await c.send(new AddPermissionCommand({
        QueueUrl: url, Label: "g1",
        AWSAccountIds: ["111122223333"], Actions: ["SendMessage"],
      }));
      await c.send(new AddPermissionCommand({
        QueueUrl: url, Label: "g2",
        AWSAccountIds: ["444455556666"], Actions: ["ReceiveMessage"],
      }));
      await c.send(new RemovePermissionCommand({ QueueUrl: url, Label: "g1" }));
      const policy = (await c.send(new GetQueueAttributesCommand({
        QueueUrl: url, AttributeNames: ["Policy"],
      }))).Attributes!.Policy!;
      expect(policy).not.toContain("g1");
      expect(policy).toContain("g2");
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("StartMessageMoveTask drains DLQ into source", async () => {
    const dlqName = uniq("dlq_mv");
    const dlqUrl = (await c.send(new CreateQueueCommand({ QueueName: dlqName }))).QueueUrl!;
    const srcUrl = (await c.send(new CreateQueueCommand({ QueueName: uniq("src_mv") }))).QueueUrl!;
    try {
      const dlqArn = `arn:aws:sqs:us-east-1:000000000000:${dlqName}`;
      await c.send(new SetQueueAttributesCommand({
        QueueUrl: srcUrl,
        Attributes: {
          RedrivePolicy: JSON.stringify({ deadLetterTargetArn: dlqArn, maxReceiveCount: 1 }),
        },
      }));
      for (let i = 0; i < 2; i++) {
        await c.send(new SendMessageCommand({ QueueUrl: srcUrl, MessageBody: `m${i}` }));
      }
      // Over-receive to push to DLQ.
      for (let i = 0; i < 3; i++) {
        await c.send(new ReceiveMessageCommand({ QueueUrl: srcUrl, VisibilityTimeout: 0 }));
      }
      // Start move task.
      const start = await c.send(new StartMessageMoveTaskCommand({ SourceArn: dlqArn }));
      expect(start.TaskHandle).toBeDefined();
      // Source has the messages again.
      const recv = await c.send(new ReceiveMessageCommand({ QueueUrl: srcUrl, MaxNumberOfMessages: 10 }));
      expect(recv.Messages?.length).toBe(2);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: srcUrl }));
      await c.send(new DeleteQueueCommand({ QueueUrl: dlqUrl }));
    }
  });

  it("ListMessageMoveTasks shows the COMPLETED task", async () => {
    const dlqName = uniq("dlq_ls");
    const dlqUrl = (await c.send(new CreateQueueCommand({ QueueName: dlqName }))).QueueUrl!;
    const srcUrl = (await c.send(new CreateQueueCommand({ QueueName: uniq("src_ls") }))).QueueUrl!;
    try {
      const dlqArn = `arn:aws:sqs:us-east-1:000000000000:${dlqName}`;
      await c.send(new SetQueueAttributesCommand({
        QueueUrl: srcUrl,
        Attributes: {
          RedrivePolicy: JSON.stringify({ deadLetterTargetArn: dlqArn, maxReceiveCount: 1 }),
        },
      }));
      await c.send(new SendMessageCommand({ QueueUrl: srcUrl, MessageBody: "x" }));
      await c.send(new ReceiveMessageCommand({ QueueUrl: srcUrl, VisibilityTimeout: 0 }));
      await c.send(new ReceiveMessageCommand({ QueueUrl: srcUrl, VisibilityTimeout: 0 }));
      await c.send(new StartMessageMoveTaskCommand({ SourceArn: dlqArn }));
      const out = await c.send(new ListMessageMoveTasksCommand({ SourceArn: dlqArn, MaxResults: 10 }));
      expect(out.Results?.length).toBe(1);
      expect(out.Results![0].Status).toBe("COMPLETED");
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: srcUrl }));
      await c.send(new DeleteQueueCommand({ QueueUrl: dlqUrl }));
    }
  });
});
