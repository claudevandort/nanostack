// JS S3 website conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketWebsiteCommand,
  GetBucketWebsiteCommand,
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

describe("S3 BucketWebsite", () => {
  it("Index + Error round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-web-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketWebsiteCommand({
        Bucket: bucket,
        WebsiteConfiguration: {
          IndexDocument: { Suffix: "index.html" },
          ErrorDocument: { Key: "404.html" },
        },
      }));
      const out = await c.send(new GetBucketWebsiteCommand({ Bucket: bucket }));
      expect(out.IndexDocument?.Suffix).toBe("index.html");
      expect(out.ErrorDocument?.Key).toBe("404.html");
    } finally {
      try { await c.send(new DeleteBucketCommand({ Bucket: bucket })); } catch {}
    }
  });
});
