// DynamoDB item-CRUD conformance — JS suite (v0.2.1).
// Proves marshall/unmarshall via @aws-sdk/util-dynamodb round-trips
// against nanostack's AttributeValue codec.

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  PutItemCommand,
  GetItemCommand,
  DeleteItemCommand,
} from "@aws-sdk/client-dynamodb";
import { marshall, unmarshall } from "@aws-sdk/util-dynamodb";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newClient(): DynamoDBClient {
  return new DynamoDBClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

const TABLE = `js-ddb-items-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
const c = newClient();

beforeAll(async () => {
  await c.send(
    new CreateTableCommand({
      TableName: TABLE,
      KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
      AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
      BillingMode: "PAY_PER_REQUEST",
    }),
  );
});

afterAll(async () => {
  try {
    await c.send(new DeleteTableCommand({ TableName: TABLE }));
  } catch {
    /* best-effort */
  }
});

describe("DynamoDB PutItem + GetItem via marshall/unmarshall", () => {
  it("string + number round-trips", async () => {
    const item = { id: "k1", title: "Inception", year: 2010 };
    await c.send(
      new PutItemCommand({ TableName: TABLE, Item: marshall(item) }),
    );
    const out = await c.send(
      new GetItemCommand({ TableName: TABLE, Key: marshall({ id: "k1" }) }),
    );
    expect(out.Item).toBeDefined();
    const got = unmarshall(out.Item!);
    expect(got.title).toBe("Inception");
    expect(got.year).toBe(2010);
  });

  it("nested map + list round-trip", async () => {
    const item = {
      id: "k2",
      addr: { city: "Berlin", postcode: "10115" },
      tags: ["alpha", "beta"],
    };
    await c.send(
      new PutItemCommand({ TableName: TABLE, Item: marshall(item) }),
    );
    const out = await c.send(
      new GetItemCommand({ TableName: TABLE, Key: marshall({ id: "k2" }) }),
    );
    const got = unmarshall(out.Item!);
    expect(got.addr.city).toBe("Berlin");
    expect(got.tags).toEqual(["alpha", "beta"]);
  });

  it("string set round-trips (sets are unordered)", async () => {
    // marshall converts a JS Set to {SS: [...]} automatically.
    const item = { id: "k3", colors: new Set(["red", "blue", "green"]) };
    await c.send(
      new PutItemCommand({ TableName: TABLE, Item: marshall(item) }),
    );
    const out = await c.send(
      new GetItemCommand({ TableName: TABLE, Key: marshall({ id: "k3" }) }),
    );
    const got = unmarshall(out.Item!);
    expect(new Set(got.colors)).toEqual(new Set(["red", "blue", "green"]));
  });
});

describe("DynamoDB DeleteItem", () => {
  it("removes the item; subsequent GetItem returns no Item", async () => {
    await c.send(
      new PutItemCommand({ TableName: TABLE, Item: marshall({ id: "k-del", v: "x" }) }),
    );
    await c.send(
      new DeleteItemCommand({ TableName: TABLE, Key: marshall({ id: "k-del" }) }),
    );
    const out = await c.send(
      new GetItemCommand({ TableName: TABLE, Key: marshall({ id: "k-del" }) }),
    );
    expect(out.Item).toBeUndefined();
  });
});
