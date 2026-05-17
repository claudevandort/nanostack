// JS S3 ownership controls conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketOwnershipControlsCommand,
  GetBucketOwnershipControlsCommand,
  DeleteBucketOwnershipControlsCommand,
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

describe("S3 OwnershipControls", () => {
  it("Put/Get round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-own-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketOwnershipControlsCommand({
        Bucket: bucket,
        OwnershipControls: { Rules: [{ ObjectOwnership: "BucketOwnerEnforced" }] },
      }));
      const out = await c.send(new GetBucketOwnershipControlsCommand({ Bucket: bucket }));
      expect(out.OwnershipControls?.Rules?.[0]?.ObjectOwnership).toBe("BucketOwnerEnforced");
      await c.send(new DeleteBucketOwnershipControlsCommand({ Bucket: bucket }));
    } finally {
      try {
        await c.send(new DeleteBucketCommand({ Bucket: bucket }));
      } catch {}
    }
  });
});
