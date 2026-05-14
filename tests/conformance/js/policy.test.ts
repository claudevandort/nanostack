// JS S3 bucket policy conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketPolicyCommand,
  GetBucketPolicyCommand,
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

const samplePolicy = `{"Version":"2012-10-17","Statement":[]}`;

describe("S3 bucket policy", () => {
  it("PutBucketPolicy + GetBucketPolicy round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-pol-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketPolicyCommand({ Bucket: bucket, Policy: samplePolicy }));
      const out = await c.send(new GetBucketPolicyCommand({ Bucket: bucket }));
      expect(out.Policy).toBe(samplePolicy);
    } finally {
      try {
        await c.send(new DeleteBucketCommand({ Bucket: bucket }));
      } catch {}
    }
  });

  it("GetBucketPolicy on untouched bucket → NoSuchBucketPolicy", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-pol-no");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await expect(
        c.send(new GetBucketPolicyCommand({ Bucket: bucket })),
      ).rejects.toMatchObject({ name: "NoSuchBucketPolicy" });
    } finally {
      try {
        await c.send(new DeleteBucketCommand({ Bucket: bucket }));
      } catch {}
    }
  });
});
