//! ServerSideEncryptionConfiguration XML parser + renderer (M11).
//!
//! Body shape:
//!     <ServerSideEncryptionConfiguration>
//!       <Rule>
//!         <ApplyServerSideEncryptionByDefault>
//!           <SSEAlgorithm>AES256</SSEAlgorithm>
//!           <KMSMasterKeyID>arn:aws:kms:...</KMSMasterKeyID>
//!         </ApplyServerSideEncryptionByDefault>
//!         <BucketKeyEnabled>true</BucketKeyEnabled>
//!       </Rule>
//!     </ServerSideEncryptionConfiguration>

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml_lib = @import("xml");
const xml_out = @import("xml.zig");
const storage = @import("../storage/mod.zig");

const xmlns_attr: xml_out.Attr = .{ .name = "xmlns", .value = "http://s3.amazonaws.com/doc/2006-03-01/" };

pub const ParseError = error{
    MalformedXml,
    OutOfMemory,
};

pub fn parseBody(allocator: Allocator, body: []const u8) ParseError!storage.EncryptionConfig {
    var static_reader: xml_lib.Reader.Static = .init(allocator, body, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var rules: std.ArrayList(storage.EncryptionRule) = .empty;
    errdefer {
        for (rules.items) |r| freeRule(allocator, r);
        rules.deinit(allocator);
    }

    var in_rule = false;
    var in_apply = false;
    var apply_alg: ?storage.SseAlgorithm = null;
    var apply_kms_id: ?[]u8 = null;
    var rule_apply: ?storage.SseByDefault = null;
    var rule_bke: ?bool = null;
    errdefer {
        if (apply_kms_id) |s| allocator.free(s);
        if (rule_apply) |a| allocator.free(a.kms_master_key_id);
    }

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "Rule")) {
                    in_rule = true;
                    rule_apply = null;
                    rule_bke = null;
                } else if (in_rule and std.mem.eql(u8, name, "ApplyServerSideEncryptionByDefault")) {
                    in_apply = true;
                    apply_alg = null;
                    apply_kms_id = null;
                } else if (in_apply and std.mem.eql(u8, name, "SSEAlgorithm")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    apply_alg = storage.sseAlgorithmFromString(txt) catch return ParseError.MalformedXml;
                } else if (in_apply and std.mem.eql(u8, name, "KMSMasterKeyID")) {
                    apply_kms_id = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                } else if (in_rule and std.mem.eql(u8, name, "BucketKeyEnabled")) {
                    const txt = reader.readElementTextAlloc(allocator) catch return ParseError.MalformedXml;
                    defer allocator.free(txt);
                    rule_bke = std.mem.eql(u8, txt, "true");
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "ApplyServerSideEncryptionByDefault")) {
                    in_apply = false;
                    const alg = apply_alg orelse return ParseError.MalformedXml;
                    rule_apply = .{
                        .sse_algorithm = alg,
                        .kms_master_key_id = apply_kms_id orelse (allocator.dupe(u8, "") catch return ParseError.OutOfMemory),
                    };
                    apply_kms_id = null;
                    apply_alg = null;
                } else if (std.mem.eql(u8, name, "Rule")) {
                    in_rule = false;
                    const rule: storage.EncryptionRule = .{
                        .apply = rule_apply,
                        .bucket_key_enabled = rule_bke,
                    };
                    rules.append(allocator, rule) catch {
                        freeRule(allocator, rule);
                        return ParseError.OutOfMemory;
                    };
                    rule_apply = null;
                    rule_bke = null;
                }
            },
            else => {},
        }
    }

    return .{ .rules = rules.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
}

