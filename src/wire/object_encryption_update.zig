//! UpdateObjectEncryption XML parser (M13). Same shape as the bucket
//! encryption rule; we extract Algorithm + KMSMasterKeyID.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_lib = @import("xml");
const storage = @import("../storage/mod.zig");

pub const ParseError = error{
    MalformedXml,
    OutOfMemory,
};

pub const Result = struct {
    algorithm: storage.SseAlgorithm,
    kms_key_id: []const u8,  // empty when absent
};

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!Result {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var algorithm: ?storage.SseAlgorithm = null;
    var kms_key_id: []const u8 = "";

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "SSEAlgorithm") or std.mem.eql(u8, name, "Algorithm")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    algorithm = storage.sseAlgorithmFromString(txt) catch return ParseError.MalformedXml;
                } else if (std.mem.eql(u8, name, "KMSMasterKeyID")) {
                    kms_key_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                }
            },
            else => {},
        }
    }
    const a = algorithm orelse return ParseError.MalformedXml;
    return .{ .algorithm = a, .kms_key_id = kms_key_id };
}

pub fn freeOwned(allocator: Allocator, r: Result) void {
    if (r.kms_key_id.len > 0) allocator.free(r.kms_key_id);
}

const testing = std.testing;

test "parseBody: AES256" {
    const body = "<ServerSideEncryption><Algorithm>AES256</Algorithm></ServerSideEncryption>";
    const r = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, r);
    try testing.expectEqual(storage.SseAlgorithm.@"AES256", r.algorithm);
}

test "parseBody: aws:kms with key id" {
    const body = "<ServerSideEncryption><Algorithm>aws:kms</Algorithm><KMSMasterKeyID>arn:aws:kms:us-east-1:1:key/abc</KMSMasterKeyID></ServerSideEncryption>";
    const r = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, r);
    try testing.expectEqual(storage.SseAlgorithm.@"aws:kms", r.algorithm);
    try testing.expectEqualStrings("arn:aws:kms:us-east-1:1:key/abc", r.kms_key_id);
}
