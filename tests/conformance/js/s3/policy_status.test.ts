// JS S3 GetBucketPolicyStatus conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  GetBucketPolicyStatusCommand,
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

describe("S3 GetBucketPolicyStatus", () => {
  it("untouched bucket → NoSuchBucketPolicy", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-ps-no");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await expect(
        c.send(new GetBucketPolicyStatusCommand({ Bucket: bucket })),
      ).rejects.toMatchObject({ name: "NoSuchBucketPolicy" });
    } finally {
      try { await c.send(new DeleteBucketCommand({ Bucket: bucket })); } catch {}
    }
  });
});
