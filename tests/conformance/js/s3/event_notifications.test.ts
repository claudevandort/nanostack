// S3 → SQS event-notification conformance — JS suite (v0.3.4).

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutObjectCommand,
  DeleteObjectCommand,
  PutBucketNotificationConfigurationCommand,
} from "@aws-sdk/client-s3";
import {
  SQSClient,
  CreateQueueCommand,
  DeleteQueueCommand,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from "@aws-sdk/client-sqs";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newS3(): S3Client {
  return new S3Client({
    endpoint,
    region: "us-east-1",
    forcePathStyle: true,
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function newSqs(): SQSClient {
  return new SQSClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniq(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}

async function drainQueue(sqs: SQSClient, queueUrl: string, maxWaitS = 5): Promise<any[]> {
  const deadline = Date.now() + maxWaitS * 1000;
  const records: any[] = [];
  while (Date.now() < deadline) {
    const resp = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: queueUrl,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 1,
    }));
    const msgs = resp.Messages ?? [];
    if (msgs.length === 0) {
      if (records.length > 0) return records;
      continue;
    }
    for (const m of msgs) {
      const parsed = JSON.parse(m.Body!);
      for (const rec of parsed.Records ?? []) records.push(rec);
      await sqs.send(new DeleteMessageCommand({
        QueueUrl: queueUrl, ReceiptHandle: m.ReceiptHandle!,
      }));
    }
  }
  return records;
}

describe("s3 → sqs event notifications (js)", () => {
  const s3 = newS3();
  const sqs = newSqs();

  it("PutObject fires s3:ObjectCreated:Put", async () => {
    const bucket = uniq("s3jsev");
    const queueName = uniq("q");
    await s3.send(new CreateBucketCommand({ Bucket: bucket }));
    const queueUrl = (await sqs.send(new CreateQueueCommand({ QueueName: queueName }))).QueueUrl!;
    try {
      await s3.send(new PutBucketNotificationConfigurationCommand({
        Bucket: bucket,
        NotificationConfiguration: {
          QueueConfigurations: [{
            QueueArn: `arn:aws:sqs:us-east-1:000000000000:${queueName}`,
            Events: ["s3:ObjectCreated:Put"],
          }],
        },
      }));
      await s3.send(new PutObjectCommand({ Bucket: bucket, Key: "hello.txt", Body: "world" }));
      const records = await drainQueue(sqs, queueUrl);
      expect(records.length).toBe(1);
      expect(records[0].eventName).toBe("s3:ObjectCreated:Put");
      expect(records[0].s3.object.key).toBe("hello.txt");
    } finally {
      await sqs.send(new DeleteQueueCommand({ QueueUrl: queueUrl }));
      try {
        await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: "hello.txt" }));
      } catch (_) {}
      await s3.send(new DeleteBucketCommand({ Bucket: bucket }));
    }
  });

  it("prefix filter limits dispatch", async () => {
    const bucket = uniq("s3jsfilt");
    const queueName = uniq("q");
    await s3.send(new CreateBucketCommand({ Bucket: bucket }));
    const queueUrl = (await sqs.send(new CreateQueueCommand({ QueueName: queueName }))).QueueUrl!;
    try {
      await s3.send(new PutBucketNotificationConfigurationCommand({
        Bucket: bucket,
        NotificationConfiguration: {
          QueueConfigurations: [{
            QueueArn: `arn:aws:sqs:us-east-1:000000000000:${queueName}`,
            Events: ["s3:ObjectCreated:Put"],
            Filter: { Key: { FilterRules: [{ Name: "prefix", Value: "images/" }] } },
          }],
        },
      }));
      await s3.send(new PutObjectCommand({ Bucket: bucket, Key: "images/a.jpg", Body: "x" }));
      await s3.send(new PutObjectCommand({ Bucket: bucket, Key: "docs/readme.md", Body: "y" }));
      const records = await drainQueue(sqs, queueUrl);
      expect(records.length).toBe(1);
      expect(records[0].s3.object.key).toBe("images/a.jpg");
    } finally {
      await sqs.send(new DeleteQueueCommand({ QueueUrl: queueUrl }));
      for (const k of ["images/a.jpg", "docs/readme.md"]) {
        try {
          await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: k }));
        } catch (_) {}
      }
      await s3.send(new DeleteBucketCommand({ Bucket: bucket }));
    }
  });

  it("DeleteObject fires s3:ObjectRemoved:Delete", async () => {
    const bucket = uniq("s3jsdel");
    const queueName = uniq("q");
    await s3.send(new CreateBucketCommand({ Bucket: bucket }));
    const queueUrl = (await sqs.send(new CreateQueueCommand({ QueueName: queueName }))).QueueUrl!;
    try {
      await s3.send(new PutBucketNotificationConfigurationCommand({
        Bucket: bucket,
        NotificationConfiguration: {
          QueueConfigurations: [{
            QueueArn: `arn:aws:sqs:us-east-1:000000000000:${queueName}`,
            Events: ["s3:ObjectRemoved:Delete"],
          }],
        },
      }));
      await s3.send(new PutObjectCommand({ Bucket: bucket, Key: "x", Body: "y" }));
      await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: "x" }));
      const records = await drainQueue(sqs, queueUrl);
      expect(records.length).toBe(1);
      expect(records[0].eventName).toBe("s3:ObjectRemoved:Delete");
    } finally {
      await sqs.send(new DeleteQueueCommand({ QueueUrl: queueUrl }));
      await s3.send(new DeleteBucketCommand({ Bucket: bucket }));
    }
  });
});
