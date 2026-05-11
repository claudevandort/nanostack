//! SigV4 verification — M0 stub.
//!
//! In M0 we accept any signature (or none). M2 ports the canonical
//! request / string-to-sign / signing key flow from `aws-sdk-for-zig`
//! and adds the presigned-URL path.

const std = @import("std");

pub const VerifyError = error{
    SignatureDoesNotMatch,
    InvalidAccessKeyId,
    Malformed,
};

pub const Credentials = struct {
    access_key: []const u8,
    secret_key: []const u8,
};

/// Returns ok unconditionally in M0. Real verification arrives in M2.
pub fn verify(
    _: Credentials,
    _: []const u8, // method
    _: []const u8, // path
    _: []const u8, // query
    _: []const std.http.Header,
    _: []const u8, // body
) VerifyError!void {
    return;
}
