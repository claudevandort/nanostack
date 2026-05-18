// SNS Topic Policy enforcement — JS suite (v0.4.2).
// Anonymous via raw form-encoded fetch + owner-bypass via @aws-sdk/client-sns.

import { describe, it, expect } from "vitest";
import {
  SNSClient,
  CreateTopicCommand,
  DeleteTopicCommand,
  PublishCommand,
  SetTopicAttributesCommand,
} from "@aws-sdk/client-sns";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newSns(): SNSClient {
  return new SNSClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniq(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

async function anonCall(action: string, params: Record<string, string>): Promise<Response> {
  const body = new URLSearchParams({ Action: action, Version: "2010-03-31", ...params });
  return fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
}

function publicPublishPolicy(topicName: string): string {
  return JSON.stringify({
    Version: "2012-10-17",
    Statement: [{
      Sid: "PublicPublish",
      Effect: "Allow",
      Principal: "*",
      Action: "sns:Publish",
      Resource: `arn:aws:sns:us-east-1:000000000000:${topicName}`,
    }],
  });
}

function denyAllPolicy(topicName: string): string {
  return JSON.stringify({
    Version: "2012-10-17",
    Statement: [{
      Sid: "DenyAll",
      Effect: "Deny",
      Principal: "*",
      Action: "*",
      Resource: `arn:aws:sns:us-east-1:000000000000:${topicName}`,
    }],
  });
}

describe("sns topic policy enforcement (js)", () => {
  const c = newSns();

  it("anonymous Publish allowed under Principal:* policy", async () => {
    const name = uniq("t_jspol");
    const arn = (await c.send(new CreateTopicCommand({ Name: name }))).TopicArn!;
    try {
      await c.send(new SetTopicAttributesCommand({
        TopicArn: arn,
        AttributeName: "Policy",
        AttributeValue: publicPublishPolicy(name),
      }));
      const resp = await anonCall("Publish", { TopicArn: arn, Message: "hi-anon" });
      expect(resp.status).toBe(200);
      const text = await resp.text();
      expect(text).toContain("<MessageId>");
    } finally {
      await c.send(new DeleteTopicCommand({ TopicArn: arn }));
    }
  });

  it("anonymous Subscribe rejected when policy only allows Publish", async () => {
    const name = uniq("t_jsdeny");
    const arn = (await c.send(new CreateTopicCommand({ Name: name }))).TopicArn!;
    try {
      await c.send(new SetTopicAttributesCommand({
        TopicArn: arn,
        AttributeName: "Policy",
        AttributeValue: publicPublishPolicy(name),
      }));
      const resp = await anonCall("Subscribe", {
        TopicArn: arn,
        Protocol: "sqs",
        Endpoint: "arn:aws:sqs:us-east-1:000000000000:nowhere",
      });
      expect(resp.status).toBe(403);
    } finally {
      await c.send(new DeleteTopicCommand({ TopicArn: arn }));
    }
  });

  it("owner-signed Publish bypasses Deny * policy", async () => {
    const name = uniq("t_jsownerbypass");
    const arn = (await c.send(new CreateTopicCommand({ Name: name }))).TopicArn!;
    try {
      await c.send(new SetTopicAttributesCommand({
        TopicArn: arn,
        AttributeName: "Policy",
        AttributeValue: denyAllPolicy(name),
      }));
      const out = await c.send(new PublishCommand({
        TopicArn: arn,
        Message: "owner-bypass",
      }));
      expect(out.MessageId).toBeDefined();
    } finally {
      await c.send(new DeleteTopicCommand({ TopicArn: arn }));
    }
  });
});
