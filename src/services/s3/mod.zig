//! S3 service entry point.
//!
//! M0 returns `NotImplemented` for every request. Subsequent milestones
//! grow the dispatch table from PRD §8.

const std = @import("std");
const router = @import("../../router.zig");
const errors = @import("../../wire/errors.zig");

pub const Result = errors.Code;

pub fn handle(_: router.Parsed, _: []const u8) Result {
    return .not_implemented;
}
