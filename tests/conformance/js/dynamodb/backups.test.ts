// DynamoDB Backups + PITR conformance — JS suite (v0.2.5).

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  PutItemCommand,
  GetItemCommand,
  CreateBackupCommand,
  ListBackupsCommand,
  DescribeBackupCommand,
  DeleteBackupCommand,
  RestoreTableFromBackupCommand,
  UpdateContinuousBackupsCommand,
  DescribeContinuousBackupsCommand,
} from "@aws-sdk/client-dynamodb";

const endpoint = process.env.NANOSTACK_ENDPOINT ?? "http://127.0.0.1:4577";

function newDdb(): DynamoDBClient {
  return new DynamoDBClient({
    endpoint,
    region: "us-east-1",
    credentials: { accessKeyId: "test", secretAccessKey: "test" },
  });
}

function uniqueTable(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
}

describe("ddb-backups (js)", () => {
  const c = newDdb();
  const T = uniqueTable("js_bkp");

  beforeAll(async () => {
    await c.send(
      new CreateTableCommand({
        TableName: T,
        KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
        AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
        BillingMode: "PAY_PER_REQUEST",
      }),
    );
    await c.send(
      new PutItemCommand({ TableName: T, Item: { id: { S: "u1" }, v: { N: "100" } } }),
    );
  });

  afterAll(async () => {
    await c.send(new DeleteTableCommand({ TableName: T }));
  });

  it("CreateBackup + ListBackups + DescribeBackup round-trip", async () => {
    const created = await c.send(new CreateBackupCommand({ TableName: T, BackupName: "daily-js" }));
    expect(created.BackupDetails?.BackupStatus).toBe("AVAILABLE");
    const arn = created.BackupDetails!.BackupArn!;

    const list = await c.send(new ListBackupsCommand({ TableName: T }));
    const arns = list.BackupSummaries!.map((b) => b.BackupArn);
    expect(arns).toContain(arn);

    const desc = await c.send(new DescribeBackupCommand({ BackupArn: arn }));
    expect(desc.BackupDescription?.BackupDetails?.BackupArn).toBe(arn);
    expect(desc.BackupDescription?.SourceTableDetails?.TableName).toBe(T);
  });

  it("DeleteBackup removes the backup", async () => {
    const created = await c.send(new CreateBackupCommand({ TableName: T, BackupName: "to-delete-js" }));
    const arn = created.BackupDetails!.BackupArn!;
    const out = await c.send(new DeleteBackupCommand({ BackupArn: arn }));
    expect(out.BackupDescription?.BackupDetails?.BackupStatus).toBe("DELETED");
  });

  it("RestoreTableFromBackup round-trips items", async () => {
    const created = await c.send(new CreateBackupCommand({ TableName: T, BackupName: "snap-js" }));
    const arn = created.BackupDetails!.BackupArn!;
    const target = uniqueTable("js_restored");
    const out = await c.send(
      new RestoreTableFromBackupCommand({ BackupArn: arn, TargetTableName: target }),
    );
    try {
      expect(out.TableDescription?.TableName).toBe(target);
      const got = await c.send(new GetItemCommand({ TableName: target, Key: { id: { S: "u1" } } }));
      expect(got.Item?.v?.N).toBe("100");
    } finally {
      await c.send(new DeleteTableCommand({ TableName: target }));
    }
  });

  it("UpdateContinuousBackups enables PITR", async () => {
    const out = await c.send(
      new UpdateContinuousBackupsCommand({
        TableName: T,
        PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true },
      }),
    );
    expect(
      out.ContinuousBackupsDescription?.PointInTimeRecoveryDescription?.PointInTimeRecoveryStatus,
    ).toBe("ENABLED");
  });

  it("DescribeContinuousBackups", async () => {
    const out = await c.send(new DescribeContinuousBackupsCommand({ TableName: T }));
    const status = out.ContinuousBackupsDescription?.ContinuousBackupsStatus;
    expect(status).toBe("ENABLED");
  });

  it("CreateBackup on missing table → ResourceNotFoundException", async () => {
    await expect(
      c.send(new CreateBackupCommand({ TableName: "missing_js_bkp_xyz", BackupName: "nope" })),
    ).rejects.toThrow(/ResourceNotFound|not found/i);
  });
});
