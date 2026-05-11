// JS SigV4 conformance — mirrors the Go suite at smoke level. The
// "custom-header presigned URL" pair is the headline LocalStack regression:
// when the request omits a header listed in X-Amz-SignedHeaders, the
// server must respond with a clean AWS error, never a 5xx.

import { describe, it, expect, beforeEach } from "vitest";
import {
  S3Client,
  CreateBucketCommand,
  DeleteBucketCommand,
  HeadBucketCommand,
} from "@aws-sdk/client-s3";
import { SignatureV4 } from "@smithy/signature-v4";
import { Sha256 } from "@aws-crypto/sha256-js";
import { HttpRequest } from "@smithy/protocol-http";
import { formatUrl } from "@aws-sdk/util-format-url";

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

function endpointHost(): string {
  return new URL(endpoint).host;
}

async function safeDelete(c: S3Client, bucket: string) {
  try {
    await c.send(new DeleteBucketCommand({ Bucket: bucket }));
  } catch {
    /* best-effort */
  }
}

it("anonymous request → 403 AccessDenied", async () => {
  const resp = await fetch(endpoint + "/", { method: "GET" });
  expect(resp.status).toBe(403);
  const body = await resp.text();
  expect(body).toContain("<Code>AccessDenied</Code>");
});

it("SDK-signed bucket op succeeds (sanity)", async () => {
  // If this passes we know basic SigV4 header auth works under the JS SDK.
  // The bucket-level M1 tests in basic.test.ts already prove this, but this
  // assertion belongs in the SigV4 suite too.
  const c = newClient();
  const bucket = uniqueBucket("js-sigv4-sanity");
  try {
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
    const out = await c.send(new HeadBucketCommand({ Bucket: bucket }));
    expect(out.$metadata.httpStatusCode).toBe(200);
  } finally {
    await safeDelete(c, bucket);
  }
});

describe("presigned URLs", () => {
  let bucket: string;

  beforeEach(async () => {
    bucket = uniqueBucket("js-presign");
    const c = newClient();
    await c.send(new CreateBucketCommand({ Bucket: bucket }));
  });

  async function signWithExtraHeader(
    extra: Record<string, string>,
    expires: number = 3600,
  ): Promise<string> {
    const signer = new SignatureV4({
      credentials: { accessKeyId: "test", secretAccessKey: "test" },
      region: "us-east-1",
      service: "s3",
      sha256: Sha256,
    });
    const url = new URL(`${endpoint}/${bucket}`);
    const request = new HttpRequest({
      method: "HEAD",
      protocol: url.protocol,
      hostname: url.hostname,
      port: Number(url.port) || undefined,
      path: url.pathname,
      query: {},
      headers: { host: endpointHost(), ...extra },
    });
    const signed = await signer.presign(request, {
      expiresIn: expires,
      // smithy excludes headers by default; force the custom ones to be signed.
      signableHeaders: new Set(Object.keys(extra)),
      unsignableHeaders: new Set(),
    });
    return formatUrl(signed);
  }

  it("happy path — request with the signed custom header succeeds", async () => {
    const signedUrl = await signWithExtraHeader({ "x-nano-custom": "v1" });
    const resp = await fetch(signedUrl, {
      method: "HEAD",
      headers: { "x-nano-custom": "v1" },
    });
    expect(resp.status).toBe(200);
  });

  it("missing signed header → clean 403, no panic (LocalStack regression)", async () => {
    const signedUrl = await signWithExtraHeader({ "x-nano-custom": "v1" });
    const resp = await fetch(signedUrl, { method: "GET" });
    expect(resp.status).toBe(403);
    const body = await resp.text();
    expect(body).toContain("<Code>SignatureDoesNotMatch</Code>");
  });

  it("expired presigned URL → 403", async () => {
    const signer = new SignatureV4({
      credentials: { accessKeyId: "test", secretAccessKey: "test" },
      region: "us-east-1",
      service: "s3",
      sha256: Sha256,
    });
    const url = new URL(`${endpoint}/${bucket}`);
    const request = new HttpRequest({
      method: "HEAD",
      protocol: url.protocol,
      hostname: url.hostname,
      port: Number(url.port) || undefined,
      path: url.pathname,
      query: {},
      headers: { host: endpointHost() },
    });
    const signed = await signer.presign(request, {
      expiresIn: 1,
      signingDate: new Date(Date.now() - 5_000),
    });
    const resp = await fetch(formatUrl(signed), { method: "HEAD" });
    expect(resp.status).toBe(403);
  });
});
