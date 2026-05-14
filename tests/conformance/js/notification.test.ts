// JS S3 notification conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketNotificationConfigurationCommand,
  GetBucketNotificationConfigurationCommand,
} from "@aws-sdk/client-s3";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newClient(): S3Client {
  return new S3Client({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
    forcePathStyle: true,
  });
}

function uniqueBucket(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}

describe("S3 BucketNotification", () => {
  it("Topic config round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-notif-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketNotificationConfigurationCommand({
        Bucket: bucket,
        NotificationConfiguration: {
          TopicConfigurations: [{
            TopicArn: "arn:aws:sns:us-east-1:1:t",
            Events: ["s3:ObjectCreated:Put"],
          }],
        },
      }));
      const out = await c.send(new GetBucketNotificationConfigurationCommand({ Bucket: bucket }));
      expect(out.TopicConfigurations?.[0]?.TopicArn).toBe("arn:aws:sns:us-east-1:1:t");
    } finally {
      try { await c.send(new DeleteBucketCommand({ Bucket: bucket })); } catch {}
    }
  });
});
