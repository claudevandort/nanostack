//! Library entry point: re-exports modules under test so `zig build test`
//! finds every `test {}` block from one root.

pub const xml = @import("wire/xml.zig");
pub const errors = @import("wire/errors.zig");
pub const s3_responses = @import("wire/s3_responses.zig");
pub const object_responses = @import("wire/object_responses.zig");
pub const list_objects = @import("wire/list_objects.zig");
pub const delete_objects_parser = @import("wire/delete_objects_parser.zig");
pub const complete_multipart_parser = @import("wire/complete_multipart_parser.zig");
pub const multipart_responses = @import("wire/multipart_responses.zig");
pub const versioning_config_parser = @import("wire/versioning_config_parser.zig");
pub const versioning_responses = @import("wire/versioning_responses.zig");
pub const list_object_versions = @import("wire/list_object_versions.zig");
pub const tagging_parser = @import("wire/tagging_parser.zig");
pub const tagging_responses = @import("wire/tagging_responses.zig");
pub const router = @import("router.zig");
pub const http_range = @import("http/range.zig");
pub const http_date = @import("http/date.zig");
pub const sigv4 = @import("auth/sigv4.zig");
pub const iso8601 = @import("auth/iso8601.zig");
pub const signing_key = @import("auth/signing_key.zig");
pub const canonical = @import("auth/canonical.zig");
pub const storage = @import("storage/mod.zig");
pub const storage_util = @import("storage/util.zig");
pub const fs_backend = @import("storage/fs.zig");
pub const storage_etag = @import("storage/etag.zig");
pub const s3 = @import("services/s3/mod.zig");
pub const preconditions = @import("services/s3/preconditions.zig");
pub const multipart_service = @import("services/s3/multipart.zig");
pub const versioning_service = @import("services/s3/versioning.zig");
pub const tagging_service = @import("services/s3/tagging.zig");
pub const cli = @import("cli.zig");
pub const version = @import("version.zig");

test {
    _ = xml;
    _ = errors;
    _ = s3_responses;
    _ = object_responses;
    _ = list_objects;
    _ = delete_objects_parser;
    _ = complete_multipart_parser;
    _ = multipart_responses;
    _ = versioning_config_parser;
    _ = versioning_responses;
    _ = list_object_versions;
    _ = tagging_parser;
    _ = tagging_responses;
    _ = router;
    _ = http_range;
    _ = http_date;
    _ = sigv4;
    _ = iso8601;
    _ = signing_key;
    _ = canonical;
    _ = storage;
    _ = storage_util;
    _ = fs_backend;
    _ = storage_etag;
    _ = s3;
    _ = preconditions;
    _ = multipart_service;
    _ = versioning_service;
    _ = tagging_service;
    _ = cli;
    _ = version;
}
