// JS S3 bucket replication conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketVersioningCommand,
  PutBucketReplicationCommand,
  GetBucketReplicationCommand,
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

describe("S3 BucketReplication", () => {
  it("Put/Get round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-repl-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketVersioningCommand({
        Bucket: bucket,
        VersioningConfiguration: { Status: "Enabled" },
      }));
      await c.send(new PutBucketReplicationCommand({
        Bucket: bucket,
        ReplicationConfiguration: {
          Role: "arn:aws:iam::1:role/repl",
          Rules: [{
            ID: "r1",
            Status: "Enabled",
            Prefix: "logs/",
            Destination: { Bucket: "arn:aws:s3:::dest" },
          }],
        },
      }));
      const out = await c.send(new GetBucketReplicationCommand({ Bucket: bucket }));
      expect(out.ReplicationConfiguration?.Role).toBe("arn:aws:iam::1:role/repl");
      expect(out.ReplicationConfiguration?.Rules?.[0]?.ID).toBe("r1");
    } finally {
      try { await c.send(new DeleteBucketCommand({ Bucket: bucket })); } catch {}
    }
  });
});
