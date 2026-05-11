//! SigV4 canonical-request construction.
//!
//! AWS SigV4 reference:
//! https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
//!
//! Canonical request layout:
//!   {method}\n{canonical-uri}\n{canonical-query-string}\n
//!   {canonical-headers}\n{signed-headers-list}\n{payload-hash}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Error = error{
    MalformedQuery,
    MalformedHeaders,
    MissingSignedHeader,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// URI / query encoding

inline fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

const hex_upper = "0123456789ABCDEF";

/// Encode `in` per SigV4 rules. If `preserve_slash` is true, '/' is left
/// as-is (path encoding). Otherwise '/' is percent-encoded (query encoding).
pub fn uriEncode(allocator: Allocator, in: []const u8, preserve_slash: bool) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, in.len);
    for (in) |c| {
        if (isUnreserved(c) or (preserve_slash and c == '/')) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex_upper[(c >> 4) & 0xF]);
            try out.append(allocator, hex_upper[c & 0xF]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexNibble(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

/// Percent-decode `in`. If `plus_is_space`, replace '+' with ' ' (query
/// semantics). Returns owned slice.
fn percentDecode(allocator: Allocator, in: []const u8, plus_is_space: bool) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        if (in[i] == '%' and i + 2 < in.len) {
            const hi = hexNibble(in[i + 1]) orelse return Error.MalformedQuery;
            const lo = hexNibble(in[i + 2]) orelse return Error.MalformedQuery;
            try out.append(allocator, (hi << 4) | lo);
            i += 2;
        } else if (in[i] == '+' and plus_is_space) {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, in[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Canonical path

/// Canonicalise a path for S3 (single-encoded). Empty input becomes "/".
pub fn canonicalPath(allocator: Allocator, path: []const u8) Error![]u8 {
    if (path.len == 0) return allocator.dupe(u8, "/");
    // Decode then re-encode so the output is unambiguous.
    const decoded = try percentDecode(allocator, path, false);
    defer allocator.free(decoded);
    return uriEncode(allocator, decoded, true);
}

// ---------------------------------------------------------------------------
// Canonical query string

const QueryPair = struct {
    name: []u8,
    value: []u8,
};

fn cmpQueryPair(_: void, a: QueryPair, b: QueryPair) bool {
    const nc = std.mem.order(u8, a.name, b.name);
    if (nc != .eq) return nc == .lt;
    return std.mem.order(u8, a.value, b.value) == .lt;
}

/// Canonicalise a raw query string. Strips entries whose name matches
/// `omit_name` (used to drop `X-Amz-Signature` when verifying presigned
/// URLs). Empty input → empty output.
pub fn canonicalQueryString(allocator: Allocator, query: []const u8, omit_name: ?[]const u8) Error![]u8 {
    if (query.len == 0) return allocator.alloc(u8, 0);

    var pairs: std.ArrayList(QueryPair) = .empty;
    defer {
        for (pairs.items) |p| {
            allocator.free(p.name);
            allocator.free(p.value);
        }
        pairs.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |raw_pair| {
        if (raw_pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, raw_pair, '=');
        const raw_name = if (eq) |i| raw_pair[0..i] else raw_pair;
        const raw_value: []const u8 = if (eq) |i| raw_pair[i + 1 ..] else "";

        const decoded_name = try percentDecode(allocator, raw_name, true);
        defer allocator.free(decoded_name);
        const decoded_value = try percentDecode(allocator, raw_value, true);
        defer allocator.free(decoded_value);

        if (omit_name) |skip| {
            if (std.mem.eql(u8, decoded_name, skip)) continue;
        }

        const enc_name = try uriEncode(allocator, decoded_name, false);
        errdefer allocator.free(enc_name);
        const enc_value = try uriEncode(allocator, decoded_value, false);
        errdefer allocator.free(enc_value);

        try pairs.append(allocator, .{ .name = enc_name, .value = enc_value });
    }

    std.mem.sort(QueryPair, pairs.items, {}, cmpQueryPair);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (pairs.items, 0..) |p, i| {
        if (i > 0) try out.append(allocator, '&');
        try out.appendSlice(allocator, p.name);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, p.value);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Canonical headers

pub const CanonicalHeaders = struct {
    /// `name:value\n` lines, sorted by name (already lowercase).
    block: []u8,
    /// `name1;name2;...` (semicolon-joined, lowercase).
    signed_list: []u8,

    pub fn deinit(self: *CanonicalHeaders, allocator: Allocator) void {
        allocator.free(self.block);
        allocator.free(self.signed_list);
        self.* = undefined;
    }
};

/// Look up a header by case-insensitive name. Returns the FIRST match.
pub fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Trim leading + trailing ASCII whitespace and collapse internal whitespace
/// runs to a single space. Caller owns the returned slice.
fn collapseWhitespace(allocator: Allocator, s: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    var pending_space = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ' ' or c == '\t') {
            pending_space = true;
        } else {
            if (pending_space and out.items.len > 0) try out.append(allocator, ' ');
            pending_space = false;
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Build the canonical headers block + signed-headers list given the
/// authoritative `signed_names` list (already lowercase, semicolon-separated
/// from the Authorization header or `X-Amz-SignedHeaders`).
pub fn canonicalHeaders(allocator: Allocator, signed_names: []const u8, headers: []const Header) Error!CanonicalHeaders {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, signed_names, ';');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        try names.append(allocator, try toLowerOwned(allocator, raw));
    }
    std.mem.sort([]u8, names.items, {}, lessThanSlices);

    var block: std.ArrayList(u8) = .empty;
    errdefer block.deinit(allocator);
    var signed_list: std.ArrayList(u8) = .empty;
    errdefer signed_list.deinit(allocator);

    for (names.items, 0..) |name, i| {
        const value = findHeader(headers, name) orelse return Error.MissingSignedHeader;
        const collapsed = try collapseWhitespace(allocator, value);
        defer allocator.free(collapsed);
        try block.appendSlice(allocator, name);
        try block.append(allocator, ':');
        try block.appendSlice(allocator, collapsed);
        try block.append(allocator, '\n');

        if (i > 0) try signed_list.append(allocator, ';');
        try signed_list.appendSlice(allocator, name);
    }

    return .{
        .block = try block.toOwnedSlice(allocator),
        .signed_list = try signed_list.toOwnedSlice(allocator),
    };
}

fn toLowerOwned(allocator: Allocator, s: []const u8) Error![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn lessThanSlices(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Canonical request

/// Compute the SHA-256 of `body` as 64 lowercase hex chars.
pub fn sha256Hex(body: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Assemble the full canonical request string. `payload_hash` is 64 lowercase
/// hex chars OR a literal like `UNSIGNED-PAYLOAD`.
pub fn canonicalRequest(
    allocator: Allocator,
    method: []const u8,
    canonical_uri: []const u8,
    canonical_query: []const u8,
    canonical_headers_block: []const u8,
    signed_headers_list: []const u8,
    payload_hash: []const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, method);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, canonical_uri);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, canonical_query);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, canonical_headers_block);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, signed_headers_list);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, payload_hash);
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "uriEncode: unreserved chars passed through" {
    const s = try uriEncode(testing.allocator, "abcXYZ-._~123", true);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("abcXYZ-._~123", s);
}

test "uriEncode: slash preserved in path mode" {
    const s = try uriEncode(testing.allocator, "/foo/bar baz", true);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("/foo/bar%20baz", s);
}

test "uriEncode: slash encoded in query mode" {
    const s = try uriEncode(testing.allocator, "a/b", false);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a%2Fb", s);
}

test "canonicalPath: empty becomes slash" {
    const s = try canonicalPath(testing.allocator, "");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("/", s);
}

test "canonicalPath: utf-8 (SigV4 get-utf8)" {
    // U+1234 -> %E1%88%B4
    const path = "/\xe1\x88\xb4";
    const s = try canonicalPath(testing.allocator, path);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("/%E1%88%B4", s);
}

test "canonicalQueryString: empty" {
    const s = try canonicalQueryString(testing.allocator, "", null);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}

test "canonicalQueryString: sorts by name then value" {
    const s = try canonicalQueryString(testing.allocator, "b=2&a=1&a=2", null);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a=1&a=2&b=2", s);
}

test "canonicalQueryString: percent-encodes special chars" {
    const s = try canonicalQueryString(testing.allocator, "foo=hello world&bar=a+b", null);
    defer testing.allocator.free(s);
    // both space and '+' → space in value, then re-encoded as %20
    try testing.expectEqualStrings("bar=a%20b&foo=hello%20world", s);
}

test "canonicalQueryString: omit name strips matching pair" {
    const s = try canonicalQueryString(testing.allocator, "a=1&X-Amz-Signature=abc&b=2", "X-Amz-Signature");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a=1&b=2", s);
}

test "canonicalHeaders: lowercase + trim + collapse + sort" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "  example.amazonaws.com  " },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        .{ .name = "X-Custom", .value = "a   b\tc" },
    };
    var ch = try canonicalHeaders(testing.allocator, "host;x-amz-date;x-custom", &headers);
    defer ch.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "host:example.amazonaws.com\nx-amz-date:20150830T123600Z\nx-custom:a b c\n",
        ch.block,
    );
    try testing.expectEqualStrings("host;x-amz-date;x-custom", ch.signed_list);
}