pub fn render(allocator: Allocator, cfg: storage.EncryptionConfig) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rule_nodes = try arena.alloc(xml_out.Node, cfg.rules.len);
    for (cfg.rules, 0..) |r, i| {
        var children: std.ArrayList(xml_out.Node) = .empty;
        if (r.apply) |a| {
            var apply_kids: std.ArrayList(xml_out.Node) = .empty;
            const alg_el = try arena.create(xml_out.Element);
            alg_el.* = .{ .name = "SSEAlgorithm", .text = storage.sseAlgorithmToString(a.sse_algorithm) };
            try apply_kids.append(arena, .{ .element = alg_el });
            if (a.kms_master_key_id.len > 0) {
                const kms_el = try arena.create(xml_out.Element);
                kms_el.* = .{ .name = "KMSMasterKeyID", .text = a.kms_master_key_id };
                try apply_kids.append(arena, .{ .element = kms_el });
            }
            const apply_el = try arena.create(xml_out.Element);
            apply_el.* = .{ .name = "ApplyServerSideEncryptionByDefault", .children = apply_kids.items };
            try children.append(arena, .{ .element = apply_el });
        }
        if (r.bucket_key_enabled) |bke| {
            const bke_el = try arena.create(xml_out.Element);
            bke_el.* = .{ .name = "BucketKeyEnabled", .text = if (bke) "true" else "false" };
            try children.append(arena, .{ .element = bke_el });
        }
        const rule_el = try arena.create(xml_out.Element);
        rule_el.* = .{ .name = "Rule", .children = children.items };
        rule_nodes[i] = .{ .element = rule_el };
    }

    const root: xml_out.Element = .{
        .name = "ServerSideEncryptionConfiguration",
        .attrs = &.{xmlns_attr},
        .children = rule_nodes,
    };
    return xml_out.renderToOwnedSlice(allocator, &root);
}

fn freeRule(allocator: Allocator, r: storage.EncryptionRule) void {
    if (r.apply) |a| allocator.free(a.kms_master_key_id);
}

pub fn freeOwned(allocator: Allocator, cfg: storage.EncryptionConfig) void {
    for (cfg.rules) |r| freeRule(allocator, r);
    allocator.free(cfg.rules);
}

const testing = std.testing;

test "parseBody: AES256" {
    const body =
        \\<ServerSideEncryptionConfiguration>
        \\  <Rule>
        \\    <ApplyServerSideEncryptionByDefault>
        \\      <SSEAlgorithm>AES256</SSEAlgorithm>
        \\    </ApplyServerSideEncryptionByDefault>
        \\  </Rule>
        \\</ServerSideEncryptionConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqual(storage.SseAlgorithm.@"AES256", cfg.rules[0].apply.?.sse_algorithm);
}

test "parseBody: aws:kms with key id" {
    const body =
        \\<ServerSideEncryptionConfiguration><Rule>
        \\<ApplyServerSideEncryptionByDefault>
        \\<SSEAlgorithm>aws:kms</SSEAlgorithm>
        \\<KMSMasterKeyID>arn:aws:kms:us-east-1:1234:key/abc</KMSMasterKeyID>
        \\</ApplyServerSideEncryptionByDefault>
        \\<BucketKeyEnabled>true</BucketKeyEnabled>
        \\</Rule></ServerSideEncryptionConfiguration>
    ;
    const cfg = try parseBody(testing.allocator, body);
    defer freeOwned(testing.allocator, cfg);
    try testing.expectEqual(storage.SseAlgorithm.@"aws:kms", cfg.rules[0].apply.?.sse_algorithm);
    try testing.expectEqualStrings("arn:aws:kms:us-east-1:1234:key/abc", cfg.rules[0].apply.?.kms_master_key_id);
    try testing.expectEqual(@as(?bool, true), cfg.rules[0].bucket_key_enabled);
}

test "render: AES256 round-trip" {
    const apply: storage.SseByDefault = .{ .sse_algorithm = .@"AES256" };
    const rules = [_]storage.EncryptionRule{.{ .apply = apply }};
    const cfg: storage.EncryptionConfig = .{ .rules = &rules };
    const body = try render(testing.allocator, cfg);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "<SSEAlgorithm>AES256</SSEAlgorithm>") != null);
}
