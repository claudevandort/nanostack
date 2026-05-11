//! SigV4 verification — header authentication AND presigned URLs.
//!
//! Pipeline:
//!   1. Choose mode: `Authorization: AWS4-HMAC-SHA256 …` → header auth;
//!      `X-Amz-Algorithm=AWS4-HMAC-SHA256` in query → presigned.
//!   2. Parse credential scope; check it matches the configured
//!      access-key/region/service.
//!   3. Validate clock skew against `X-Amz-Date`.
//!   4. Resolve the payload hash: hex digest, `UNSIGNED-PAYLOAD`, or
//!      computed from the body. Streaming hashes → `StreamingUnsupported`.
//!   5. Build the canonical request and string-to-sign.
//!   6. Derive the signing key (HMAC-SHA256 cascade).
//!   7. Compute the signature and constant-time compare with what the
//!      client sent.
//!
//! The "presigned URL with custom headers" case is implemented as a
//! first-class flow (see `verifyPresigned`). It's the LocalStack divergence
//! we exist to fix: a header listed in `X-Amz-SignedHeaders` but missing
//! from the request returns `MissingSignedHeader` rather than panicking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const timing_safe = std.crypto.timing_safe;

const canonical = @import("canonical.zig");
const signing_key = @import("signing_key.zig");
const iso8601 = @import("iso8601.zig");

pub const Header = canonical.Header;

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: []const Header,
    body: []const u8,
};

pub const Credentials = struct {
    access_key: []const u8,
    secret_key: []const u8,
};

pub const VerifyOptions = struct {
    region: []const u8,
    service: []const u8,
    now_unix: i64,
    skew_tolerance_seconds: i64 = 900,
};

pub const VerifyError = error{
    MissingAuth,
    MalformedAuthorization,
    MalformedCredentialScope,
    MalformedPresignedQuery,
    InvalidAccessKeyId,
    SignatureDoesNotMatch,
    MissingSignedHeader,
    RequestTimeTooSkewed,
    PresignedExpired,
    StreamingUnsupported,
    XAmzContentSha256Mismatch,
    OutOfMemory,
    MalformedQuery,
    MalformedHeaders,
};

/// Top-level entry point. Branches between header-auth and presigned URLs.
pub fn verify(
    allocator: Allocator,
    req: Request,
    creds: Credentials,
    opts: VerifyOptions,
) VerifyError!void {
    if (canonical.findHeader(req.headers, "Authorization")) |auth| {
        if (std.mem.startsWith(u8, auth, "AWS4-HMAC-SHA256")) {
            return verifyHeader(allocator, req, creds, opts, auth);
        }
    }
    if (queryParam(req.query, "X-Amz-Algorithm")) |alg| {
        if (std.mem.eql(u8, alg, "AWS4-HMAC-SHA256")) {
            return verifyPresigned(allocator, req, creds, opts);
        }
    }
    return VerifyError.MissingAuth;
}

// ---------------------------------------------------------------------------
// Header authentication

const Authorization = struct {
    access_key: []const u8,
    date: []const u8, // YYYYMMDD
    region: []const u8,
    service: []const u8,
    signed_headers: []const u8, // semicolon-joined
    signature: []const u8, // 64 hex
};

fn parseAuthorization(header_value: []const u8) VerifyError!Authorization {
    const prefix = "AWS4-HMAC-SHA256 ";
    if (!std.mem.startsWith(u8, header_value, prefix)) return VerifyError.MalformedAuthorization;
    const rest = std.mem.trim(u8, header_value[prefix.len..], " ");

    var credential: ?[]const u8 = null;
    var signed_headers: ?[]const u8 = null;
    var signature: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " ");
        if (std.mem.startsWith(u8, trimmed, "Credential=")) {
            credential = trimmed["Credential=".len..];
        } else if (std.mem.startsWith(u8, trimmed, "SignedHeaders=")) {
            signed_headers = trimmed["SignedHeaders=".len..];
        } else if (std.mem.startsWith(u8, trimmed, "Signature=")) {
            signature = trimmed["Signature=".len..];
        }
    }

    const cred = credential orelse return VerifyError.MalformedAuthorization;
    const sh = signed_headers orelse return VerifyError.MalformedAuthorization;
    const sig = signature orelse return VerifyError.MalformedAuthorization;
    if (sig.len != 64) return VerifyError.MalformedAuthorization;

    return parseCredential(cred, sh, sig);
}

