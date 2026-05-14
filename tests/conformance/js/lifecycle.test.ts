// JS S3 lifecycle conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketLifecycleConfigurationCommand,
  GetBucketLifecycleConfigurationCommand,
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

describe("S3 BucketLifecycle", () => {
  it("Put/Get round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-lc-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketLifecycleConfigurationCommand({
        Bucket: bucket,
        LifecycleConfiguration: {
          Rules: [{
            ID: "r1",
            Status: "Enabled",
            Filter: { Prefix: "tmp/" },
            Expiration: { Days: 7 },
          }],
        },
      }));
      const out = await c.send(new GetBucketLifecycleConfigurationCommand({ Bucket: bucket }));
      expect(out.Rules?.[0]?.ID).toBe("r1");
      expect(out.Rules?.[0]?.Expiration?.Days).toBe(7);
    } finally {
      try { await c.send(new DeleteBucketCommand({ Bucket: bucket })); } catch {}
    }
  });
});
