// JS S3 ACL conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketAclCommand,
  GetBucketAclCommand,
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

describe("S3 ACL", () => {
  it("PutBucketAcl canned public-read + GetBucketAcl round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-acl-canned");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketAclCommand({ Bucket: bucket, ACL: "public-read" }));
      const out = await c.send(new GetBucketAclCommand({ Bucket: bucket }));
      const hasGroup = (out.Grants ?? []).some(
        (g) => g.Grantee?.Type === "Group" && g.Permission === "READ",
      );
      expect(hasGroup).toBe(true);
    } finally {
      try {
        await c.send(new DeleteBucketCommand({ Bucket: bucket }));
      } catch {}
    }
  });
});
