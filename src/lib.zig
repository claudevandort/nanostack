//! Library entry point: re-exports modules under test so `zig build test`
//! finds every `test {}` block from one root.

pub const xml = @import("wire/xml.zig");
pub const errors = @import("wire/errors.zig");
pub const router = @import("router.zig");
pub const sigv4 = @import("auth/sigv4.zig");
pub const storage = @import("storage/mod.zig");
pub const s3 = @import("services/s3/mod.zig");
pub const cli = @import("cli.zig");

test {
    _ = xml;
    _ = errors;
    _ = router;
    _ = sigv4;
    _ = storage;
    _ = s3;
    _ = cli;
}
