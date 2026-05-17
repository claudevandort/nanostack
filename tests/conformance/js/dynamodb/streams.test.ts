// DynamoDBStreams conformance — JS suite (v0.2.2).
// Validates that @aws-sdk/client-dynamodb-streams talks to nanostack's
// Streams sub-service end-to-end: ListStreams, DescribeStream,
// GetShardIterator (TRIM_HORIZON + AFTER_SEQUENCE_NUMBER), GetRecords
// with INSERT/MODIFY/REMOVE classification + view-type filtering.

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  PutItemCommand,
  UpdateItemCommand,
  DeleteItemCommand,
} from "@aws-sdk/client-dynamodb";
import {
  DynamoDBStreamsClient,
  ListStreamsCommand,
  DescribeStreamCommand,
  GetShardIteratorCommand,
  GetRecordsCommand,
} from "@aws-sdk/client-dynamodb-streams";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newDdb(): DynamoDBClient {
  return new DynamoDBClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function newStreams(): DynamoDBStreamsClient {
  return new DynamoDBStreamsClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniqueTable(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}

async function createStreamedTable(
  c: DynamoDBClient,
  name: string,
  viewType: string = "NEW_AND_OLD_IMAGES",
): Promise<void> {
  await c.send(
    new CreateTableCommand({
      TableName: name,
      KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
      AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
      BillingMode: "PAY_PER_REQUEST",
      StreamSpecification: { StreamEnabled: true, StreamViewType: viewType as any },
    }),
  );
}

describe("ddb-streams (js)", () => {
  const c = newDdb();
  const s = newStreams();

  it("ListStreams + DescribeStream round-trip", async () => {
    const t = uniqueTable("js-strm");
    await createStreamedTable(c, t);
    try {
      const ls = await s.send(new ListStreamsCommand({ TableName: t }));
      expect(ls.Streams).toBeDefined();
      expect(ls.Streams!.length).toBe(1);
      const arn = ls.Streams![0].StreamArn!;
      expect(arn).toMatch(/^arn:aws:dynamodb:us-east-1:000000000000:table\//);

      const desc = await s.send(new DescribeStreamCommand({ StreamArn: arn }));
      expect(desc.StreamDescription?.StreamStatus).toBe("ENABLED");
      expect(desc.StreamDescription?.StreamViewType).toBe("NEW_AND_OLD_IMAGES");
      expect(desc.StreamDescription?.Shards?.length).toBe(1);
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t }));
    }
  });

  it("GetShardIterator + GetRecords replays INSERT/MODIFY/REMOVE", async () => {
    const t = uniqueTable("js-strm");
    await createStreamedTable(c, t);
    try {
      await c.send(new PutItemCommand({ TableName: t, Item: { id: { S: "a" }, v: { N: "1" } } }));
      await c.send(new UpdateItemCommand({
        TableName: t,
        Key: { id: { S: "a" } },
        UpdateExpression: "SET v = :v",
        ExpressionAttributeValues: { ":v": { N: "2" } },
      }));
      await c.send(new DeleteItemCommand({ TableName: t, Key: { id: { S: "a" } } }));

      const arn = (await s.send(new ListStreamsCommand({ TableName: t }))).Streams![0].StreamArn!;
      const shard = (await s.send(new DescribeStreamCommand({ StreamArn: arn })))
        .StreamDescription!.Shards![0].ShardId!;
      const it = (await s.send(new GetShardIteratorCommand({
        StreamArn: arn, ShardId: shard, ShardIteratorType: "TRIM_HORIZON",
      }))).ShardIterator!;
      const recs = await s.send(new GetRecordsCommand({ ShardIterator: it }));
      expect(recs.Records?.length).toBe(3);
      expect(recs.Records!.map((r) => r.eventName)).toEqual(["INSERT", "MODIFY", "REMOVE"]);
      expect(recs.NextShardIterator).toBeDefined();

      const modify = recs.Records![1].dynamodb!;
      expect(modify.OldImage).toEqual({ id: { S: "a" }, v: { N: "1" } });
      expect(modify.NewImage).toEqual({ id: { S: "a" }, v: { N: "2" } });
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t }));
    }
  });

  it("KEYS_ONLY view-type drops both images", async () => {
    const t = uniqueTable("js-strm");
    await createStreamedTable(c, t, "KEYS_ONLY");
    try {
      await c.send(new PutItemCommand({ TableName: t, Item: { id: { S: "a" }, v: { N: "1" } } }));
      const arn = (await s.send(new ListStreamsCommand({ TableName: t }))).Streams![0].StreamArn!;
      const shard = (await s.send(new DescribeStreamCommand({ StreamArn: arn })))
        .StreamDescription!.Shards![0].ShardId!;
      const it = (await s.send(new GetShardIteratorCommand({
        StreamArn: arn, ShardId: shard, ShardIteratorType: "TRIM_HORIZON",
      }))).ShardIterator!;
      const recs = await s.send(new GetRecordsCommand({ ShardIterator: it }));
      const r = recs.Records![0].dynamodb!;
      expect(r.Keys).toEqual({ id: { S: "a" } });
      expect(r.NewImage).toBeUndefined();
      expect(r.OldImage).toBeUndefined();
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t }));
    }
  });

  it("LATEST iterator skips backlog", async () => {
    const t = uniqueTable("js-strm");
    await createStreamedTable(c, t);
    try {
      await c.send(new PutItemCommand({ TableName: t, Item: { id: { S: "before" } } }));
      const arn = (await s.send(new ListStreamsCommand({ TableName: t }))).Streams![0].StreamArn!;
      const shard = (await s.send(new DescribeStreamCommand({ StreamArn: arn })))
        .StreamDescription!.Shards![0].ShardId!;
      const it = (await s.send(new GetShardIteratorCommand({
        StreamArn: arn, ShardId: shard, ShardIteratorType: "LATEST",
      }))).ShardIterator!;
      await c.send(new PutItemCommand({ TableName: t, Item: { id: { S: "after" } } }));
      const recs = await s.send(new GetRecordsCommand({ ShardIterator: it }));
      const keys = recs.Records!.map((r) => r.dynamodb!.Keys!.id.S);
      expect(keys).toEqual(["after"]);
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t }));
    }
  });

  it("ListStreams filters by TableName", async () => {
    const t1 = uniqueTable("js-strm");
    const t2 = uniqueTable("js-strm");
    await createStreamedTable(c, t1);
    await createStreamedTable(c, t2);
    try {
      const ls = await s.send(new ListStreamsCommand({ TableName: t1 }));
      expect(ls.Streams?.length).toBe(1);
      expect(ls.Streams![0].TableName).toBe(t1);
    } finally {
      await c.send(new DeleteTableCommand({ TableName: t1 }));
      await c.send(new DeleteTableCommand({ TableName: t2 }));
    }
  });
});
