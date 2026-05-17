// JS S3 versioning conformance — smoke level.

import { describe, it, expect } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  PutBucketVersioningCommand,
  GetBucketVersioningCommand,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
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

async function drainAndCleanup(c: S3Client, bucket: string) {
  try {
    const list = await c.send(new ListObjectVersionsCommand({ Bucket: bucket }));
    for (const v of list.Versions ?? []) {
      await c.send(new DeleteObjectCommand({ Bucket: bucket, Key: v.Key, VersionId: v.VersionId }));
    }
    for (const m of list.DeleteMarkers ?? []) {
      await c.send(new DeleteObjectCommand({ Bucket: bucket, Key: m.Key, VersionId: m.VersionId }));
    }
  } catch {}
  try {
    await c.send(new DeleteBucketCommand({ Bucket: bucket }));
  } catch {}
}

describe("S3 versioning", () => {
  it("PutBucketVersioning + GetBucketVersioning round-trip", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-ver-rt");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketVersioningCommand({
        Bucket: bucket,
        VersioningConfiguration: { Status: "Enabled" },
      }));
      const out = await c.send(new GetBucketVersioningCommand({ Bucket: bucket }));
      expect(out.Status).toBe("Enabled");
    } finally {
      await drainAndCleanup(c, bucket);
    }
  });

  it("Three puts produce three listable versions with IsLatest correct", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-ver-list");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketVersioningCommand({
        Bucket: bucket,
        VersioningConfiguration: { Status: "Enabled" },
      }));
      for (const v of ["v1", "v2", "v3"]) {
        const out = await c.send(new PutObjectCommand({ Bucket: bucket, Key: "k", Body: Buffer.from(v) }));
        expect(out.VersionId).toBeTruthy();
      }
      const list = await c.send(new ListObjectVersionsCommand({ Bucket: bucket }));
      expect(list.Versions?.length).toBe(3);
      expect(list.Versions![0].IsLatest).toBe(true);
      expect(list.Versions![1].IsLatest).toBe(false);
    } finally {
      await drainAndCleanup(c, bucket);
    }
  });

  it("DeleteObject creates a delete marker; GetObject 404s", async () => {
    const c = newClient();
    const bucket = uniqueBucket("js-ver-dm");
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    try {
      await c.send(new PutBucketVersioningCommand({
        Bucket: bucket,
        VersioningConfiguration: { Status: "Enabled" },
      }));
      await c.send(new PutObjectCommand({ Bucket: bucket, Key: "k", Body: Buffer.from("alive") }));
      const del = await c.send(new DeleteObjectCommand({ Bucket: bucket, Key: "k" }));
      expect(del.DeleteMarker).toBe(true);
      expect(del.VersionId).toBeTruthy();
      await expect(
        c.send(new GetObjectCommand({ Bucket: bucket, Key: "k" })),
      ).rejects.toMatchObject({ $metadata: { httpStatusCode: 404 } });
    } finally {
      await drainAndCleanup(c, bucket);
    }
  });
});
