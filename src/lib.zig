//! Library entry point: re-exports modules under test so `zig build test`
//! finds every `test {}` block from one root.

pub const xml = @import("wire/xml.zig");
pub const errors = @import("wire/errors.zig");
pub const s3_responses = @import("wire/s3_responses.zig");
pub const router = @import("router.zig");
pub const sigv4 = @import("auth/sigv4.zig");
pub const iso8601 = @import("auth/iso8601.zig");
pub const signing_key = @import("auth/signing_key.zig");
pub const canonical = @import("auth/canonical.zig");
pub const storage = @import("storage/mod.zig");
pub const storage_util = @import("storage/util.zig");
pub const fs_backend = @import("storage/fs.zig");
pub const mem_backend = @import("storage/mem.zig");
pub const s3 = @import("services/s3/mod.zig");
pub const cli = @import("cli.zig");

test {
    _ = xml;
    _ = errors;
    _ = s3_responses;
    _ = router;
    _ = sigv4;
    _ = iso8601;
    _ = signing_key;
    _ = canonical;
    _ = storage;
    _ = storage_util;
    _ = fs_backend;
    _ = mem_backend;
    _ = s3;
    _ = cli;
}
