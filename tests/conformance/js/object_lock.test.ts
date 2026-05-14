// JS S3 Object Lock conformance — smoke level (WORM enforcement).

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutObjectCommand,
  DeleteObjectCommand,
  PutObjectLockConfigurationCommand,
  GetObjectLockConfigurationCommand,
  GetObjectRetentionCommand,
  ListObjectVersionsCommand,
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

async function drainLocked(c: S3Client, bucket: string) {
  const list = await c.send(new ListObjectVersionsCommand({ Bucket: bucket }));
  for (const v of list.Versions ?? []) {
    await c.send(new DeleteObjectCommand({
      Bucket: bucket, Key: v.Key, VersionId: v.VersionId,
      BypassGovernanceRetention: true,
    }));
  }
  for (const m of list.DeleteMarkers ?? []) {
    await c.send(new DeleteObjectCommand({ Bucket: bucket, Key: m.Key, VersionId: m.VersionId }));
  }
  try { await c.send(new DeleteBucketCommand({ Bucket: bucket })); } catch {}
}

describe("S3 Object Lock", () => {
  it("CreateBucket with Object Lock + GetObjectLockConfiguration round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-ol-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket, ObjectLockEnabledForBucket: true }));
    try {
      await c.send(new PutObjectLockConfigurationCommand({
        Bucket: bucket,
        ObjectLockConfiguration: {
          ObjectLockEnabled: "Enabled",
          Rule: { DefaultRetention: { Mode: "GOVERNANCE", Days: 1 } },
        },
      }));
      const out = await c.send(new GetObjectLockConfigurationCommand({ Bucket: bucket }));
      expect(out.ObjectLockConfiguration?.Rule?.DefaultRetention?.Mode).toBe("GOVERNANCE");
      expect(out.ObjectLockConfiguration?.Rule?.DefaultRetention?.Days).toBe(1);
    } finally {
      await drainLocked(c, bucket);
    }
  });

  it("Object retention round-trip (per-version)", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-ol-ret");
    await c.send(new CreateBucketCommand({ Bucket: bucket, ObjectLockEnabledForBucket: true }));
    try {
      const until = new Date(Date.now() + 24 * 3600 * 1000);
      const put = await c.send(new PutObjectCommand({
        Bucket: bucket, Key: "k", Body: "x",
        ObjectLockMode: "GOVERNANCE",
        ObjectLockRetainUntilDate: until,
      }));
      const out = await c.send(new GetObjectRetentionCommand({
        Bucket: bucket, Key: "k", VersionId: put.VersionId,
      }));
      expect(out.Retention?.Mode).toBe("GOVERNANCE");
    } finally {
      await drainLocked(c, bucket);
    }
  });

  it("DeleteObject within retention → AccessDenied", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-ol-deny");
    await c.send(new CreateBucketCommand({ Bucket: bucket, ObjectLockEnabledForBucket: true }));
    try {
      const until = new Date(Date.now() + 24 * 3600 * 1000);
      const put = await c.send(new PutObjectCommand({
        Bucket: bucket, Key: "k", Body: "x",
        ObjectLockMode: "GOVERNANCE",
        ObjectLockRetainUntilDate: until,
      }));
      await expect(
        c.send(new DeleteObjectCommand({ Bucket: bucket, Key: "k", VersionId: put.VersionId })),
      ).rejects.toMatchObject({ name: "AccessDenied" });
    } finally {
      await drainLocked(c, bucket);
    }
  });
});
