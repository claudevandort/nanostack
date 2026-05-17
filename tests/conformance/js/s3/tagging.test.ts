// JS S3 tagging conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketTaggingCommand,
  GetBucketTaggingCommand,
  PutObjectCommand,
  GetObjectTaggingCommand,
  DeleteObjectCommand,
  CopyObjectCommand,
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

async function cleanup(c: S3Client, bucket: string, keys: string[] = []) {
  for (const k of keys) {
    try {
      await c.send(new DeleteObjectCommand({ Bucket: bucket, Key: k }));
    } catch {}
  }
  try {
    await c.send(new DeleteBucketCommand({ Bucket: bucket }));
  } catch {}
}

describe("S3 tagging", () => {
  it("PutBucketTagging + GetBucketTagging round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-tag-buk");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketTaggingCommand({
        Bucket: bucket,
        Tagging: { TagSet: [
          { Key: "env", Value: "prod" },
          { Key: "team", Value: "alpha" },
        ] },
      }));
      const out = await c.send(new GetBucketTaggingCommand({ Bucket: bucket }));
      const map: Record<string, string> = {};
      for (const t of out.TagSet ?? []) map[t.Key!] = t.Value!;
      expect(map["env"]).toBe("prod");
      expect(map["team"]).toBe("alpha");
    } finally {
      await cleanup(c, bucket);
    }
  });

  it("PutObject with x-amz-tagging inline header + GetObjectTagging", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-tag-inline");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutObjectCommand({
        Bucket: bucket, Key: "k", Body: "hi",
        Tagging: "team=alpha&env=prod",
      }));
      const out = await c.send(new GetObjectTaggingCommand({ Bucket: bucket, Key: "k" }));
      const map: Record<string, string> = {};
      for (const t of out.TagSet ?? []) map[t.Key!] = t.Value!;
      expect(map["team"]).toBe("alpha");
      expect(map["env"]).toBe("prod");
    } finally {
      await cleanup(c, bucket, ["k"]);
    }
  });

  it("CopyObject REPLACE directive overrides source tags", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-tag-cp-r");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutObjectCommand({
        Bucket: bucket, Key: "src", Body: "x",
        Tagging: "env=prod",
      }));
      await c.send(new CopyObjectCommand({
        Bucket: bucket, Key: "dst",
        CopySource: `${bucket}/src`,
        TaggingDirective: "REPLACE",
        Tagging: "phase=replace",
      }));
      const out = await c.send(new GetObjectTaggingCommand({ Bucket: bucket, Key: "dst" }));
      const map: Record<string, string> = {};
      for (const t of out.TagSet ?? []) map[t.Key!] = t.Value!;
      expect(map["env"]).toBeUndefined();
      expect(map["phase"]).toBe("replace");
    } finally {
      await cleanup(c, bucket, ["src", "dst"]);
    }
  });
});