fn parseCredential(cred: []const u8, sh: []const u8, sig: []const u8) VerifyError!Authorization {
    // <access>/<date>/<region>/<service>/aws4_request
    var parts: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, cred, '/');
    while (it.next()) |p| : (count += 1) {
        if (count >= 5) return VerifyError.MalformedCredentialScope;
        parts[count] = p;
    }
    if (count != 5) return VerifyError.MalformedCredentialScope;
    if (!std.mem.eql(u8, parts[4], "aws4_request")) return VerifyError.MalformedCredentialScope;
    return .{
        .access_key = parts[0],
        .date = parts[1],
        .region = parts[2],
        .service = parts[3],
        .signed_headers = sh,
        .signature = sig,
    };
}

fn verifyHeader(
    allocator: Allocator,
    req: Request,
    creds: Credentials,
    opts: VerifyOptions,
    auth_value: []const u8,
) VerifyError!void {
    const auth = try parseAuthorization(auth_value);

    if (!std.mem.eql(u8, auth.access_key, creds.access_key)) return VerifyError.InvalidAccessKeyId;
    if (!std.mem.eql(u8, auth.region, opts.region)) return VerifyError.MalformedCredentialScope;
    if (!std.mem.eql(u8, auth.service, opts.service)) return VerifyError.MalformedCredentialScope;

    const amz_date = canonical.findHeader(req.headers, "X-Amz-Date") orelse
        return VerifyError.MalformedAuthorization;
    try checkSkew(amz_date, opts);

    // Resolve payload hash from x-amz-content-sha256 if present, else SHA-256 of body.
    const payload_hash = try resolvePayloadHash(req, allocator);
    defer freePayloadHash(allocator, payload_hash);

    try verifyAgainst(allocator, req, creds, opts, .{
        .signed_headers = auth.signed_headers,
        .amz_date = amz_date,
        .scope_date = auth.date,
        .payload_hash = payload_hash.bytes,
        .expected_signature = auth.signature,
        .query_for_canonical = req.query,
    });
}

// ---------------------------------------------------------------------------
// Presigned URLs

fn verifyPresigned(
    allocator: Allocator,
    req: Request,
    creds: Credentials,
    opts: VerifyOptions,
) VerifyError!void {
    const credential = queryParam(req.query, "X-Amz-Credential") orelse
        return VerifyError.MalformedPresignedQuery;
    const amz_date = queryParam(req.query, "X-Amz-Date") orelse
        return VerifyError.MalformedPresignedQuery;
    const expires_str = queryParam(req.query, "X-Amz-Expires") orelse
        return VerifyError.MalformedPresignedQuery;
    const signed_headers_raw = queryParam(req.query, "X-Amz-SignedHeaders") orelse
        return VerifyError.MalformedPresignedQuery;
    const signature = queryParam(req.query, "X-Amz-Signature") orelse
        return VerifyError.MalformedPresignedQuery;
    if (signature.len != 64) return VerifyError.MalformedPresignedQuery;

    // X-Amz-Credential arrives URL-encoded ('/' as %2F).
    var credential_buf: [512]u8 = undefined;
    const cred_decoded = decodePercentInto(&credential_buf, credential) orelse
        return VerifyError.MalformedPresignedQuery;
    // X-Amz-SignedHeaders is also encoded (';' as %3B).
    var signed_headers_buf: [1024]u8 = undefined;
    const signed_headers = decodePercentInto(&signed_headers_buf, signed_headers_raw) orelse
        return VerifyError.MalformedPresignedQuery;

    const parsed = try parseCredential(cred_decoded, signed_headers, signature);
    if (!std.mem.eql(u8, parsed.access_key, creds.access_key)) return VerifyError.InvalidAccessKeyId;
    if (!std.mem.eql(u8, parsed.region, opts.region)) return VerifyError.MalformedCredentialScope;
    if (!std.mem.eql(u8, parsed.service, opts.service)) return VerifyError.MalformedCredentialScope;

    // Expires check: now must be ≤ amz_date + expires_seconds.
    const expires = std.fmt.parseInt(i64, expires_str, 10) catch return VerifyError.MalformedPresignedQuery;
    const issued = iso8601.parseAmzDate(amz_date) catch return VerifyError.MalformedPresignedQuery;
    if (opts.now_unix > issued + expires) return VerifyError.PresignedExpired;
    if (opts.now_unix + opts.skew_tolerance_seconds < issued) return VerifyError.RequestTimeTooSkewed;

    // Presigned URLs: AWS spec says the payload hash is `UNSIGNED-PAYLOAD`,
    // but some SDKs (notably @smithy/signature-v4 for GETs with no body)
    // sign with SHA-256("") instead. We try the spec value first and fall
    // back to the smithy convention so both client families work without
    // configuration.
    const spec_payload_hash = "UNSIGNED-PAYLOAD";
    const sha_empty_payload_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    verifyAgainst(allocator, req, creds, opts, .{
        .signed_headers = signed_headers,
        .amz_date = amz_date,
        .scope_date = parsed.date,
        .payload_hash = spec_payload_hash,
        .expected_signature = signature,
        .query_for_canonical = req.query,
        .omit_query_param = "X-Amz-Signature",
    }) catch |err| {
        if (err != VerifyError.SignatureDoesNotMatch) return err;
        try verifyAgainst(allocator, req, creds, opts, .{
            .signed_headers = signed_headers,
            .amz_date = amz_date,
            .scope_date = parsed.date,
            .payload_hash = sha_empty_payload_hash,
            .expected_signature = signature,
            .query_for_canonical = req.query,
            .omit_query_param = "X-Amz-Signature",
        });
    };
}

