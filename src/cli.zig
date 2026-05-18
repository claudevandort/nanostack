//! CLI argument parsing.
//!
//! Flag set tracks PRD §10. Unknown flags abort with a clear message.

const std = @import("std");

pub const Config = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 4566,
    data_dir: ?[]const u8 = null,
    profile: []const u8 = "default",
    services: []const u8 = "s3",
    log_level: []const u8 = "info",
    access_key: []const u8 = "test",
    secret_key: []const u8 = "test",
    region: []const u8 = "us-east-1",
    /// Internal: start everything, then exit. Used to benchmark cold start
    /// without holding the listener open.
    self_test_ready: bool = false,
    /// Skip SigV4 verification entirely (curl-friendly dev mode). Off by
    /// default — real AWS rejects unsigned requests, and so do we.
    no_auth: bool = false,
    /// SigV4 clock-skew tolerance (seconds). AWS default is 900 (15 min).
    skew_seconds: i64 = 900,
    /// DynamoDB TTL background sweep interval (seconds). Real AWS evicts
    /// expired items "best effort within 48h"; for local-dev tests we
    /// default to 5s so callers don't need to wait. Range: 1..=3600.
    ttl_sweep_interval_seconds: u32 = 5,
    /// SQS MessageRetentionPeriod sweeper interval (seconds). Real AWS
    /// best-effort within 60 seconds; for local-dev tests we default
    /// to 60s. Range: 1..=3600.
    sqs_retention_sweep_interval_seconds: u32 = 60,
    /// Account ID embedded in ARNs + SQS queue URLs. AWS accounts are
    /// 12 digits; nanostack uses 000000000000 by default to match the
    /// LocalStack-style placeholder.
    account_id: []const u8 = "000000000000",
    /// `--version` flag: print version + exit before starting the server.
    print_version: bool = false,

    /// True if the comma-separated `--services` list contains `name`.
    /// Case-sensitive, whitespace-trimmed around each entry.
    pub fn hasService(self: Config, name: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.services, ',');
        while (it.next()) |raw| {
            const s = std.mem.trim(u8, raw, " \t");
            if (std.mem.eql(u8, s, name)) return true;
        }
        return false;
    }
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
};

pub fn parse(args: []const [:0]const u8) ParseError!Config {
    var c: Config = .{};
    // Skip arg[0] (executable name).
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            c.print_version = true;
        } else if (std.mem.eql(u8, arg, "--self-test-ready")) {
            c.self_test_ready = true;
        } else if (std.mem.eql(u8, arg, "--no-auth")) {
            c.no_auth = true;
        } else if (std.mem.eql(u8, arg, "--skew-seconds")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.skew_seconds = std.fmt.parseInt(i64, args[i], 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--ttl-sweep-interval-seconds")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            const n = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.InvalidValue;
            if (n < 1 or n > 3600) return ParseError.InvalidValue;
            c.ttl_sweep_interval_seconds = n;
        } else if (std.mem.eql(u8, arg, "--sqs-retention-sweep-interval-seconds")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            const n = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.InvalidValue;
            if (n < 1 or n > 3600) return ParseError.InvalidValue;
            c.sqs_retention_sweep_interval_seconds = n;
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.port = std.fmt.parseInt(u16, args[i], 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--bind")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.bind = args[i];
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.data_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.profile = args[i];
        } else if (std.mem.eql(u8, arg, "--services")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.services = args[i];
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.log_level = args[i];
        } else if (std.mem.eql(u8, arg, "--access-key")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.access_key = args[i];
        } else if (std.mem.eql(u8, arg, "--secret-key")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.secret_key = args[i];
        } else if (std.mem.eql(u8, arg, "--region")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.region = args[i];
        } else if (std.mem.eql(u8, arg, "--account-id")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            c.account_id = args[i];
        } else {
            return ParseError.UnknownFlag;
        }
    }
    return c;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "defaults" {
    const c = try parse(&.{"nanostack"});
    try testing.expectEqualStrings("127.0.0.1", c.bind);
    try testing.expectEqual(@as(u16, 4566), c.port);
    try testing.expectEqualStrings("default", c.profile);
}

test "overrides" {
    const c = try parse(&.{ "nanostack", "--port", "9999", "--bind", "0.0.0.0", "--region", "eu-west-1" });
    try testing.expectEqual(@as(u16, 9999), c.port);
    try testing.expectEqualStrings("0.0.0.0", c.bind);
    try testing.expectEqualStrings("eu-west-1", c.region);
}

test "--ttl-sweep-interval-seconds parses + range-checks" {
    const c = try parse(&.{ "nanostack", "--ttl-sweep-interval-seconds", "30" });
    try testing.expectEqual(@as(u32, 30), c.ttl_sweep_interval_seconds);
    try testing.expectError(ParseError.InvalidValue, parse(&.{ "nanostack", "--ttl-sweep-interval-seconds", "0" }));
    try testing.expectError(ParseError.InvalidValue, parse(&.{ "nanostack", "--ttl-sweep-interval-seconds", "3601" }));
}

test "no-auth + skew flags" {
    const c = try parse(&.{ "nanostack", "--no-auth", "--skew-seconds", "60" });
    try testing.expect(c.no_auth);
    try testing.expectEqual(@as(i64, 60), c.skew_seconds);
}

test "--version sets print_version" {
    const c = try parse(&.{ "nanostack", "--version" });
    try testing.expect(c.print_version);
}

test "unknown flag" {
    try testing.expectError(ParseError.UnknownFlag, parse(&.{ "nanostack", "--what" }));
}

test "missing value" {
    try testing.expectError(ParseError.MissingValue, parse(&.{ "nanostack", "--port" }));
}

test "invalid port" {
    try testing.expectError(ParseError.InvalidValue, parse(&.{ "nanostack", "--port", "abc" }));
}

test "hasService: default is s3 only" {
    const c = try parse(&.{"nanostack"});
    try testing.expect(c.hasService("s3"));
    try testing.expect(!c.hasService("dynamodb"));
}

test "hasService: --services s3,dynamodb enables both" {
    const c = try parse(&.{ "nanostack", "--services", "s3,dynamodb" });
    try testing.expect(c.hasService("s3"));
    try testing.expect(c.hasService("dynamodb"));
}

test "hasService: --services dynamodb only" {
    const c = try parse(&.{ "nanostack", "--services", "dynamodb" });
    try testing.expect(!c.hasService("s3"));
    try testing.expect(c.hasService("dynamodb"));
}

test "hasService: whitespace tolerated" {
    const c = try parse(&.{ "nanostack", "--services", "s3, dynamodb" });
    try testing.expect(c.hasService("s3"));
    try testing.expect(c.hasService("dynamodb"));
}
