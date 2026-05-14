//! AWS-compatible error response builder.
//!
//! Produces the exact XML body, HTTP status, and required header values
//! for any error in the supported catalog. The HTTP server glues these
//! onto its response type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");

pub const Code = enum {
    not_implemented,
    no_such_bucket,
    no_such_key,
    bucket_already_exists,
    bucket_already_owned_by_you,
    bucket_not_empty,
    invalid_bucket_name,
    access_denied,
    invalid_request,
    invalid_argument,
    method_not_allowed,
    signature_does_not_match,
    invalid_access_key_id,
    request_time_too_skewed,
    missing_content_length,
    bad_request,
    bad_digest,
    invalid_range,
    precondition_failed,
    not_modified,
    entity_too_small,
    no_such_upload,
    invalid_part,
    invalid_part_order,
    invalid_tag,
    no_such_tag_set,
    malformed_acl_error,
    malformed_policy,
    no_such_bucket_policy,
    ownership_controls_not_found,
    no_such_public_access_block_configuration,
    access_control_list_not_supported,
    no_such_cors_configuration,
    server_side_encryption_configuration_not_found_error,
    no_such_lifecycle_configuration,
    no_such_website_configuration,
    malformed_xml,
    object_lock_configuration_not_found_error,
    invalid_bucket_state,
    invalid_retention_period,
    replication_configuration_not_found_error,
    internal_error,

    pub fn awsCode(self: Code) []const u8 {
        return switch (self) {
            .not_implemented => "NotImplemented",
            .no_such_bucket => "NoSuchBucket",
            .no_such_key => "NoSuchKey",
            .bucket_already_exists => "BucketAlreadyExists",
            .bucket_already_owned_by_you => "BucketAlreadyOwnedByYou",
            .bucket_not_empty => "BucketNotEmpty",
            .invalid_bucket_name => "InvalidBucketName",
            .access_denied => "AccessDenied",
            .invalid_request => "InvalidRequest",
            .invalid_argument => "InvalidArgument",
            .method_not_allowed => "MethodNotAllowed",
            .signature_does_not_match => "SignatureDoesNotMatch",
            .invalid_access_key_id => "InvalidAccessKeyId",
            .request_time_too_skewed => "RequestTimeTooSkewed",
            .missing_content_length => "MissingContentLength",
            .bad_request => "BadRequest",
            .bad_digest => "BadDigest",
            .invalid_range => "InvalidRange",
            .precondition_failed => "PreconditionFailed",
            .not_modified => "NotModified",
            .entity_too_small => "EntityTooSmall",
            .no_such_upload => "NoSuchUpload",
            .invalid_part => "InvalidPart",
            .invalid_part_order => "InvalidPartOrder",
            .invalid_tag => "InvalidTag",
            .no_such_tag_set => "NoSuchTagSet",
            .malformed_acl_error => "MalformedACLError",
            .malformed_policy => "MalformedPolicy",
            .no_such_bucket_policy => "NoSuchBucketPolicy",
            .ownership_controls_not_found => "OwnershipControlsNotFoundError",
            .no_such_public_access_block_configuration => "NoSuchPublicAccessBlockConfiguration",
            .access_control_list_not_supported => "AccessControlListNotSupported",
            .no_such_cors_configuration => "NoSuchCORSConfiguration",
            .server_side_encryption_configuration_not_found_error => "ServerSideEncryptionConfigurationNotFoundError",
            .no_such_lifecycle_configuration => "NoSuchLifecycleConfiguration",
            .no_such_website_configuration => "NoSuchWebsiteConfiguration",
            .malformed_xml => "MalformedXML",
            .object_lock_configuration_not_found_error => "ObjectLockConfigurationNotFoundError",
            .invalid_bucket_state => "InvalidBucketState",
            .invalid_retention_period => "InvalidRetentionPeriod",
            .replication_configuration_not_found_error => "ReplicationConfigurationNotFoundError",
            .internal_error => "InternalError",
        };
    }

    pub fn defaultMessage(self: Code) []const u8 {
        return switch (self) {
            .not_implemented => "A header you provided implies functionality that is not implemented.",
            .no_such_bucket => "The specified bucket does not exist.",
            .no_such_key => "The specified key does not exist.",
            .bucket_already_exists => "The requested bucket name is not available.",
            .bucket_already_owned_by_you => "Your previous request to create the named bucket succeeded and you already own it.",
            .bucket_not_empty => "The bucket you tried to delete is not empty.",
            .invalid_bucket_name => "The specified bucket is not valid.",
            .access_denied => "Access Denied",
            .invalid_request => "Invalid Request",
            .invalid_argument => "Invalid Argument",
            .method_not_allowed => "The specified method is not allowed against this resource.",
            .signature_does_not_match => "The request signature we calculated does not match the signature you provided.",
            .invalid_access_key_id => "The AWS Access Key Id you provided does not exist in our records.",
            .request_time_too_skewed => "The difference between the request time and the current time is too large.",
            .missing_content_length => "You must provide the Content-Length HTTP header.",
            .bad_request => "Bad Request",
            .bad_digest => "The Content-MD5 you specified did not match what we received.",
            .invalid_range => "The requested range is not satisfiable.",
            .precondition_failed => "At least one of the preconditions you specified did not hold.",
            .not_modified => "Not Modified",
            .entity_too_small => "Your proposed upload is smaller than the minimum allowed object size.",
            .no_such_upload => "The specified multipart upload does not exist. The upload ID may be invalid, or the upload may have been aborted or completed.",
            .invalid_part => "One or more of the specified parts could not be found. The part may not have been uploaded, or the specified entity tag may not match the part's entity tag.",
            .invalid_part_order => "The list of parts was not in ascending order. Parts must be ordered by part number.",
            .invalid_tag => "The tag provided was not a valid tag. This error can occur if the tag did not pass input validation.",
            .no_such_tag_set => "The TagSet does not exist.",
            .malformed_acl_error => "The XML you provided was not well-formed or did not validate against our published schema.",
            .malformed_policy => "Policies must be valid JSON and the first byte must be '{'.",
            .no_such_bucket_policy => "The bucket policy does not exist",
            .ownership_controls_not_found => "The bucket ownership controls were not found",
            .no_such_public_access_block_configuration => "The public access block configuration was not found",
            .access_control_list_not_supported => "The bucket does not allow ACLs.",
            .no_such_cors_configuration => "The CORS configuration does not exist",
            .server_side_encryption_configuration_not_found_error => "The server side encryption configuration was not found",
            .no_such_lifecycle_configuration => "The lifecycle configuration does not exist",
            .no_such_website_configuration => "The specified bucket does not have a website configuration",
            .malformed_xml => "The XML you provided was not well-formed or did not validate against our published schema.",
            .object_lock_configuration_not_found_error => "Object Lock configuration does not exist for this bucket",
            .invalid_bucket_state => "The request is not valid with the current state of the bucket.",
            .invalid_retention_period => "The retention period specified is not valid.",
            .replication_configuration_not_found_error => "The replication configuration was not found",
            .internal_error => "We encountered an internal error. Please try again.",
        };
    }

    pub fn httpStatus(self: Code) u16 {
        return switch (self) {
            .not_implemented => 501,
            .no_such_bucket, .no_such_key => 404,
            .bucket_already_exists, .bucket_already_owned_by_you, .bucket_not_empty => 409,
            .access_denied, .signature_does_not_match, .invalid_access_key_id, .request_time_too_skewed => 403,
            .invalid_request, .invalid_argument, .invalid_bucket_name, .missing_content_length, .bad_request, .bad_digest => 400,
            .invalid_range => 416,
            .precondition_failed => 412,
            .not_modified => 304,
            .entity_too_small => 400,
            .no_such_upload => 404,
            .invalid_part, .invalid_part_order => 400,
            .invalid_tag => 400,
            .no_such_tag_set => 404,
            .malformed_acl_error => 400,
            .malformed_policy => 400,
            .no_such_bucket_policy => 404,
            .ownership_controls_not_found => 404,
            .no_such_public_access_block_configuration => 404,
            .access_control_list_not_supported => 400,
            .no_such_cors_configuration => 404,
            .server_side_encryption_configuration_not_found_error => 404,
            .no_such_lifecycle_configuration => 404,
            .no_such_website_configuration => 404,
            .malformed_xml => 400,
            .object_lock_configuration_not_found_error => 404,
            .invalid_bucket_state => 409,
            .invalid_retention_period => 400,
            .replication_configuration_not_found_error => 404,
            .method_not_allowed => 405,
            .internal_error => 500,
        };
    }
};

