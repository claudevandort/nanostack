//! SigV4 signing-key derivation.
//!
//! Output: 32-byte HMAC-SHA256 key used as the HMAC secret for the final
//! StringToSign signature.
//!
//!   kDate    = HMAC-SHA256("AWS4" + secret, date)
//!   kRegion  = HMAC-SHA256(kDate, region)
//!   kService = HMAC-SHA256(kRegion, service)
//!   kSigning = HMAC-SHA256(kService, "aws4_request")

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Key = [32]u8;

pub fn derive(secret_key: []const u8, date_yyyymmdd: []const u8, region: []const u8, service: []const u8) Key {
    // kDate uses the "AWS4" prefix concatenated with the secret.
    var seed_buf: [4 + 1024]u8 = undefined; // secrets in practice are well under 1 KiB
    std.debug.assert(secret_key.len <= seed_buf.len - 4);
    @memcpy(seed_buf[0..4], "AWS4");
    @memcpy(seed_buf[4 .. 4 + secret_key.len], secret_key);
    const seed = seed_buf[0 .. 4 + secret_key.len];

    var k_date: Key = undefined;
    HmacSha256.create(&k_date, date_yyyymmdd, seed);

    var k_region: Key = undefined;
    HmacSha256.create(&k_region, region, &k_date);

    var k_service: Key = undefined;
    HmacSha256.create(&k_service, service, &k_region);

    var k_signing: Key = undefined;
    HmacSha256.create(&k_signing, "aws4_request", &k_service);
    return k_signing;
}

/// Compute the final HMAC-SHA256 of `data` keyed by `key`, return as 64
/// lowercase hex bytes.
pub fn signHex(key: Key, data: []const u8) [64]u8 {
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, data, &key);
    return std.fmt.bytesToHex(mac, .lower);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "derive: AWS SigV4 doc example (IAM/us-east-1)" {
    // https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_aws-signing.html
    const k = derive("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam");
    const hex = std.fmt.bytesToHex(k, .lower);
    try testing.expectEqualStrings(
        "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9",
        &hex,
    );
}

test "signHex: returns 64 lowercase hex chars" {
    const k = derive("test-secret", "20260512", "us-east-1", "s3");
    const hex = signHex(k, "hello");
    try testing.expectEqual(@as(usize, 64), hex.len);
    for (hex) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}