// ---------------------------------------------------------------------------
// Shared signature verification

const VerifyInputs = struct {
    signed_headers: []const u8,
    amz_date: []const u8,
    scope_date: []const u8,
    payload_hash: []const u8,
    expected_signature: []const u8,
    query_for_canonical: []const u8,
    omit_query_param: ?[]const u8 = null,
};

fn verifyAgainst(
    allocator: Allocator,
    req: Request,
    creds: Credentials,
    opts: VerifyOptions,
    in: VerifyInputs,
) VerifyError!void {
    const cpath = try canonical.canonicalPath(allocator, req.path);
    defer allocator.free(cpath);
    const cquery = try canonical.canonicalQueryString(allocator, in.query_for_canonical, in.omit_query_param);
    defer allocator.free(cquery);
    var cheaders = try canonical.canonicalHeaders(allocator, in.signed_headers, req.headers);
    defer cheaders.deinit(allocator);

    const creq = try canonical.canonicalRequest(
        allocator,
        req.method,
        cpath,
        cquery,
        cheaders.block,
        cheaders.signed_list,
        in.payload_hash,
    );
    defer allocator.free(creq);

    const creq_hash = canonical.sha256Hex(creq);
    const sts = try buildStringToSign(allocator, in.amz_date, in.scope_date, opts.region, opts.service, &creq_hash);
    defer allocator.free(sts);

    const k_signing = signing_key.derive(creds.secret_key, in.scope_date, opts.region, opts.service);
    const expected = signing_key.signHex(k_signing, sts);

    if (in.expected_signature.len != expected.len) return VerifyError.SignatureDoesNotMatch;
    var got: [64]u8 = undefined;
    @memcpy(&got, in.expected_signature[0..64]);
    // Constant-time compare requires arrays.
    if (!timing_safe.eql([64]u8, got, expected)) return VerifyError.SignatureDoesNotMatch;
}

fn buildStringToSign(
    allocator: Allocator,
    amz_date: []const u8,
    scope_date: []const u8,
    region: []const u8,
    service: []const u8,
    creq_hash: []const u8,
) VerifyError![]u8 {
    return std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}", .{
        amz_date,
        scope_date,
        region,
        service,
        creq_hash,
    }) catch return VerifyError.OutOfMemory;
}

fn checkSkew(amz_date: []const u8, opts: VerifyOptions) VerifyError!void {
    const t = iso8601.parseAmzDate(amz_date) catch return VerifyError.MalformedAuthorization;
    const delta = if (opts.now_unix >= t) opts.now_unix - t else t - opts.now_unix;
    if (delta > opts.skew_tolerance_seconds) return VerifyError.RequestTimeTooSkewed;
}

const PayloadHash = struct {
    bytes: []const u8,
    owned: bool,
};