pub const Response = struct {
    code: Code,
    /// If null, `code.defaultMessage()` is used.
    message: ?[]const u8 = null,
    request_id: []const u8,
    /// Matches the `x-amz-id-2` header; opaque, can be empty.
    host_id: []const u8 = "",
    /// Typically the request path / bucket / key. Optional in the body.
    resource: ?[]const u8 = null,
};

pub fn renderBody(allocator: Allocator, r: Response) ![]u8 {
    var code_el: xml.Element = .{ .name = "Code", .text = r.code.awsCode() };
    var msg_el: xml.Element = .{ .name = "Message", .text = r.message orelse r.code.defaultMessage() };
    var rid_el: xml.Element = .{ .name = "RequestId", .text = r.request_id };
    var hid_el: xml.Element = .{ .name = "HostId", .text = r.host_id };

    // Inline-build the children array. Resource is optional.
    if (r.resource) |res| {
        var res_el: xml.Element = .{ .name = "Resource", .text = res };
        const err: xml.Element = .{
            .name = "Error",
            .children = &.{
                .{ .element = &code_el },
                .{ .element = &msg_el },
                .{ .element = &res_el },
                .{ .element = &rid_el },
                .{ .element = &hid_el },
            },
        };
        return xml.renderToOwnedSlice(allocator, &err);
    }
    const err: xml.Element = .{
        .name = "Error",
        .children = &.{
            .{ .element = &code_el },
            .{ .element = &msg_el },
            .{ .element = &rid_el },
            .{ .element = &hid_el },
        },
    };
    return xml.renderToOwnedSlice(allocator, &err);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "code metadata" {
    try testing.expectEqualStrings("NotImplemented", Code.not_implemented.awsCode());
    try testing.expectEqual(@as(u16, 501), Code.not_implemented.httpStatus());
    try testing.expectEqualStrings("NoSuchBucket", Code.no_such_bucket.awsCode());
    try testing.expectEqual(@as(u16, 404), Code.no_such_bucket.httpStatus());
    try testing.expectEqual(@as(u16, 403), Code.signature_does_not_match.httpStatus());
}

test "renders NotImplemented body without resource" {
    const body = try renderBody(testing.allocator, .{
        .code = .not_implemented,
        .request_id = "ABCD1234",
        .host_id = "abc/def",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<Error><Code>NotImplemented</Code>" ++
            "<Message>A header you provided implies functionality that is not implemented.</Message>" ++
            "<RequestId>ABCD1234</RequestId>" ++
            "<HostId>abc/def</HostId></Error>",
        body,
    );
}

test "renders NoSuchBucket body with resource and override message" {
    const body = try renderBody(testing.allocator, .{
        .code = .no_such_bucket,
        .message = "custom",
        .request_id = "RID",
        .resource = "/mybucket",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<Error><Code>NoSuchBucket</Code><Message>custom</Message>" ++
            "<Resource>/mybucket</Resource>" ++
            "<RequestId>RID</RequestId><HostId/></Error>",
        body,
    );
}

test "escapes special chars in resource" {
    const body = try renderBody(testing.allocator, .{
        .code = .no_such_key,
        .request_id = "R",
        .resource = "/b/key&<>",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<Error><Code>NoSuchKey</Code>" ++
            "<Message>The specified key does not exist.</Message>" ++
            "<Resource>/b/key&amp;&lt;&gt;</Resource>" ++
            "<RequestId>R</RequestId><HostId/></Error>",
        body,
    );
}
