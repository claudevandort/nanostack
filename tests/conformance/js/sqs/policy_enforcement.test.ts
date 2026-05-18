// SQS Queue Policy enforcement — JS suite (v0.3.3).
// Covers anonymous (via raw fetch) + owner-bypass (via @aws-sdk/client-sqs).

import { describe, it, expect } from "vitest";
import {
  SQSClient,
  CreateQueueCommand,
  DeleteQueueCommand,
  SendMessageCommand,
  SetQueueAttributesCommand,
} from "@aws-sdk/client-sqs";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newSqs(): SQSClient {
  return new SQSClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniq(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

async function anonCall(target: string, payload: object): Promise<Response> {
  return fetch(endpoint, {
    method: "POST",
    headers: {
      "X-Amz-Target": `AmazonSQS.${target}`,
      "Content-Type": "application/x-amz-json-1.0",
    },
    body: JSON.stringify(payload),
  });
}

function publicSendPolicy(queueName: string): string {
  return JSON.stringify({
    Version: "2012-10-17",
    Statement: [{
      Sid: "PublicSend",
      Effect: "Allow",
      Principal: "*",
      Action: "sqs:SendMessage",
      Resource: `arn:aws:sqs:us-east-1:000000000000:${queueName}`,
    }],
  });
}

function denyAllPolicy(queueName: string): string {
  return JSON.stringify({
    Version: "2012-10-17",
    Statement: [{
      Sid: "DenyAll",
      Effect: "Deny",
      Principal: "*",
      Action: "*",
      Resource: `arn:aws:sqs:us-east-1:000000000000:${queueName}`,
    }],
  });
}

describe("sqs policy enforcement (js)", () => {
  const c = newSqs();

  it("anonymous SendMessage allowed under Principal:* policy", async () => {
    const name = uniq("q_jspol");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      await c.send(new SetQueueAttributesCommand({
        QueueUrl: url,
        Attributes: { Policy: publicSendPolicy(name) },
      }));
      const resp = await anonCall("SendMessage", { QueueUrl: url, MessageBody: "hi-anon" });
      expect(resp.status).toBe(200);
      const body = await resp.json();
      expect(body.MessageId).toBeDefined();
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("anonymous ReceiveMessage rejected when policy only allows SendMessage", async () => {
    const name = uniq("q_jsdeny");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      await c.send(new SetQueueAttributesCommand({
        QueueUrl: url,
        Attributes: { Policy: publicSendPolicy(name) },
      }));
      const resp = await anonCall("ReceiveMessage", { QueueUrl: url });
      expect(resp.status).toBe(403);
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });

  it("owner-signed request bypasses Deny * policy", async () => {
    const name = uniq("q_jsownerbypass");
    const url = (await c.send(new CreateQueueCommand({ QueueName: name }))).QueueUrl!;
    try {
      await c.send(new SetQueueAttributesCommand({
        QueueUrl: url,
        Attributes: { Policy: denyAllPolicy(name) },
      }));
      // Owner-signed request still works.
      const out = await c.send(new SendMessageCommand({
        QueueUrl: url,
        MessageBody: "owner-bypass",
      }));
      expect(out.MessageId).toBeDefined();
    } finally {
      await c.send(new DeleteQueueCommand({ QueueUrl: url }));
    }
  });
});