fn resolvePayloadHash(req: Request, allocator: Allocator) VerifyError!PayloadHash {
    if (canonical.findHeader(req.headers, "x-amz-content-sha256")) |v| {
        if (std.mem.eql(u8, v, "UNSIGNED-PAYLOAD")) {
            return .{ .bytes = "UNSIGNED-PAYLOAD", .owned = false };
        }
        if (std.mem.startsWith(u8, v, "STREAMING-")) {
            return VerifyError.StreamingUnsupported;
        }
        if (v.len == 64 and isLowercaseHex(v)) {
            // Hex digest mode: verify the body actually matches what the
            // client signed. Without this, the body could be tampered in
            // transit and we'd accept it.
            const actual = canonical.sha256Hex(req.body);
            if (!std.mem.eql(u8, v, &actual)) return VerifyError.XAmzContentSha256Mismatch;
            return .{ .bytes = v, .owned = false };
        }
        // Otherwise treat as opaque and use literally — AWS allows raw values.
        return .{ .bytes = v, .owned = false };
    }
    const hex = canonical.sha256Hex(req.body);
    const buf = allocator.alloc(u8, 64) catch return VerifyError.OutOfMemory;
    @memcpy(buf, &hex);
    return .{ .bytes = buf, .owned = true };
}

fn isLowercaseHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn freePayloadHash(allocator: Allocator, p: PayloadHash) void {
    if (p.owned) allocator.free(p.bytes);
}

// ---------------------------------------------------------------------------
// Query parameter helpers (raw, percent-encoded — caller handles decoding)

pub fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    if (query.len == 0) return null;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn decodePercentInto(buf: []u8, in: []const u8) ?[]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        if (in[i] == '%' and i + 2 < in.len) {
            const hi = hexNibble(in[i + 1]) orelse return null;
            const lo = hexNibble(in[i + 2]) orelse return null;
            if (w >= buf.len) return null;
            buf[w] = (hi << 4) | lo;
            w += 1;
            i += 2;
        } else {
            if (w >= buf.len) return null;
            buf[w] = in[i];
            w += 1;
        }
    }
    return buf[0..w];
}

fn hexNibble(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "verify: AWS SigV4 get-vanilla example" {
    // The canonical request from `get-vanilla` is verified end-to-end here:
    // we reconstruct the exact Authorization header from AWS's docs and
    // assert verify() returns success.
    const headers = [_]Header{
        .{ .name = "Host", .value = "example.amazonaws.com" },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        .{
            .name = "Authorization",
            .value = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
        },
    };

    try verify(
        testing.allocator,
        .{
            .method = "GET",
            .path = "/",
            .query = "",
            .headers = &headers,
            .body = "",
        },
        .{ .access_key = "AKIDEXAMPLE", .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" },
        .{
            .region = "us-east-1",
            .service = "service",
            .now_unix = 1440938160, // == 20150830T123600Z, so skew is 0.
        },
    );
}

test "verify: tampered signature → SignatureDoesNotMatch" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "example.amazonaws.com" },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        .{
            .name = "Authorization",
            .value = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=0000000000000000000000000000000000000000000000000000000000000000",
        },
    };
    try testing.expectError(VerifyError.SignatureDoesNotMatch, verify(
        testing.allocator,
        .{ .method = "GET", .path = "/", .query = "", .headers = &headers, .body = "" },
        .{ .access_key = "AKIDEXAMPLE", .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" },
        .{ .region = "us-east-1", .service = "service", .now_unix = 1440938160 },
    ));
}

test "verify: wrong access key → InvalidAccessKeyId" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "example.amazonaws.com" },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        .{
            .name = "Authorization",
            .value = "AWS4-HMAC-SHA256 Credential=WRONG/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
        },
    };
    try testing.expectError(VerifyError.InvalidAccessKeyId, verify(
        testing.allocator,
        .{ .method = "GET", .path = "/", .query = "", .headers = &headers, .body = "" },
        .{ .access_key = "AKIDEXAMPLE", .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" },
        .{ .region = "us-east-1", .service = "service", .now_unix = 1440938160 },
    ));
}

test "verify: skew outside tolerance → RequestTimeTooSkewed" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "example.amazonaws.com" },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        .{
            .name = "Authorization",
            .value = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
        },
    };
    try testing.expectError(VerifyError.RequestTimeTooSkewed, verify(
        testing.allocator,
        .{ .method = "GET", .path = "/", .query = "", .headers = &headers, .body = "" },
        .{ .access_key = "AKIDEXAMPLE", .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" },
        .{ .region = "us-east-1", .service = "service", .now_unix = 1440938160 + 1000, .skew_tolerance_seconds = 900 },
    ));
}