test "canonicalHeaders: missing signed header → error" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "x.y" },
    };
    const result = canonicalHeaders(testing.allocator, "host;x-custom", &headers);
    try testing.expectError(Error.MissingSignedHeader, result);
}

test "canonicalRequest: SigV4 get-vanilla matches AWS spec" {
    // Reproduce the canonical request from the AWS SigV4 docs (get-vanilla).
    const headers = [_]Header{
        .{ .name = "Host", .value = "example.amazonaws.com" },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
    };

    const path = try canonicalPath(testing.allocator, "/");
    defer testing.allocator.free(path);
    const query = try canonicalQueryString(testing.allocator, "", null);
    defer testing.allocator.free(query);
    var ch = try canonicalHeaders(testing.allocator, "host;x-amz-date", &headers);
    defer ch.deinit(testing.allocator);
    const payload_hash = sha256Hex("");

    const cr = try canonicalRequest(
        testing.allocator,
        "GET",
        path,
        query,
        ch.block,
        ch.signed_list,
        &payload_hash,
    );
    defer testing.allocator.free(cr);

    try testing.expectEqualStrings(
        "GET\n" ++
            "/\n" ++
            "\n" ++
            "host:example.amazonaws.com\n" ++
            "x-amz-date:20150830T123600Z\n" ++
            "\n" ++
            "host;x-amz-date\n" ++
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        cr,
    );
}