test "verify: missing signed header → MissingSignedHeader (the LocalStack bug)" {
    // Authorization advertises a signed header that isn't on the request.
    const headers = [_]Header{
        .{ .name = "Host", .value = "example.amazonaws.com" },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        .{
            .name = "Authorization",
            // SignedHeaders includes x-missing.
            .value = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date;x-missing, Signature=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        },
    };
    try testing.expectError(VerifyError.MissingSignedHeader, verify(
        testing.allocator,
        .{ .method = "GET", .path = "/", .query = "", .headers = &headers, .body = "" },
        .{ .access_key = "AKIDEXAMPLE", .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" },
        .{ .region = "us-east-1", .service = "service", .now_unix = 1440938160 },
    ));
}

test "verify: no Authorization, no presigned → MissingAuth" {
    const headers = [_]Header{.{ .name = "Host", .value = "x" }};
    try testing.expectError(VerifyError.MissingAuth, verify(
        testing.allocator,
        .{ .method = "GET", .path = "/", .query = "", .headers = &headers, .body = "" },
        .{ .access_key = "AKIDEXAMPLE", .secret_key = "secret" },
        .{ .region = "us-east-1", .service = "s3", .now_unix = 0 },
    ));
}

test "verify: streaming hash → StreamingUnsupported" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "x" },
        .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        .{ .name = "x-amz-content-sha256", .value = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD" },
        .{ .name = "Authorization", .value = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=0000000000000000000000000000000000000000000000000000000000000000" },
    };
    try testing.expectError(VerifyError.StreamingUnsupported, verify(
        testing.allocator,
        .{ .method = "PUT", .path = "/bucket/key", .query = "", .headers = &headers, .body = "" },
        .{ .access_key = "AKIDEXAMPLE", .secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" },
        .{ .region = "us-east-1", .service = "s3", .now_unix = 1440938160 },
    ));
}

test "verify presigned: happy path round-trip" {
    // We construct a presigned URL with a known signature using our own
    // primitives, then verify it. This proves the presigned path is
    // self-consistent end-to-end; SDK-driven tests in conformance/ cover
    // interop with the real AWS signers.
    const region = "us-east-1";
    const service = "s3";
    const access_key = "AKIDEXAMPLE";
    const secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
    const scope_date = "20150830";
    const amz_date = "20150830T123600Z";
    const expires = "3600";
    const signed_headers = "host";

    // Build the unsigned query.
    var query_buf: [512]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buf, "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential={s}%2F{s}%2F{s}%2F{s}%2Faws4_request&X-Amz-Date={s}&X-Amz-Expires={s}&X-Amz-SignedHeaders={s}", .{
        access_key,
        scope_date,
        region,
        service,
        amz_date,
        expires,
        signed_headers,
    }) catch unreachable;

    const headers = [_]Header{
        .{ .name = "Host", .value = "example.amazonaws.com" },
    };

    // Compute the expected signature using the same canonical pipeline.
    const cpath = try canonical.canonicalPath(testing.allocator, "/");
    defer testing.allocator.free(cpath);
    const cquery = try canonical.canonicalQueryString(testing.allocator, query, null);
    defer testing.allocator.free(cquery);
    var ch = try canonical.canonicalHeaders(testing.allocator, signed_headers, &headers);
    defer ch.deinit(testing.allocator);
    const creq = try canonical.canonicalRequest(testing.allocator, "GET", cpath, cquery, ch.block, ch.signed_list, "UNSIGNED-PAYLOAD");
    defer testing.allocator.free(creq);
    const creq_hash = canonical.sha256Hex(creq);
    const sts = try std.fmt.allocPrint(testing.allocator, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}", .{ amz_date, scope_date, region, service, &creq_hash });
    defer testing.allocator.free(sts);
    const k = signing_key.derive(secret_key, scope_date, region, service);
    const sig = signing_key.signHex(k, sts);

    // Append the signature to the query.
    var full_query_buf: [768]u8 = undefined;
    const full_query = std.fmt.bufPrint(&full_query_buf, "{s}&X-Amz-Signature={s}", .{ query, &sig }) catch unreachable;

    try verify(
        testing.allocator,
        .{ .method = "GET", .path = "/", .query = full_query, .headers = &headers, .body = "" },
        .{ .access_key = access_key, .secret_key = secret_key },
        .{ .region = region, .service = service, .now_unix = 1440938160 },
    );
}
