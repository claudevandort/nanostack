//! Filesystem storage backend.
//!
//! Layout (PRD §9):
//!   <base_dir>/s3/buckets.json                      -- bucket registry
//!   <base_dir>/s3/<bucket>/objects/<key-hash>/data
//!   <base_dir>/s3/<bucket>/objects/<key-hash>/meta.json
//!
//! M1 owns the registry; M3 fills the per-bucket `objects/` directory.
//! Each object lives in its own subdirectory keyed by `sha256(key)` (hex)
//! so we sidestep filesystem path constraints on the user-supplied key.
//! Both `data` and `meta.json` are written atomically (createFileAtomic +
//! replace), and the bucket's sorted in-memory key index is updated under
//! the same mutex.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const storage = @import("mod.zig");
const util = @import("util.zig");
const etag_mod = @import("etag.zig");

const Fs = @This();

const registry_version: u32 = 1;
const default_region = "us-east-1";

const PartMeta = struct {
    part_number: u32,
    size: u64,
    etag: []u8, // quoted MD5
    last_modified_unix: i64,
};

const MultipartState = struct {
    key: []u8,
    content_type: []u8,
    user_metadata: []storage.Header,
    initiated_unix: i64,
    parts: std.AutoHashMap(u32, PartMeta),
    /// M9. Tags applied to the merged object on Complete.
    tags: []storage.Tag = &.{},
    /// M10. ACL applied to the merged object on Complete.
    acl: ?storage.Acl = null,
    /// M12. Object Lock state applied to the merged object on Complete.
    retention_mode: ?storage.RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. SSE applied to the merged object on Complete.
    sse_algorithm: ?storage.SseAlgorithm = null,
    sse_kms_key_id: []u8 = &.{},
    /// Wave 2 (drift #6). Identity captured at CreateMultipartUpload.
    initiator_id: []u8 = &.{},
    initiator_display_name: []u8 = &.{},

    fn deinit(self: *MultipartState, gpa: Allocator) void {
        gpa.free(self.key);
        gpa.free(self.content_type);
        for (self.user_metadata) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.user_metadata);
        var it = self.parts.iterator();
        while (it.next()) |entry| gpa.free(entry.value_ptr.etag);
        self.parts.deinit();
        freeTagsOwned(gpa, self.tags);
        if (self.acl) |a| freeAclOwned(gpa, a);
        if (self.sse_kms_key_id.len > 0) gpa.free(self.sse_kms_key_id);
        if (self.initiator_id.len > 0) gpa.free(self.initiator_id);
        if (self.initiator_display_name.len > 0) gpa.free(self.initiator_display_name);
        self.* = undefined;
    }
};

/// One entry in a versioned key's chain. M8 + M9 tags + M10 acl.
const VersionEntry = struct {
    version_id: []u8, // owned by backend allocator
    is_delete_marker: bool,
    etag: []u8, // includes surrounding quotes; empty for delete markers
    size: u64,
    content_type: []u8, // empty for delete markers
    last_modified_unix: i64,
    user_metadata: []storage.Header,
    /// M9. Per-version tag set.
    tags: []storage.Tag = &.{},
    /// M10. Per-version ACL. `null` means "synthesize default on Get".
    acl: ?storage.Acl = null,
    /// M12. Per-version Object Lock state.
    retention_mode: ?storage.RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. Per-version restore + SSE state.
    restore_in_progress: bool = false,
    restore_expiry_unix: i64 = 0,
    sse_algorithm: ?storage.SseAlgorithm = null,
    sse_kms_key_id: []u8 = &.{},

    fn deinit(self: *VersionEntry, gpa: Allocator) void {
        gpa.free(self.version_id);
        gpa.free(self.etag);
        gpa.free(self.content_type);
        for (self.user_metadata) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.user_metadata);
        freeTagsOwned(gpa, self.tags);
        if (self.acl) |a| freeAclOwned(gpa, a);
        if (self.sse_kms_key_id.len > 0) gpa.free(self.sse_kms_key_id);
        self.* = undefined;
    }
};

/// Per-key chain. Sorted newest-first (index 0 is the current version).
const VersionChain = std.ArrayList(VersionEntry);

const BucketSlot = struct {
    meta: storage.Bucket,
    /// Sorted in-memory view of all keys present in this bucket. Mutated
    /// on every PutObject / DeleteObject so M4 ListObjects can read it
    /// directly without an FS walk. For versioned buckets, a key is in
    /// the index iff its chain has a non-delete-marker entry visible.
    key_index: std.ArrayList([]const u8),
    /// Keyed by upload_id (owned). M6.
    uploads: std.StringHashMap(MultipartState),
    /// Bucket versioning state. M8.
    versioning_status: storage.VersioningStatus = .none,
    /// Per-key version chain. Keys are owned strings duped from the
    /// caller's key on first insert. Only populated when versioning has
    /// ever been enabled on this bucket.
    versions: std.StringHashMap(VersionChain),
    /// Bucket-level tag set (M9). Empty means "no TagSet"; GetBucketTagging
    /// returns 404 NoSuchTagSet in that case.
    tags: []storage.Tag = &.{},
    /// Bucket-level ACL (M10). `null` means "synthesize default on Get".
    acl: ?storage.Acl = null,
    /// Bucket policy JSON bytes (M10). `null` → 404 NoSuchBucketPolicy.
    policy_json: ?[]u8 = null,
    /// Bucket ownership controls (M10). `null` → 404
    /// OwnershipControlsNotFoundError.
    ownership_controls: ?storage.OwnershipControl = null,
    /// Bucket public access block configuration (M10). `null` → 404
    /// NoSuchPublicAccessBlockConfiguration.
    public_access_block: ?storage.PublicAccessBlockConfig = null,
    /// CORS config (M11). `null` → 404 NoSuchCORSConfiguration.
    cors: ?storage.CorsConfig = null,
    /// Encryption config (M11). `null` → 404 ServerSideEncryptionConfigurationNotFoundError.
    encryption: ?storage.EncryptionConfig = null,
    /// Lifecycle config (M11). `null` → 404 NoSuchLifecycleConfiguration.
    lifecycle: ?storage.LifecycleConfig = null,
    /// Notification config (M11). `null` → return empty config (AWS-exact);
    /// no 404 for this one.
    notification: ?storage.NotificationConfig = null,
    /// Website config (M11). `null` → 404 NoSuchWebsiteConfiguration.
    website: ?storage.WebsiteConfig = null,
    /// Object Lock enabled (M12). Set at CreateBucket via the
    /// `x-amz-bucket-object-lock-enabled` header; immutable after creation.
    object_lock_enabled: bool = false,
    /// Object Lock config (M12). `null` when not yet PutObjectLockConfig'd.
    /// `getObjectLockConfig` returns the empty-Rule config (Enabled=true,
    /// no default retention) when locked but unset, and 404 when not locked.
    object_lock_config: ?storage.ObjectLockConfig = null,
    /// Replication config (M13). `null` → 404 ReplicationConfigurationNotFoundError.
    replication: ?storage.ReplicationConfig = null,

    fn deinit(self: *BucketSlot, gpa: Allocator) void {
        gpa.free(self.meta.name);
        gpa.free(self.meta.region);
        for (self.key_index.items) |k| gpa.free(k);
        self.key_index.deinit(gpa);
        var it = self.uploads.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            var st = entry.value_ptr.*;
            st.deinit(gpa);
        }
        self.uploads.deinit();
        var vit = self.versions.iterator();
        while (vit.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            var chain = entry.value_ptr.*;
            for (chain.items) |*v| v.deinit(gpa);
            chain.deinit(gpa);
        }
        self.versions.deinit();
        freeTagsOwned(gpa, self.tags);
        if (self.acl) |a| freeAclOwned(gpa, a);
        if (self.policy_json) |p| gpa.free(p);
        if (self.cors) |c| freeCorsConfig(gpa, c);
        if (self.encryption) |c| freeEncryptionConfig(gpa, c);
        if (self.lifecycle) |c| freeLifecycleConfig(gpa, c);
        if (self.notification) |c| freeNotificationConfig(gpa, c);
        if (self.website) |c| freeWebsiteConfig(gpa, c);
        if (self.object_lock_config) |_| {}  // No owned strings in this config.
        if (self.replication) |c| freeReplicationConfig(gpa, c);
        self.* = undefined;
    }
};

/// Free a tag set whose keys and values were duped with the given allocator.
fn freeTagsOwned(gpa: Allocator, tags: []storage.Tag) void {
    for (tags) |t| {
        gpa.free(t.key);
        gpa.free(t.value);
    }
    gpa.free(tags);
}

/// Dupe an arbitrary tag set into `gpa`-owned strings + slice.
fn dupeTagsOwned(gpa: Allocator, src: []const storage.Tag) ![]storage.Tag {
    const out = try gpa.alloc(storage.Tag, src.len);
    errdefer gpa.free(out);
    var made: usize = 0;
    errdefer for (out[0..made]) |t| {
        gpa.free(t.key);
        gpa.free(t.value);
    };
    for (src) |t| {
        out[made] = .{
            .key = try gpa.dupe(u8, t.key),
            .value = try gpa.dupe(u8, t.value),
        };
        made += 1;
    }
    return out;
}

/// Free an ACL whose owner + grant strings were duped with the given
/// allocator.
fn freeAclOwned(gpa: Allocator, acl: storage.Acl) void {
    gpa.free(acl.owner.id);
    gpa.free(acl.owner.display_name);
    for (acl.grants) |g| {
        gpa.free(g.grantee.id);
        gpa.free(g.grantee.display_name);
        gpa.free(g.grantee.uri);
        gpa.free(g.grantee.email_address);
    }
    gpa.free(acl.grants);
}

/// Dupe an ACL into `gpa`-owned strings + slice.
fn dupeAclOwned(gpa: Allocator, src: storage.Acl) !storage.Acl {
    const owner_id = try gpa.dupe(u8, src.owner.id);
    errdefer gpa.free(owner_id);
    const owner_dn = try gpa.dupe(u8, src.owner.display_name);
    errdefer gpa.free(owner_dn);

    const grants = try gpa.alloc(storage.Grant, src.grants.len);
    errdefer gpa.free(grants);
    var made: usize = 0;
    errdefer for (grants[0..made]) |g| {
        gpa.free(g.grantee.id);
        gpa.free(g.grantee.display_name);
        gpa.free(g.grantee.uri);
        gpa.free(g.grantee.email_address);
    };
    for (src.grants) |g| {
        const gid = try gpa.dupe(u8, g.grantee.id);
        errdefer gpa.free(gid);
        const gdn = try gpa.dupe(u8, g.grantee.display_name);
        errdefer gpa.free(gdn);
        const guri = try gpa.dupe(u8, g.grantee.uri);
        errdefer gpa.free(guri);
        const gemail = try gpa.dupe(u8, g.grantee.email_address);
        grants[made] = .{
            .grantee = .{
                .kind = g.grantee.kind,
                .id = gid,
                .display_name = gdn,
                .uri = guri,
                .email_address = gemail,
            },
            .permission = g.permission,
        };
        made += 1;
    }
    return .{
        .owner = .{ .id = owner_id, .display_name = owner_dn },
        .grants = grants,
    };
}

/// Synthesize the default "private" ACL (Owner FULL_CONTROL) into
/// `allocator`-owned memory.
pub fn defaultAcl(allocator: Allocator) !storage.Acl {
    const owner_id = try allocator.dupe(u8, storage.default_owner_id);
    errdefer allocator.free(owner_id);
    const owner_dn = try allocator.dupe(u8, storage.default_owner_display_name);
    errdefer allocator.free(owner_dn);

    const grants = try allocator.alloc(storage.Grant, 1);
    errdefer allocator.free(grants);
    const gid = try allocator.dupe(u8, storage.default_owner_id);
    errdefer allocator.free(gid);
    const gdn = try allocator.dupe(u8, storage.default_owner_display_name);
    errdefer allocator.free(gdn);
    const guri = try allocator.dupe(u8, "");
    errdefer allocator.free(guri);
    const gemail = try allocator.dupe(u8, "");

    grants[0] = .{
        .grantee = .{
            .kind = .canonical_user,
            .id = gid,
            .display_name = gdn,
            .uri = guri,
            .email_address = gemail,
        },
        .permission = .FULL_CONTROL,
    };
    return .{
        .owner = .{ .id = owner_id, .display_name = owner_dn },
        .grants = grants,
    };
}

// ---------------------------------------------------------------------------
// M11 bucket-config dupe/free helpers. Each config gets a deep dupe into
// `gpa`-owned memory + a matching free routine.

fn dupeStringList(gpa: Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, src.len);
    errdefer gpa.free(out);
    var made: usize = 0;
    errdefer for (out[0..made]) |s| gpa.free(s);
    for (src) |s| {
        out[made] = try gpa.dupe(u8, s);
        made += 1;
    }
    return out;
}

fn freeStringList(gpa: Allocator, items: []const []const u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

// CORS
fn dupeCorsConfig(gpa: Allocator, src: storage.CorsConfig) !storage.CorsConfig {
    const rules = try gpa.alloc(storage.CorsRule, src.rules.len);
    errdefer gpa.free(rules);
    var made: usize = 0;
    errdefer for (rules[0..made]) |r| freeCorsRule(gpa, r);
    for (src.rules) |r| {
        const methods = try gpa.dupe(storage.HttpMethod, r.allowed_methods);
        errdefer gpa.free(methods);
        const origins = try dupeStringList(gpa, r.allowed_origins);
        errdefer freeStringList(gpa, origins);
        const headers = try dupeStringList(gpa, r.allowed_headers);
        errdefer freeStringList(gpa, headers);
        const expose = try dupeStringList(gpa, r.expose_headers);
        errdefer freeStringList(gpa, expose);
        const id_dup = try gpa.dupe(u8, r.id);
        rules[made] = .{
            .id = id_dup,
            .allowed_methods = methods,
            .allowed_origins = origins,
            .allowed_headers = headers,
            .expose_headers = expose,
            .max_age_seconds = r.max_age_seconds,
        };
        made += 1;
    }
    return .{ .rules = rules };
}

fn freeCorsRule(gpa: Allocator, r: storage.CorsRule) void {
    gpa.free(r.id);
    gpa.free(r.allowed_methods);
    freeStringList(gpa, r.allowed_origins);
    freeStringList(gpa, r.allowed_headers);
    freeStringList(gpa, r.expose_headers);
}

fn freeCorsConfig(gpa: Allocator, cfg: storage.CorsConfig) void {
    for (cfg.rules) |r| freeCorsRule(gpa, r);
    gpa.free(cfg.rules);
}

// Encryption
fn dupeEncryptionConfig(gpa: Allocator, src: storage.EncryptionConfig) !storage.EncryptionConfig {
    const rules = try gpa.alloc(storage.EncryptionRule, src.rules.len);
    errdefer gpa.free(rules);
    var made: usize = 0;
    errdefer for (rules[0..made]) |r| freeEncryptionRule(gpa, r);
    for (src.rules) |r| {
        var apply_dup: ?storage.SseByDefault = null;
        if (r.apply) |a| {
            apply_dup = .{
                .sse_algorithm = a.sse_algorithm,
                .kms_master_key_id = try gpa.dupe(u8, a.kms_master_key_id),
            };
        }
        rules[made] = .{
            .apply = apply_dup,
            .bucket_key_enabled = r.bucket_key_enabled,
        };
        made += 1;
    }
    return .{ .rules = rules };
}

fn freeEncryptionRule(gpa: Allocator, r: storage.EncryptionRule) void {
    if (r.apply) |a| gpa.free(a.kms_master_key_id);
}

fn freeEncryptionConfig(gpa: Allocator, cfg: storage.EncryptionConfig) void {
    for (cfg.rules) |r| freeEncryptionRule(gpa, r);
    gpa.free(cfg.rules);
}

// Lifecycle
fn dupeTransition(gpa: Allocator, t: storage.Transition) !storage.Transition {
    return .{
        .days = t.days,
        .date_iso8601 = try gpa.dupe(u8, t.date_iso8601),
        .storage_class = t.storage_class,
    };
}

fn freeTransition(gpa: Allocator, t: storage.Transition) void {
    gpa.free(t.date_iso8601);
}

fn dupeExpiration(gpa: Allocator, e: storage.Expiration) !storage.Expiration {
    return .{
        .days = e.days,
        .date_iso8601 = try gpa.dupe(u8, e.date_iso8601),
        .expired_object_delete_marker = e.expired_object_delete_marker,
    };
}

fn freeExpiration(gpa: Allocator, e: storage.Expiration) void {
    gpa.free(e.date_iso8601);
}

fn dupeLifecycleFilter(gpa: Allocator, f: storage.LifecycleFilter) !storage.LifecycleFilter {
    var tag_dup: ?storage.Tag = null;
    if (f.tag) |t| {
        tag_dup = .{
            .key = try gpa.dupe(u8, t.key),
            .value = try gpa.dupe(u8, t.value),
        };
    }
    return .{
        .prefix = try gpa.dupe(u8, f.prefix),
        .tag = tag_dup,
        .object_size_greater_than = f.object_size_greater_than,
        .object_size_less_than = f.object_size_less_than,
    };
}

fn freeLifecycleFilter(gpa: Allocator, f: storage.LifecycleFilter) void {
    gpa.free(f.prefix);
    if (f.tag) |t| {
        gpa.free(t.key);
        gpa.free(t.value);
    }
}

fn dupeTransitionList(gpa: Allocator, src: []const storage.Transition) ![]const storage.Transition {
    const out = try gpa.alloc(storage.Transition, src.len);
    errdefer gpa.free(out);
    var made: usize = 0;
    errdefer for (out[0..made]) |t| freeTransition(gpa, t);
    for (src) |t| {
        out[made] = try dupeTransition(gpa, t);
        made += 1;
    }
    return out;
}

fn freeTransitionList(gpa: Allocator, ts: []const storage.Transition) void {
    for (ts) |t| freeTransition(gpa, t);
    gpa.free(ts);
}

fn dupeLifecycleRule(gpa: Allocator, r: storage.LifecycleRule) !storage.LifecycleRule {
    var filter_dup: ?storage.LifecycleFilter = null;
    if (r.filter) |f| filter_dup = try dupeLifecycleFilter(gpa, f);
    errdefer if (filter_dup) |f| freeLifecycleFilter(gpa, f);
    var exp_dup: ?storage.Expiration = null;
    if (r.expiration) |e| exp_dup = try dupeExpiration(gpa, e);
    errdefer if (exp_dup) |e| freeExpiration(gpa, e);
    var ncve_dup: ?storage.Expiration = null;
    if (r.noncurrent_version_expiration) |e| ncve_dup = try dupeExpiration(gpa, e);
    errdefer if (ncve_dup) |e| freeExpiration(gpa, e);
    return .{
        .id = try gpa.dupe(u8, r.id),
        .status = r.status,
        .filter = filter_dup,
        .prefix = try gpa.dupe(u8, r.prefix),
        .transitions = try dupeTransitionList(gpa, r.transitions),
        .expiration = exp_dup,
        .noncurrent_version_transitions = try dupeTransitionList(gpa, r.noncurrent_version_transitions),
        .noncurrent_version_expiration = ncve_dup,
        .abort_incomplete_multipart_upload_days = r.abort_incomplete_multipart_upload_days,
    };
}

fn freeLifecycleRule(gpa: Allocator, r: storage.LifecycleRule) void {
    gpa.free(r.id);
    gpa.free(r.prefix);
    if (r.filter) |f| freeLifecycleFilter(gpa, f);
    freeTransitionList(gpa, r.transitions);
    if (r.expiration) |e| freeExpiration(gpa, e);
    freeTransitionList(gpa, r.noncurrent_version_transitions);
    if (r.noncurrent_version_expiration) |e| freeExpiration(gpa, e);
}

fn dupeLifecycleConfig(gpa: Allocator, src: storage.LifecycleConfig) !storage.LifecycleConfig {
    const rules = try gpa.alloc(storage.LifecycleRule, src.rules.len);
    errdefer gpa.free(rules);
    var made: usize = 0;
    errdefer for (rules[0..made]) |r| freeLifecycleRule(gpa, r);
    for (src.rules) |r| {
        rules[made] = try dupeLifecycleRule(gpa, r);
        made += 1;
    }
    return .{ .rules = rules };
}

fn freeLifecycleConfig(gpa: Allocator, cfg: storage.LifecycleConfig) void {
    for (cfg.rules) |r| freeLifecycleRule(gpa, r);
    gpa.free(cfg.rules);
}

// Notifications
fn dupeNotificationFilter(gpa: Allocator, f: storage.NotificationFilter) !storage.NotificationFilter {
    const rules = try gpa.alloc(storage.NotificationFilterRule, f.filter_rules.len);
    errdefer gpa.free(rules);
    var made: usize = 0;
    errdefer for (rules[0..made]) |r| {
        gpa.free(r.name);
        gpa.free(r.value);
    };
    for (f.filter_rules) |r| {
        rules[made] = .{
            .name = try gpa.dupe(u8, r.name),
            .value = try gpa.dupe(u8, r.value),
        };
        made += 1;
    }
    return .{ .filter_rules = rules };
}

fn freeNotificationFilter(gpa: Allocator, f: storage.NotificationFilter) void {
    for (f.filter_rules) |r| {
        gpa.free(r.name);
        gpa.free(r.value);
    }
    gpa.free(f.filter_rules);
}

fn dupeNotificationEntry(gpa: Allocator, e: storage.NotificationConfigEntry) !storage.NotificationConfigEntry {
    var filter_dup: ?storage.NotificationFilter = null;
    if (e.filter) |f| filter_dup = try dupeNotificationFilter(gpa, f);
    errdefer if (filter_dup) |f| freeNotificationFilter(gpa, f);
    const events = try gpa.dupe(storage.S3EventName, e.events);
    errdefer gpa.free(events);
    return .{
        .target = e.target,
        .id = try gpa.dupe(u8, e.id),
        .arn = try gpa.dupe(u8, e.arn),
        .events = events,
        .filter = filter_dup,
    };
}

fn freeNotificationEntry(gpa: Allocator, e: storage.NotificationConfigEntry) void {
    gpa.free(e.id);
    gpa.free(e.arn);
    gpa.free(e.events);
    if (e.filter) |f| freeNotificationFilter(gpa, f);
}

fn dupeNotificationConfig(gpa: Allocator, src: storage.NotificationConfig) !storage.NotificationConfig {
    const entries = try gpa.alloc(storage.NotificationConfigEntry, src.entries.len);
    errdefer gpa.free(entries);
    var made: usize = 0;
    errdefer for (entries[0..made]) |e| freeNotificationEntry(gpa, e);
    for (src.entries) |e| {
        entries[made] = try dupeNotificationEntry(gpa, e);
        made += 1;
    }
    return .{ .entries = entries };
}

fn freeNotificationConfig(gpa: Allocator, cfg: storage.NotificationConfig) void {
    for (cfg.entries) |e| freeNotificationEntry(gpa, e);
    gpa.free(cfg.entries);
}

// Website
fn dupeRoutingRule(gpa: Allocator, r: storage.RoutingRule) !storage.RoutingRule {
    var cond_dup: ?storage.RoutingCondition = null;
    if (r.condition) |c| {
        cond_dup = .{
            .key_prefix_equals = try gpa.dupe(u8, c.key_prefix_equals),
            .http_error_code_returned_equals = try gpa.dupe(u8, c.http_error_code_returned_equals),
        };
    }
    errdefer if (cond_dup) |c| {
        gpa.free(c.key_prefix_equals);
        gpa.free(c.http_error_code_returned_equals);
    };
    return .{
        .condition = cond_dup,
        .redirect = .{
            .host_name = try gpa.dupe(u8, r.redirect.host_name),
            .http_redirect_code = try gpa.dupe(u8, r.redirect.http_redirect_code),
            .protocol = r.redirect.protocol,
            .replace_key_prefix_with = try gpa.dupe(u8, r.redirect.replace_key_prefix_with),
            .replace_key_with = try gpa.dupe(u8, r.redirect.replace_key_with),
        },
    };
}

fn freeRoutingRule(gpa: Allocator, r: storage.RoutingRule) void {
    if (r.condition) |c| {
        gpa.free(c.key_prefix_equals);
        gpa.free(c.http_error_code_returned_equals);
    }
    gpa.free(r.redirect.host_name);
    gpa.free(r.redirect.http_redirect_code);
    gpa.free(r.redirect.replace_key_prefix_with);
    gpa.free(r.redirect.replace_key_with);
}

fn dupeWebsiteConfig(gpa: Allocator, src: storage.WebsiteConfig) !storage.WebsiteConfig {
    var redirect_all_dup: ?storage.RedirectAllRequestsTo = null;
    if (src.redirect_all) |r| {
        redirect_all_dup = .{
            .host_name = try gpa.dupe(u8, r.host_name),
            .protocol = r.protocol,
        };
    }
    errdefer if (redirect_all_dup) |r| gpa.free(r.host_name);
    var idx_dup: ?storage.IndexDocument = null;
    if (src.index_document) |i| idx_dup = .{ .suffix = try gpa.dupe(u8, i.suffix) };
    errdefer if (idx_dup) |i| gpa.free(i.suffix);
    var err_dup: ?storage.ErrorDocument = null;
    if (src.error_document) |e| err_dup = .{ .key = try gpa.dupe(u8, e.key) };
    errdefer if (err_dup) |e| gpa.free(e.key);
    const rules = try gpa.alloc(storage.RoutingRule, src.routing_rules.len);
    errdefer gpa.free(rules);
    var made: usize = 0;
    errdefer for (rules[0..made]) |r| freeRoutingRule(gpa, r);
    for (src.routing_rules) |r| {
        rules[made] = try dupeRoutingRule(gpa, r);
        made += 1;
    }
    return .{
        .redirect_all = redirect_all_dup,
        .index_document = idx_dup,
        .error_document = err_dup,
        .routing_rules = rules,
    };
}

fn freeWebsiteConfig(gpa: Allocator, cfg: storage.WebsiteConfig) void {
    if (cfg.redirect_all) |r| gpa.free(r.host_name);
    if (cfg.index_document) |i| gpa.free(i.suffix);
    if (cfg.error_document) |e| gpa.free(e.key);
    for (cfg.routing_rules) |r| freeRoutingRule(gpa, r);
    gpa.free(cfg.routing_rules);
}

// Replication (M13)
fn dupeReplicationRule(gpa: Allocator, r: storage.ReplicationRule) !storage.ReplicationRule {
    return .{
        .id = try gpa.dupe(u8, r.id),
        .status = r.status,
        .prefix = try gpa.dupe(u8, r.prefix),
        .destination = .{
            .bucket = try gpa.dupe(u8, r.destination.bucket),
            .storage_class = try gpa.dupe(u8, r.destination.storage_class),
        },
    };
}

fn freeReplicationRule(gpa: Allocator, r: storage.ReplicationRule) void {
    gpa.free(r.id);
    gpa.free(r.prefix);
    gpa.free(r.destination.bucket);
    gpa.free(r.destination.storage_class);
}

fn dupeReplicationConfig(gpa: Allocator, src: storage.ReplicationConfig) !storage.ReplicationConfig {
    const role = try gpa.dupe(u8, src.role);
    errdefer gpa.free(role);
    const rules = try gpa.alloc(storage.ReplicationRule, src.rules.len);
    errdefer gpa.free(rules);
    var made: usize = 0;
    errdefer for (rules[0..made]) |r| freeReplicationRule(gpa, r);
    for (src.rules) |r| {
        rules[made] = try dupeReplicationRule(gpa, r);
        made += 1;
    }
    return .{ .role = role, .rules = rules };
}

fn freeReplicationConfig(gpa: Allocator, cfg: storage.ReplicationConfig) void {
    gpa.free(cfg.role);
    for (cfg.rules) |r| freeReplicationRule(gpa, r);
    gpa.free(cfg.rules);
}

allocator: Allocator,
io: Io,
base_dir: []u8,
mutex: Io.Mutex,
buckets: std.ArrayList(BucketSlot),
/// In-memory set of "already restored" object keys, formatted as
/// `"<bucket>/<key>/<version_id?>"`. Lost on restart by design — restore
/// state is observable only within a single nanostack session for the
/// 200-vs-202 distinction on RestoreObject (drift #21).
restored_objects: std.StringHashMapUnmanaged(void),
/// DynamoDB table metadata, in-memory. Keys are the table name (owned
/// by the slot itself). Values are heap-allocated `TableSlot`s persisted
/// at `<base>/dynamodb/tables/<name>/schema.json`. Lock via `mutex` for
/// any mutation.
dynamo_tables: std.StringHashMapUnmanaged(*storage.TableSlot),

pub const InitError = error{
    OutOfMemory,
    Io,
};

pub fn init(allocator: Allocator, io: Io, base_dir: []const u8) InitError!*Fs {
    const self = try allocator.create(Fs);
    errdefer allocator.destroy(self);

    const base_owned = try allocator.dupe(u8, base_dir);
    errdefer allocator.free(base_owned);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .base_dir = base_owned,
        .mutex = .init,
        .buckets = .empty,
        .restored_objects = .empty,
        .dynamo_tables = .empty,
    };

    ensureS3Dir(self) catch return InitError.Io;
    loadRegistry(self) catch return InitError.Io;
    ensureDynamoDir(self) catch return InitError.Io;
    loadDynamoTables(self) catch return InitError.Io;
    return self;
}

pub fn deinit(self: *Fs) void {
    for (self.buckets.items) |*b| b.deinit(self.allocator);
    self.buckets.deinit(self.allocator);
    {
        var it = self.restored_objects.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.restored_objects.deinit(self.allocator);
    }
    {
        var it = self.dynamo_tables.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.dynamo_tables.deinit(self.allocator);
    }
    self.allocator.free(self.base_dir);
    self.allocator.destroy(self);
}

pub fn backend(self: *Fs) storage.Backend {
    return .{ .ctx = self, .vtable = &vtable };
}

/// DynamoDB-flavoured view of the same `Fs` (M15). Persistence path is
/// `<data_dir>/profiles/<profile>/dynamodb/...`, parallel to S3's
/// `s3/...`. Phase-1 stub returns an empty table list.
pub fn dynamoBackend(self: *Fs) storage.DynamoBackend {
    return .{ .ctx = self, .vtable = &dynamo_vtable };
}

const dynamo_vtable: storage.DynamoBackend.VTable = .{
    .listTables = vtDdbListTables,
    .createTable = vtDdbCreateTable,
    .describeTable = vtDdbDescribeTable,
    .deleteTable = vtDdbDeleteTable,
    .updateTable = vtDdbUpdateTable,
};

fn vtDdbListTables(ctx: *anyopaque, allocator: Allocator) storage.Error![]const []const u8 {
    return ddbListTables(@ptrCast(@alignCast(ctx)), allocator);
}
fn vtDdbCreateTable(ctx: *anyopaque, in: storage.CreateTableInput) storage.Error!void {
    return ddbCreateTable(@ptrCast(@alignCast(ctx)), in);
}
fn vtDdbDescribeTable(ctx: *anyopaque, name: []const u8) storage.Error!*const storage.TableSlot {
    return ddbDescribeTable(@ptrCast(@alignCast(ctx)), name);
}
fn vtDdbDeleteTable(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return ddbDeleteTable(@ptrCast(@alignCast(ctx)), name);
}
fn vtDdbUpdateTable(ctx: *anyopaque, in: storage.UpdateTableInput) storage.Error!*const storage.TableSlot {
    return ddbUpdateTable(@ptrCast(@alignCast(ctx)), in);
}

// ---------------------------------------------------------------------------
// VTable thunks

const vtable: storage.Backend.VTable = .{
    .createBucket = vtCreateBucket,
    .deleteBucket = vtDeleteBucket,
    .headBucket = vtHeadBucket,
    .listBuckets = vtListBuckets,
    .putObject = vtPutObject,
    .getObject = vtGetObject,
    .headObject = vtHeadObject,
    .deleteObject = vtDeleteObject,
    .listObjects = vtListObjects,
    .initiateMultipartUpload = vtInitiateMultipartUpload,
    .uploadPart = vtUploadPart,
    .completeMultipartUpload = vtCompleteMultipartUpload,
    .abortMultipartUpload = vtAbortMultipartUpload,
    .listMultipartUploads = vtListMultipartUploads,
    .listParts = vtListParts,
    .getBucketVersioning = vtGetBucketVersioning,
    .putBucketVersioning = vtPutBucketVersioning,
    .listObjectVersions = vtListObjectVersions,
    .putBucketTagging = vtPutBucketTagging,
    .getBucketTagging = vtGetBucketTagging,
    .deleteBucketTagging = vtDeleteBucketTagging,
    .putObjectTagging = vtPutObjectTagging,
    .getObjectTagging = vtGetObjectTagging,
    .deleteObjectTagging = vtDeleteObjectTagging,
    .putBucketAcl = vtPutBucketAcl,
    .getBucketAcl = vtGetBucketAcl,
    .putObjectAcl = vtPutObjectAcl,
    .getObjectAcl = vtGetObjectAcl,
    .putBucketPolicy = vtPutBucketPolicy,
    .getBucketPolicy = vtGetBucketPolicy,
    .deleteBucketPolicy = vtDeleteBucketPolicy,
    .putBucketOwnershipControls = vtPutBucketOwnershipControls,
    .getBucketOwnershipControls = vtGetBucketOwnershipControls,
    .deleteBucketOwnershipControls = vtDeleteBucketOwnershipControls,
    .putPublicAccessBlock = vtPutPublicAccessBlock,
    .getPublicAccessBlock = vtGetPublicAccessBlock,
    .deletePublicAccessBlock = vtDeletePublicAccessBlock,
    .putBucketCors = vtPutBucketCors,
    .getBucketCors = vtGetBucketCors,
    .deleteBucketCors = vtDeleteBucketCors,
    .putBucketEncryption = vtPutBucketEncryption,
    .getBucketEncryption = vtGetBucketEncryption,
    .deleteBucketEncryption = vtDeleteBucketEncryption,
    .putBucketLifecycle = vtPutBucketLifecycle,
    .getBucketLifecycle = vtGetBucketLifecycle,
    .deleteBucketLifecycle = vtDeleteBucketLifecycle,
    .putBucketNotification = vtPutBucketNotification,
    .getBucketNotification = vtGetBucketNotification,
    .putBucketWebsite = vtPutBucketWebsite,
    .getBucketWebsite = vtGetBucketWebsite,
    .deleteBucketWebsite = vtDeleteBucketWebsite,
    .putObjectLockConfig = vtPutObjectLockConfig,
    .getObjectLockConfig = vtGetObjectLockConfig,
    .putObjectRetention = vtPutObjectRetention,
    .getObjectRetention = vtGetObjectRetention,
    .putObjectLegalHold = vtPutObjectLegalHold,
    .getObjectLegalHold = vtGetObjectLegalHold,
    .restoreObject = vtRestoreObject,
    .updateObjectEncryption = vtUpdateObjectEncryption,
    .putBucketReplication = vtPutBucketReplication,
    .getBucketReplication = vtGetBucketReplication,
    .deleteBucketReplication = vtDeleteBucketReplication,
};

fn vtCreateBucket(ctx: *anyopaque, in: storage.CreateBucketInput) storage.Error!void {
    return createBucket(@ptrCast(@alignCast(ctx)), in);
}
fn vtDeleteBucket(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return deleteBucket(@ptrCast(@alignCast(ctx)), name);
}
fn vtHeadBucket(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return headBucket(@ptrCast(@alignCast(ctx)), name);
}
fn vtListBuckets(ctx: *anyopaque, allocator: Allocator) storage.Error![]storage.Bucket {
    return listBuckets(@ptrCast(@alignCast(ctx)), allocator);
}
fn vtPutObject(ctx: *anyopaque, in: storage.PutObjectInput) storage.Error!storage.PutObjectOutput {
    return putObject(@ptrCast(@alignCast(ctx)), in);
}
fn vtGetObject(ctx: *anyopaque, allocator: Allocator, in: storage.GetObjectInput) storage.Error!storage.GetObjectOutput {
    return getObject(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtHeadObject(ctx: *anyopaque, allocator: Allocator, in: storage.HeadObjectInput) storage.Error!storage.Object {
    return headObject(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDeleteObject(ctx: *anyopaque, in: storage.DeleteObjectInput) storage.Error!storage.DeleteObjectOutput {
    return deleteObject(@ptrCast(@alignCast(ctx)), in);
}
fn vtListObjects(ctx: *anyopaque, allocator: Allocator, in: storage.ListObjectsInput) storage.Error!storage.ListObjectsOutput {
    return listObjects(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtInitiateMultipartUpload(ctx: *anyopaque, allocator: Allocator, in: storage.InitiateMultipartUploadInput) storage.Error!storage.InitiateMultipartUploadOutput {
    return initiateMultipartUpload(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtUploadPart(ctx: *anyopaque, in: storage.UploadPartInput) storage.Error!storage.UploadPartOutput {
    return uploadPart(@ptrCast(@alignCast(ctx)), in);
}
fn vtCompleteMultipartUpload(ctx: *anyopaque, allocator: Allocator, in: storage.CompleteMultipartUploadInput) storage.Error!storage.CompleteMultipartUploadOutput {
    return completeMultipartUpload(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtAbortMultipartUpload(ctx: *anyopaque, bucket: []const u8, key: []const u8, upload_id: []const u8) storage.Error!void {
    return abortMultipartUpload(@ptrCast(@alignCast(ctx)), bucket, key, upload_id);
}
fn vtListMultipartUploads(ctx: *anyopaque, allocator: Allocator, in: storage.ListMultipartUploadsInput) storage.Error!storage.ListMultipartUploadsOutput {
    return listMultipartUploads(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtListParts(ctx: *anyopaque, allocator: Allocator, in: storage.ListPartsInput) storage.Error!storage.ListPartsOutput {
    return listParts(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtGetBucketVersioning(ctx: *anyopaque, bucket: []const u8) storage.Error!storage.VersioningStatus {
    return getBucketVersioning(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutBucketVersioning(ctx: *anyopaque, bucket: []const u8, status: storage.VersioningStatus) storage.Error!void {
    return putBucketVersioning(@ptrCast(@alignCast(ctx)), bucket, status);
}
fn vtListObjectVersions(ctx: *anyopaque, allocator: Allocator, in: storage.ListObjectVersionsInput) storage.Error!storage.ListObjectVersionsOutput {
    return listObjectVersions(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtPutBucketTagging(ctx: *anyopaque, bucket: []const u8, tags: []const storage.Tag) storage.Error!void {
    return putBucketTagging(@ptrCast(@alignCast(ctx)), bucket, tags);
}
fn vtGetBucketTagging(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error![]storage.Tag {
    return getBucketTagging(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtDeleteBucketTagging(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketTagging(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutObjectTagging(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, tags: []const storage.Tag) storage.Error!void {
    return putObjectTagging(@ptrCast(@alignCast(ctx)), bucket, key, version_id, tags);
}
fn vtGetObjectTagging(ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error![]storage.Tag {
    return getObjectTagging(@ptrCast(@alignCast(ctx)), allocator, bucket, key, version_id);
}
fn vtDeleteObjectTagging(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!void {
    return deleteObjectTagging(@ptrCast(@alignCast(ctx)), bucket, key, version_id);
}
fn vtPutBucketAcl(ctx: *anyopaque, bucket: []const u8, acl: storage.Acl) storage.Error!void {
    return putBucketAcl(@ptrCast(@alignCast(ctx)), bucket, acl);
}
fn vtGetBucketAcl(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.Acl {
    return getBucketAcl(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtPutObjectAcl(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, acl: storage.Acl) storage.Error!void {
    return putObjectAcl(@ptrCast(@alignCast(ctx)), bucket, key, version_id, acl);
}
fn vtGetObjectAcl(ctx: *anyopaque, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!storage.Acl {
    return getObjectAcl(@ptrCast(@alignCast(ctx)), allocator, bucket, key, version_id);
}
fn vtPutBucketPolicy(ctx: *anyopaque, bucket: []const u8, policy_json: []const u8) storage.Error!void {
    return putBucketPolicy(@ptrCast(@alignCast(ctx)), bucket, policy_json);
}
fn vtGetBucketPolicy(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error![]u8 {
    return getBucketPolicy(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtDeleteBucketPolicy(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketPolicy(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutBucketOwnershipControls(ctx: *anyopaque, bucket: []const u8, oc: storage.OwnershipControl) storage.Error!void {
    return putBucketOwnershipControls(@ptrCast(@alignCast(ctx)), bucket, oc);
}
fn vtGetBucketOwnershipControls(ctx: *anyopaque, bucket: []const u8) storage.Error!storage.OwnershipControl {
    return getBucketOwnershipControls(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtDeleteBucketOwnershipControls(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketOwnershipControls(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutPublicAccessBlock(ctx: *anyopaque, bucket: []const u8, pab: storage.PublicAccessBlockConfig) storage.Error!void {
    return putPublicAccessBlock(@ptrCast(@alignCast(ctx)), bucket, pab);
}
fn vtGetPublicAccessBlock(ctx: *anyopaque, bucket: []const u8) storage.Error!storage.PublicAccessBlockConfig {
    return getPublicAccessBlock(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtDeletePublicAccessBlock(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deletePublicAccessBlock(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutBucketCors(ctx: *anyopaque, bucket: []const u8, cfg: storage.CorsConfig) storage.Error!void {
    return putBucketCors(@ptrCast(@alignCast(ctx)), bucket, cfg);
}
fn vtGetBucketCors(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.CorsConfig {
    return getBucketCors(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtDeleteBucketCors(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketCors(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutBucketEncryption(ctx: *anyopaque, bucket: []const u8, cfg: storage.EncryptionConfig) storage.Error!void {
    return putBucketEncryption(@ptrCast(@alignCast(ctx)), bucket, cfg);
}
fn vtGetBucketEncryption(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.EncryptionConfig {
    return getBucketEncryption(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtDeleteBucketEncryption(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketEncryption(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutBucketLifecycle(ctx: *anyopaque, bucket: []const u8, cfg: storage.LifecycleConfig) storage.Error!void {
    return putBucketLifecycle(@ptrCast(@alignCast(ctx)), bucket, cfg);
}
fn vtGetBucketLifecycle(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.LifecycleConfig {
    return getBucketLifecycle(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtDeleteBucketLifecycle(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketLifecycle(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutBucketNotification(ctx: *anyopaque, bucket: []const u8, cfg: storage.NotificationConfig) storage.Error!void {
    return putBucketNotification(@ptrCast(@alignCast(ctx)), bucket, cfg);
}
fn vtGetBucketNotification(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.NotificationConfig {
    return getBucketNotification(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtPutBucketWebsite(ctx: *anyopaque, bucket: []const u8, cfg: storage.WebsiteConfig) storage.Error!void {
    return putBucketWebsite(@ptrCast(@alignCast(ctx)), bucket, cfg);
}
fn vtGetBucketWebsite(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.WebsiteConfig {
    return getBucketWebsite(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtDeleteBucketWebsite(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketWebsite(@ptrCast(@alignCast(ctx)), bucket);
}
fn vtPutObjectLockConfig(ctx: *anyopaque, bucket: []const u8, cfg: storage.ObjectLockConfig) storage.Error!void {
    return putObjectLockConfig(@ptrCast(@alignCast(ctx)), bucket, cfg);
}
fn vtGetObjectLockConfig(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.ObjectLockConfig {
    return getObjectLockConfig(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtPutObjectRetention(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, retention: storage.ObjectRetention, bypass: bool) storage.Error!void {
    return putObjectRetention(@ptrCast(@alignCast(ctx)), bucket, key, version_id, retention, bypass);
}
fn vtGetObjectRetention(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!storage.ObjectRetention {
    return getObjectRetention(@ptrCast(@alignCast(ctx)), bucket, key, version_id);
}
fn vtPutObjectLegalHold(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, status: storage.LegalHoldStatus) storage.Error!void {
    return putObjectLegalHold(@ptrCast(@alignCast(ctx)), bucket, key, version_id, status);
}
fn vtGetObjectLegalHold(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!storage.LegalHoldStatus {
    return getObjectLegalHold(@ptrCast(@alignCast(ctx)), bucket, key, version_id);
}
fn vtRestoreObject(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, days: u32) storage.Error!storage.RestoreOutcome {
    return restoreObject(@ptrCast(@alignCast(ctx)), bucket, key, version_id, days);
}
fn vtUpdateObjectEncryption(ctx: *anyopaque, bucket: []const u8, key: []const u8, version_id: ?[]const u8, algorithm: storage.SseAlgorithm, kms_key_id: []const u8) storage.Error!void {
    return updateObjectEncryption(@ptrCast(@alignCast(ctx)), bucket, key, version_id, algorithm, kms_key_id);
}
fn vtPutBucketReplication(ctx: *anyopaque, bucket: []const u8, cfg: storage.ReplicationConfig) storage.Error!void {
    return putBucketReplication(@ptrCast(@alignCast(ctx)), bucket, cfg);
}
fn vtGetBucketReplication(ctx: *anyopaque, allocator: Allocator, bucket: []const u8) storage.Error!storage.ReplicationConfig {
    return getBucketReplication(@ptrCast(@alignCast(ctx)), allocator, bucket);
}
fn vtDeleteBucketReplication(ctx: *anyopaque, bucket: []const u8) storage.Error!void {
    return deleteBucketReplication(@ptrCast(@alignCast(ctx)), bucket);
}

// ---------------------------------------------------------------------------
// Bucket ops

pub fn createBucket(self: *Fs, in: storage.CreateBucketInput) storage.Error!void {
    const name = in.name;
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (self.buckets.items) |b| {
        if (std.mem.eql(u8, b.meta.name, name)) return storage.Error.BucketAlreadyOwnedByYou;
    }

    var buf: [4096]u8 = undefined;
    const objects_path = std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, name }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, objects_path) catch return storage.Error.Io;

    const name_owned = self.allocator.dupe(u8, name) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(name_owned);
    const region_owned = self.allocator.dupe(u8, default_region) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(region_owned);

    // M12: Object Lock requires versioning enabled (AWS-exact).
    const initial_versioning: storage.VersioningStatus = if (in.object_lock_enabled) .enabled else .none;

    self.buckets.append(self.allocator, .{
        .meta = .{
            .name = name_owned,
            .region = region_owned,
            .created_unix = nowUnixSeconds(self.io),
        },
        .key_index = .empty,
        .uploads = std.StringHashMap(MultipartState).init(self.allocator),
        .versioning_status = initial_versioning,
        .versions = std.StringHashMap(VersionChain).init(self.allocator),
        .tags = &.{},
        .object_lock_enabled = in.object_lock_enabled,
    }) catch return storage.Error.OutOfMemory;

    saveRegistry(self) catch return storage.Error.Io;
}

pub fn deleteBucket(self: *Fs, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, name) orelse return storage.Error.NoSuchBucket;

    if (self.buckets.items[idx].key_index.items.len > 0) return storage.Error.BucketNotEmpty;
    if (self.buckets.items[idx].uploads.count() > 0) return storage.Error.BucketNotEmpty;

    var buf: [4096]u8 = undefined;
    const bucket_path = std.fmt.bufPrint(&buf, "{s}/s3/{s}", .{ self.base_dir, name }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, bucket_path) catch return storage.Error.Io;

    var removed = self.buckets.orderedRemove(idx);
    removed.deinit(self.allocator);

    saveRegistry(self) catch return storage.Error.Io;
}

pub fn headBucket(self: *Fs, name: []const u8) storage.Error!void {
    try util.validateBucketName(name);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (findBucket(self, name) == null) return storage.Error.NoSuchBucket;
}

pub fn listBuckets(self: *Fs, allocator: Allocator) storage.Error![]storage.Bucket {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var out = allocator.alloc(storage.Bucket, self.buckets.items.len) catch return storage.Error.OutOfMemory;
    errdefer allocator.free(out);
    for (self.buckets.items, 0..) |b, i| {
        out[i] = .{
            .name = allocator.dupe(u8, b.meta.name) catch return storage.Error.OutOfMemory,
            .region = allocator.dupe(u8, b.meta.region) catch return storage.Error.OutOfMemory,
            .created_unix = b.meta.created_unix,
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Object ops

pub fn putObject(self: *Fs, in: storage.PutObjectInput) storage.Error!storage.PutObjectOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    return switch (slot.versioning_status) {
        .none => putObjectFlat(self, slot, in),
        .enabled => putObjectVersioned(self, slot, in, false),
        .suspended => putObjectVersioned(self, slot, in, true),
    };
}

fn putObjectFlat(self: *Fs, slot: *BucketSlot, in: storage.PutObjectInput) storage.Error!storage.PutObjectOutput {
    const etag = etag_mod.computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);

    const hash = keyHash(in.key);
    var dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, key_dir) catch return storage.Error.Io;

    var data_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}/data", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, data_path, in.body) catch return storage.Error.Io;

    // M12: apply bucket default retention if input has no explicit lock.
    const effective = applyDefaultRetention(slot, in, nowUnixSeconds(self.io));
    const meta_doc = MetaDoc{
        .key = in.key,
        .size = in.body.len,
        .etag = etag,
        .content_type = in.content_type,
        .last_modified_unix = nowUnixSeconds(self.io),
        .user_metadata = in.user_metadata,
        .tags = in.tags,
        .acl = in.acl,
        .retention_mode = effective.mode,
        .retain_until_unix = effective.retain_until_unix,
        .legal_hold = effective.legal_hold,
        .sse_algorithm = in.sse_algorithm,
        .sse_kms_key_id = in.sse_kms_key_id,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{key_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    if (!keyIndexContains(slot, in.key)) {
        const owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        errdefer self.allocator.free(owned);
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, in.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
    }

    return .{ .etag = etag };
}

/// M12: resolve the effective retention/legal-hold for a new object. If
/// the input has explicit values, use them; otherwise apply the bucket's
/// default-retention rule (if any). Days take precedence over Years; if
/// both are absent the rule has no effect.
const EffectiveLock = struct {
    mode: ?storage.RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
};
fn applyDefaultRetention(slot: *const BucketSlot, in: storage.PutObjectInput, now: i64) EffectiveLock {
    var out: EffectiveLock = .{
        .mode = in.retention_mode,
        .retain_until_unix = in.retain_until_unix,
        .legal_hold = in.legal_hold,
    };
    if (out.mode != null) return out;
    const cfg = slot.object_lock_config orelse return out;
    const rule = cfg.rule orelse return out;
    const def = rule.default_retention orelse return out;
    out.mode = def.mode;
    if (def.days) |d| {
        out.retain_until_unix = now + @as(i64, @intCast(d)) * 86400;
    } else if (def.years) |y| {
        // AWS treats a year as 365 days for retention math.
        out.retain_until_unix = now + @as(i64, @intCast(y)) * 365 * 86400;
    }
    return out;
}

fn applyDefaultRetentionMpu(slot: *const BucketSlot, state: *const MultipartState, now: i64) EffectiveLock {
    var out: EffectiveLock = .{
        .mode = state.retention_mode,
        .retain_until_unix = state.retain_until_unix,
        .legal_hold = state.legal_hold,
    };
    if (out.mode != null) return out;
    const cfg = slot.object_lock_config orelse return out;
    const rule = cfg.rule orelse return out;
    const def = rule.default_retention orelse return out;
    out.mode = def.mode;
    if (def.days) |d| {
        out.retain_until_unix = now + @as(i64, @intCast(d)) * 86400;
    } else if (def.years) |y| {
        out.retain_until_unix = now + @as(i64, @intCast(y)) * 365 * 86400;
    }
    return out;
}

fn putObjectVersioned(self: *Fs, slot: *BucketSlot, in: storage.PutObjectInput, suspended: bool) storage.Error!storage.PutObjectOutput {
    const etag = etag_mod.computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);

    // versionId: real id on Enabled; literal "null" on Suspended.
    const version_id_owned: []u8 = if (suspended)
        try self.allocator.dupe(u8, "null")
    else
        try newVersionId(self.io, self.allocator);
    errdefer self.allocator.free(version_id_owned);

    const hash = keyHash(in.key);
    var versions_dir_buf: [4096]u8 = undefined;
    const versions_dir = std.fmt.bufPrint(&versions_dir_buf, "{s}/s3/{s}/objects/{s}/versions/{s}", .{ self.base_dir, in.bucket, &hash, version_id_owned }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, versions_dir) catch return storage.Error.Io;

    // 1. Write data.
    var data_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}/data", .{versions_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, data_path, in.body) catch return storage.Error.Io;

    // 2. Write meta.json.
    const now = nowUnixSeconds(self.io);
    const effective = applyDefaultRetention(slot, in, now);
    const meta_doc = VersionedMetaDoc{
        .key = in.key,
        .size = in.body.len,
        .etag = etag,
        .content_type = in.content_type,
        .last_modified_unix = now,
        .user_metadata = in.user_metadata,
        .is_delete_marker = false,
        .tags = in.tags,
        .acl = in.acl,
        .retention_mode = effective.mode,
        .retain_until_unix = effective.retain_until_unix,
        .legal_hold = effective.legal_hold,
        .sse_algorithm = in.sse_algorithm,
        .sse_kms_key_id = in.sse_kms_key_id,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{versions_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    // 3. Update `current` pointer.
    var key_dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&key_dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    var current_path_buf: [4096]u8 = undefined;
    const current_path = std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, current_path, version_id_owned) catch return storage.Error.Io;

    // 4. In-memory chain update.
    const acl_dup: ?storage.Acl = if (in.acl) |a|
        dupeAclOwned(self.allocator, a) catch return storage.Error.OutOfMemory
    else
        null;
    const sse_kms_dup: []u8 = if (in.sse_kms_key_id.len > 0)
        try self.allocator.dupe(u8, in.sse_kms_key_id)
    else
        &.{};
    const chain_entry: VersionEntry = .{
        .version_id = version_id_owned,
        .is_delete_marker = false,
        .etag = self.allocator.dupe(u8, etag) catch return storage.Error.OutOfMemory,
        .size = in.body.len,
        .content_type = self.allocator.dupe(u8, in.content_type) catch return storage.Error.OutOfMemory,
        .last_modified_unix = now,
        .user_metadata = try dupeHeadersStorage(self.allocator, in.user_metadata),
        .tags = try dupeTagsOwned(self.allocator, in.tags),
        .acl = acl_dup,
        .retention_mode = effective.mode,
        .retain_until_unix = effective.retain_until_unix,
        .legal_hold = effective.legal_hold,
        .sse_algorithm = in.sse_algorithm,
        .sse_kms_key_id = sse_kms_dup,
    };

    if (slot.versions.getPtr(in.key)) |chain| {
        if (suspended) {
            // Suspended: any prior "null" version gets overwritten on disk
            // and replaced in the chain.
            var i: usize = 0;
            while (i < chain.items.len) : (i += 1) {
                if (std.mem.eql(u8, chain.items[i].version_id, "null")) {
                    var old = chain.orderedRemove(i);
                    old.deinit(self.allocator);
                    break;
                }
            }
        }
        chain.insert(self.allocator, 0, chain_entry) catch return storage.Error.OutOfMemory;
    } else {
        var chain: VersionChain = .empty;
        chain.append(self.allocator, chain_entry) catch return storage.Error.OutOfMemory;
        const key_owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        slot.versions.put(key_owned, chain) catch return storage.Error.OutOfMemory;
    }

    // 5. Maintain sorted key_index (mirrors flat behaviour; presence ==
    //    "key has a non-delete-marker current version visible").
    if (!keyIndexContains(slot, in.key)) {
        const owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, in.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
    }

    return .{
        .etag = etag,
        .version_id = self.allocator.dupe(u8, version_id_owned) catch return storage.Error.OutOfMemory,
    };
}

/// Generate a 22-char base64-url-no-pad versionId from 16 random bytes.
/// Same generator as multipart upload_id (PRD §M6 + §M8).
fn newVersionId(io: Io, allocator: Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, &raw);
    return out;
}

pub fn getObject(self: *Fs, allocator: Allocator, in: storage.GetObjectInput) storage.Error!storage.GetObjectOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        // Flat read.
        if (in.version_id) |_| return storage.Error.NoSuchKey; // versionId on unversioned bucket
        const meta = readMeta(self, allocator, in.bucket, in.key) catch |err| switch (err) {
            error.FileNotFound => return storage.Error.NoSuchKey,
            else => return storage.Error.Io,
        };
        const hash = keyHash(in.key);
        var path_buf: [4096]u8 = undefined;
        const data_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/data", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
        const body = Io.Dir.cwd().readFileAlloc(self.io, data_path, allocator, .limited(5 * 1024 * 1024 * 1024)) catch return storage.Error.Io;
        return .{ .meta = meta, .body = body };
    }

    // Versioned read.
    const chain = slot.versions.get(in.key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    const v: VersionEntry = blk: {
        if (in.version_id) |vid| {
            for (chain.items) |entry| {
                if (std.mem.eql(u8, entry.version_id, vid)) break :blk entry;
            }
            return storage.Error.NoSuchKey;
        }
        break :blk chain.items[0]; // current = newest
    };

    // Surface delete markers via Object.is_delete_marker; caller (service
    // layer) translates to 404 + headers.
    const meta = try cloneVersionedMeta(allocator, in.key, v);
    if (v.is_delete_marker) {
        return .{ .meta = meta, .body = "" };
    }

    const hash = keyHash(in.key);
    var path_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/versions/{s}/data", .{ self.base_dir, in.bucket, &hash, v.version_id }) catch return storage.Error.Io;
    const body = Io.Dir.cwd().readFileAlloc(self.io, data_path, allocator, .limited(5 * 1024 * 1024 * 1024)) catch return storage.Error.Io;
    return .{ .meta = meta, .body = body };
}

pub fn headObject(self: *Fs, allocator: Allocator, in: storage.HeadObjectInput) storage.Error!storage.Object {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        if (in.version_id) |_| return storage.Error.NoSuchKey;
        return readMeta(self, allocator, in.bucket, in.key) catch |err| switch (err) {
            error.FileNotFound => storage.Error.NoSuchKey,
            else => storage.Error.Io,
        };
    }

    const chain = slot.versions.get(in.key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    const v: VersionEntry = blk: {
        if (in.version_id) |vid| {
            for (chain.items) |entry| {
                if (std.mem.eql(u8, entry.version_id, vid)) break :blk entry;
            }
            return storage.Error.NoSuchKey;
        }
        break :blk chain.items[0];
    };
    return cloneVersionedMeta(allocator, in.key, v);
}

fn cloneVersionedMeta(allocator: Allocator, key: []const u8, v: VersionEntry) storage.Error!storage.Object {
    const acl_out: ?storage.Acl = if (v.acl) |a|
        dupeAclOwned(allocator, a) catch return storage.Error.OutOfMemory
    else
        null;
    return .{
        .key = allocator.dupe(u8, key) catch return storage.Error.OutOfMemory,
        .size = v.size,
        .etag = allocator.dupe(u8, v.etag) catch return storage.Error.OutOfMemory,
        .content_type = allocator.dupe(u8, v.content_type) catch return storage.Error.OutOfMemory,
        .last_modified_unix = v.last_modified_unix,
        .user_metadata = try dupeHeadersStorage(allocator, v.user_metadata),
        .version_id = allocator.dupe(u8, v.version_id) catch return storage.Error.OutOfMemory,
        .is_delete_marker = v.is_delete_marker,
        .tags = try cloneTagsTo(allocator, v.tags),
        .acl = acl_out,
        .retention_mode = v.retention_mode,
        .retain_until_unix = v.retain_until_unix,
        .legal_hold = v.legal_hold,
        .restore_in_progress = v.restore_in_progress,
        .restore_expiry_unix = v.restore_expiry_unix,
        .sse_algorithm = v.sse_algorithm,
        .sse_kms_key_id = allocator.dupe(u8, v.sse_kms_key_id) catch return storage.Error.OutOfMemory,
    };
}

pub fn listObjects(self: *Fs, allocator: Allocator, in: storage.ListObjectsInput) storage.Error!storage.ListObjectsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    var contents: std.ArrayList(storage.Object) = .empty;
    errdefer {
        for (contents.items) |o| freeObjectMetaOwned(allocator, o);
        contents.deinit(allocator);
    }
    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }

    var i: usize = 0;
    var last_key: []const u8 = "";
    var truncated = false;
    const limit: usize = if (in.max_keys > 1000) 1000 else in.max_keys;

    while (i < slot.key_index.items.len) : (i += 1) {
        const k = slot.key_index.items[i];
        if (in.start_after.len > 0 and (std.mem.lessThan(u8, k, in.start_after) or std.mem.eql(u8, k, in.start_after))) continue;
        if (in.prefix.len > 0 and !std.mem.startsWith(u8, k, in.prefix)) continue;

        if (in.delimiter.len > 0) {
            const after = k[in.prefix.len..];
            if (std.mem.indexOf(u8, after, in.delimiter)) |off| {
                const cp_end = in.prefix.len + off + in.delimiter.len;
                const cp = k[0..cp_end];
                if (contents.items.len + prefixes.items.len >= limit) {
                    truncated = true;
                    break;
                }
                const owned = allocator.dupe(u8, cp) catch return storage.Error.OutOfMemory;
                prefixes.append(allocator, owned) catch {
                    allocator.free(owned);
                    return storage.Error.OutOfMemory;
                };
                last_key = k;
                while (i + 1 < slot.key_index.items.len and std.mem.startsWith(u8, slot.key_index.items[i + 1], cp)) : (i += 1) {
                    last_key = slot.key_index.items[i + 1];
                }
                continue;
            }
        }

        if (contents.items.len + prefixes.items.len >= limit) {
            truncated = true;
            break;
        }
        // Lazy-load per-key metadata from disk. Skip missing files silently
        // (the index is the source of truth for "key exists"; missing meta
        // is a stale-index bug that we'd rather not crash on).
        const obj = readMeta(self, allocator, in.bucket, k) catch continue;
        contents.append(allocator, obj) catch {
            freeObjectMetaOwned(allocator, obj);
            return storage.Error.OutOfMemory;
        };
        last_key = k;
    }

    const next_key_owned: []const u8 = if (truncated) blk: {
        break :blk allocator.dupe(u8, last_key) catch return storage.Error.OutOfMemory;
    } else "";

    return .{
        .contents = contents.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .common_prefixes = prefixes.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_key = next_key_owned,
    };
}

fn freeObjectMetaOwned(gpa: Allocator, o: storage.Object) void {
    gpa.free(o.key);
    gpa.free(o.etag);
    gpa.free(o.content_type);
    for (o.user_metadata) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    gpa.free(o.user_metadata);
    for (o.tags) |t| {
        gpa.free(t.key);
        gpa.free(t.value);
    }
    gpa.free(o.tags);
    if (o.acl) |a| freeAclOwned(gpa, a);
    if (o.sse_kms_key_id.len > 0) gpa.free(o.sse_kms_key_id);
    if (o.version_id.len > 0) gpa.free(o.version_id);
}

pub fn deleteObject(self: *Fs, in: storage.DeleteObjectInput) storage.Error!storage.DeleteObjectOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) return deleteObjectFlat(self, slot, in);

    // Versioned bucket.
    if (in.version_id) |vid| {
        return deleteVersion(self, slot, in.bucket, in.key, vid, in.bypass_governance);
    }
    // Delete marker creation — AWS-exact: never blocked by retention/legal hold
    // (a delete marker doesn't actually delete any version's data).
    return createDeleteMarker(self, slot, in.bucket, in.key);
}

fn deleteObjectFlat(self: *Fs, slot: *BucketSlot, in: storage.DeleteObjectInput) storage.Error!storage.DeleteObjectOutput {
    const hash = keyHash(in.key);
    var path_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, key_dir) catch return storage.Error.Io;

    for (slot.key_index.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, in.key)) {
            self.allocator.free(slot.key_index.orderedRemove(i));
            break;
        }
    }
    return .{ .version_id = "", .delete_marker = false };
}

/// Permanently remove one specific version. If it was the current version,
/// the next-newest version becomes current (or the key is fully removed if
/// no versions remain).
fn deleteVersion(self: *Fs, slot: *BucketSlot, bucket: []const u8, key: []const u8, version_id: []const u8, bypass_governance: bool) storage.Error!storage.DeleteObjectOutput {
    const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
    var removed_idx: ?usize = null;
    for (chain.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.version_id, version_id)) {
            removed_idx = i;
            break;
        }
    }
    const idx = removed_idx orelse return storage.Error.NoSuchKey;
    const target = chain.items[idx];

    // M12 WORM enforcement. Delete markers are never protected (they
    // have no retention/legal-hold themselves).
    if (!target.is_delete_marker) {
        if (target.legal_hold) return storage.Error.AccessDenied;
        if (target.retention_mode) |mode| {
            const now = nowUnixSeconds(self.io);
            if (target.retain_until_unix > now) {
                switch (mode) {
                    .GOVERNANCE => if (!bypass_governance) return storage.Error.AccessDenied,
                    .COMPLIANCE => return storage.Error.AccessDenied,
                }
            }
        }
    }

    const was_delete_marker = target.is_delete_marker;
    var removed = chain.orderedRemove(idx);
    removed.deinit(self.allocator);

    // Remove the on-disk version dir.
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const version_dir = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/versions/{s}", .{ self.base_dir, bucket, &hash, version_id }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, version_dir) catch {};

    // If the chain is now empty, also remove the key entry and the
    // `current` pointer file.
    var key_dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&key_dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    if (chain.items.len == 0) {
        Io.Dir.cwd().deleteTree(self.io, key_dir) catch {};
        // Drop from versions map.
        if (slot.versions.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var c = kv.value;
            c.deinit(self.allocator);
        }
        // Drop from key_index.
        for (slot.key_index.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                self.allocator.free(slot.key_index.orderedRemove(i));
                break;
            }
        }
    } else {
        // Rewrite the `current` pointer to the new newest version.
        const new_current = chain.items[0].version_id;
        var current_path_buf: [4096]u8 = undefined;
        const current_path = std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir}) catch return storage.Error.Io;
        writeAtomic(self.io, current_path, new_current) catch return storage.Error.Io;
        // If the new current is a delete marker, the key shouldn't appear
        // in ListObjects; pull it from key_index.
        const new_is_marker = chain.items[0].is_delete_marker;
        if (new_is_marker) {
            for (slot.key_index.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) {
                    self.allocator.free(slot.key_index.orderedRemove(i));
                    break;
                }
            }
        } else if (!keyIndexContains(slot, key)) {
            const owned = self.allocator.dupe(u8, key) catch return storage.Error.OutOfMemory;
            const pos = std.sort.upperBound([]const u8, slot.key_index.items, key, orderSlices);
            slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
        }
    }

    return .{
        .version_id = self.allocator.dupe(u8, version_id) catch return storage.Error.OutOfMemory,
        .delete_marker = was_delete_marker,
    };
}

/// Insert a delete-marker version. Generates a fresh versionId, writes a
/// tombstone meta.json (no data file), updates the `current` pointer,
/// and pulls the key out of `key_index` (so ListObjects hides it).
fn createDeleteMarker(self: *Fs, slot: *BucketSlot, bucket: []const u8, key: []const u8) storage.Error!storage.DeleteObjectOutput {
    const suspended = slot.versioning_status == .suspended;
    const version_id_owned: []u8 = if (suspended)
        try self.allocator.dupe(u8, "null")
    else
        try newVersionId(self.io, self.allocator);
    errdefer self.allocator.free(version_id_owned);

    const hash = keyHash(key);
    var dir_buf: [4096]u8 = undefined;
    const version_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/objects/{s}/versions/{s}", .{ self.base_dir, bucket, &hash, version_id_owned }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, version_dir) catch return storage.Error.Io;

    const now = nowUnixSeconds(self.io);
    const meta_doc = VersionedMetaDoc{
        .key = key,
        .size = 0,
        .etag = "",
        .content_type = "",
        .last_modified_unix = now,
        .user_metadata = &.{},
        .is_delete_marker = true,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{version_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    // Update `current`.
    var key_dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&key_dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, key_dir) catch return storage.Error.Io;
    var current_path_buf: [4096]u8 = undefined;
    const current_path = std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, current_path, version_id_owned) catch return storage.Error.Io;

    // In-memory chain: prepend new delete marker. For Suspended, overwrite
    // any prior "null".
    const chain_entry: VersionEntry = .{
        .version_id = version_id_owned,
        .is_delete_marker = true,
        .etag = self.allocator.dupe(u8, "") catch return storage.Error.OutOfMemory,
        .size = 0,
        .content_type = self.allocator.dupe(u8, "") catch return storage.Error.OutOfMemory,
        .last_modified_unix = now,
        .user_metadata = try dupeHeadersStorage(self.allocator, &.{}),
    };

    if (slot.versions.getPtr(key)) |chain| {
        if (suspended) {
            var i: usize = 0;
            while (i < chain.items.len) : (i += 1) {
                if (std.mem.eql(u8, chain.items[i].version_id, "null")) {
                    var old = chain.orderedRemove(i);
                    old.deinit(self.allocator);
                    break;
                }
            }
        }
        chain.insert(self.allocator, 0, chain_entry) catch return storage.Error.OutOfMemory;
    } else {
        var chain: VersionChain = .empty;
        chain.append(self.allocator, chain_entry) catch return storage.Error.OutOfMemory;
        const key_owned = self.allocator.dupe(u8, key) catch return storage.Error.OutOfMemory;
        slot.versions.put(key_owned, chain) catch return storage.Error.OutOfMemory;
    }

    // Pull the key from key_index — its current version is now a delete
    // marker, so it shouldn't show up in ListObjects.
    for (slot.key_index.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) {
            self.allocator.free(slot.key_index.orderedRemove(i));
            break;
        }
    }

    return .{
        .version_id = self.allocator.dupe(u8, version_id_owned) catch return storage.Error.OutOfMemory,
        .delete_marker = true,
    };
}

// ---------------------------------------------------------------------------
// Versioning (M8)

pub fn getBucketVersioning(self: *Fs, bucket: []const u8) storage.Error!storage.VersioningStatus {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    return self.buckets.items[idx].versioning_status;
}

pub fn putBucketVersioning(self: *Fs, bucket: []const u8, status: storage.VersioningStatus) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    // PutBucketVersioning never resets to `.none` (AWS doesn't expose that
    // in the wire format). Callers should reject `.none` at the service
    // layer; we treat it as a no-op here defensively.
    if (status == .none) return;

    // M12: Object-Lock-enabled buckets cannot have versioning suspended.
    if (slot.object_lock_enabled and status == .suspended) {
        return storage.Error.InvalidBucketState;
    }

    const prev = slot.versioning_status;
    if (prev == .none and status == .enabled) {
        // Migrate every existing object under this bucket from flat
        // `<key-hash>/{data,meta.json}` to `<key-hash>/versions/null/{...}`
        // and populate the in-memory chain.
        migrateNoneToEnabled(self, slot) catch return storage.Error.Io;
    }
    slot.versioning_status = status;
    saveRegistry(self) catch return storage.Error.Io;
}

/// Walks every object directory under the bucket, moves the flat
/// `{data, meta.json}` pair into `versions/null/`, writes `current = "null"`,
/// and populates the in-memory `versions` chain. Idempotent: if a key
/// already has a `versions/` subdir, it's left alone.
fn migrateNoneToEnabled(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const objects_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, slot.meta.name });
    var dir = Io.Dir.cwd().openDir(self.io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // no objects yet
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var key_dir_buf: [4096]u8 = undefined;
        const key_dir = try std.fmt.bufPrint(&key_dir_buf, "{s}/{s}", .{ objects_path, entry.name });
        var vbuf: [4096]u8 = undefined;
        const versions_dir = try std.fmt.bufPrint(&vbuf, "{s}/versions/null", .{key_dir});

        // Skip if already migrated.
        if (dirExists(self.io, versions_dir)) continue;

        // Read the existing meta.json to populate the in-memory chain.
        var meta_path_buf: [4096]u8 = undefined;
        const meta_path = try std.fmt.bufPrint(&meta_path_buf, "{s}/meta.json", .{key_dir});
        const meta_bytes = Io.Dir.cwd().readFileAlloc(self.io, meta_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer self.allocator.free(meta_bytes);
        var parsed = std.json.parseFromSlice(MetaDoc, self.allocator, meta_bytes, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const md = parsed.value;

        // Move both files into versions/null/. Use createDirPath +
        // rename (atomic on same fs).
        Io.Dir.cwd().createDirPath(self.io, versions_dir) catch return storage.Error.Io;

        var src_data: [4096]u8 = undefined;
        const src_data_path = try std.fmt.bufPrint(&src_data, "{s}/data", .{key_dir});
        var dst_data: [4096]u8 = undefined;
        const dst_data_path = try std.fmt.bufPrint(&dst_data, "{s}/data", .{versions_dir});
        Io.Dir.renameAbsolute(src_data_path, dst_data_path, self.io) catch return storage.Error.Io;

        var dst_meta: [4096]u8 = undefined;
        const dst_meta_path = try std.fmt.bufPrint(&dst_meta, "{s}/meta.json", .{versions_dir});
        Io.Dir.renameAbsolute(meta_path, dst_meta_path, self.io) catch return storage.Error.Io;

        // Write the `current` pointer.
        var current_path_buf: [4096]u8 = undefined;
        const current_path = try std.fmt.bufPrint(&current_path_buf, "{s}/current", .{key_dir});
        try writeAtomic(self.io, current_path, "null");

        // Populate in-memory chain (newest-first; chain has one entry).
        var chain: VersionChain = .empty;
        const acl_dup: ?storage.Acl = if (md.acl) |a|
            try dupeAclOwned(self.allocator, a)
        else
            null;
        const v: VersionEntry = .{
            .version_id = try self.allocator.dupe(u8, "null"),
            .is_delete_marker = false,
            .etag = try self.allocator.dupe(u8, md.etag),
            .size = md.size,
            .content_type = try self.allocator.dupe(u8, md.content_type),
            .last_modified_unix = md.last_modified_unix,
            .user_metadata = try dupeHeadersStorage(self.allocator, md.user_metadata),
            .tags = try dupeTagsOwned(self.allocator, md.tags),
            .acl = acl_dup,
            .retention_mode = md.retention_mode,
            .retain_until_unix = md.retain_until_unix,
            .legal_hold = md.legal_hold,
            .restore_in_progress = md.restore_in_progress,
            .restore_expiry_unix = md.restore_expiry_unix,
            .sse_algorithm = md.sse_algorithm,
            .sse_kms_key_id = try self.allocator.dupe(u8, md.sse_kms_key_id),
        };
        try chain.append(self.allocator, v);
        const key_owned = try self.allocator.dupe(u8, md.key);
        try slot.versions.put(key_owned, chain);
    }
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// On startup, walks `<bucket>/objects/*/versions/*/` for each key and
/// populates `slot.versions` with the chain (newest-first by
/// `last_modified_unix`).
fn rebuildVersionIndex(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const objects_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, slot.meta.name });
    var top = Io.Dir.cwd().openDir(self.io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer top.close(self.io);

    var top_it = top.iterate();
    while (try top_it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var versions_buf: [4096]u8 = undefined;
        const versions_path = std.fmt.bufPrint(&versions_buf, "{s}/{s}/versions", .{ objects_path, entry.name }) catch continue;
        var versions_dir = Io.Dir.cwd().openDir(self.io, versions_path, .{ .iterate = true }) catch continue;
        defer versions_dir.close(self.io);

        var chain: VersionChain = .empty;
        errdefer {
            for (chain.items) |*v| v.deinit(self.allocator);
            chain.deinit(self.allocator);
        }

        var key_buf: ?[]u8 = null;
        var vit = versions_dir.iterate();
        while (try vit.next(self.io)) |v_entry| {
            if (v_entry.kind != .directory) continue;
            var meta_buf: [4096]u8 = undefined;
            const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/{s}/meta.json", .{ versions_path, v_entry.name }) catch continue;
            const meta_bytes = Io.Dir.cwd().readFileAlloc(self.io, meta_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
            defer self.allocator.free(meta_bytes);

            var parsed = std.json.parseFromSlice(VersionedMetaDoc, self.allocator, meta_bytes, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const md = parsed.value;

            if (key_buf == null) key_buf = try self.allocator.dupe(u8, md.key);

            const acl_dup: ?storage.Acl = if (md.acl) |a|
                try dupeAclOwned(self.allocator, a)
            else
                null;
            const v: VersionEntry = .{
                .version_id = try self.allocator.dupe(u8, v_entry.name),
                .is_delete_marker = md.is_delete_marker,
                .etag = try self.allocator.dupe(u8, md.etag),
                .size = md.size,
                .content_type = try self.allocator.dupe(u8, md.content_type),
                .last_modified_unix = md.last_modified_unix,
                .user_metadata = try dupeHeadersStorage(self.allocator, md.user_metadata),
                .tags = try dupeTagsOwned(self.allocator, md.tags),
                .acl = acl_dup,
                .restore_in_progress = md.restore_in_progress,
                .restore_expiry_unix = md.restore_expiry_unix,
                .sse_algorithm = md.sse_algorithm,
                .sse_kms_key_id = try self.allocator.dupe(u8, md.sse_kms_key_id),
                .retention_mode = md.retention_mode,
                .retain_until_unix = md.retain_until_unix,
                .legal_hold = md.legal_hold,
            };
            try chain.append(self.allocator, v);
        }

        if (chain.items.len == 0 or key_buf == null) {
            chain.deinit(self.allocator);
            if (key_buf) |k| self.allocator.free(k);
            continue;
        }
        // Sort newest-first by last_modified_unix.
        std.mem.sort(VersionEntry, chain.items, {}, struct {
            fn lt(_: void, a: VersionEntry, b: VersionEntry) bool {
                return a.last_modified_unix > b.last_modified_unix;
            }
        }.lt);
        try slot.versions.put(key_buf.?, chain);
    }
}

/// On-disk version meta.json schema. Same fields as the flat MetaDoc plus
/// `is_delete_marker` so we can persist tombstones.
const VersionedMetaDoc = struct {
    key: []const u8,
    size: usize,
    etag: []const u8,
    content_type: []const u8,
    last_modified_unix: i64,
    user_metadata: []const storage.Header,
    is_delete_marker: bool = false,
    /// M9. Defaults to empty for older records.
    tags: []const storage.Tag = &.{},
    /// M10. `null` on older records → synthesize default on Get.
    acl: ?storage.Acl = null,
    /// M12. Object Lock state.
    retention_mode: ?storage.RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. Restore + SSE.
    restore_in_progress: bool = false,
    restore_expiry_unix: i64 = 0,
    sse_algorithm: ?storage.SseAlgorithm = null,
    sse_kms_key_id: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Tagging (M9). Bucket-level tags live in the registry. Object tags live
// inside the per-object/per-version meta.json (`tags` field). For versioned
// buckets we also keep an in-memory copy on each VersionEntry.

pub fn putBucketTagging(self: *Fs, bucket: []const u8, tags: []const storage.Tag) storage.Error!void {
    try storage.validateTagSet(tags);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const new_tags = try dupeTagsOwned(self.allocator, tags);
    freeTagsOwned(self.allocator, slot.tags);
    slot.tags = new_tags;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketTagging(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error![]storage.Tag {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    if (slot.tags.len == 0) return storage.Error.NoSuchTagSet;
    return cloneTagsTo(allocator, slot.tags);
}

pub fn deleteBucketTagging(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    freeTagsOwned(self.allocator, slot.tags);
    slot.tags = &.{};
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn putObjectTagging(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8, tags: []const storage.Tag) storage.Error!void {
    try storage.validateTagSet(tags);
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        if (version_id) |_| return storage.Error.NoSuchKey;
        return writeFlatObjectTags(self, bucket, key, tags);
    }

    // Versioned bucket. Resolve target version, update in-memory chain +
    // persist to that version's meta.json.
    const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target_idx: usize = 0;
    if (version_id) |vid| {
        var found: ?usize = null;
        for (chain.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                found = i;
                break;
            }
        }
        target_idx = found orelse return storage.Error.NoSuchKey;
    }
    if (chain.items[target_idx].is_delete_marker) return storage.Error.NoSuchKey;

    const new_tags = try dupeTagsOwned(self.allocator, tags);
    // Free old in-memory tags + swap.
    freeTagsOwned(self.allocator, chain.items[target_idx].tags);
    chain.items[target_idx].tags = new_tags;

    // Re-serialise the meta.json for that version.
    try rewriteVersionMeta(self, bucket, key, &chain.items[target_idx]);
}

pub fn getObjectTagging(self: *Fs, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error![]storage.Tag {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        if (version_id) |_| return storage.Error.NoSuchKey;
        const meta = readMeta(self, allocator, bucket, key) catch |err| switch (err) {
            error.FileNotFound => return storage.Error.NoSuchKey,
            else => return storage.Error.Io,
        };
        defer freeObjectMetaOwned(allocator, meta);
        return cloneTagsTo(allocator, meta.tags);
    }

    const chain = slot.versions.get(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target: VersionEntry = chain.items[0];
    if (version_id) |vid| {
        var found = false;
        for (chain.items) |entry| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                target = entry;
                found = true;
                break;
            }
        }
        if (!found) return storage.Error.NoSuchKey;
    }
    if (target.is_delete_marker) return storage.Error.NoSuchKey;
    return cloneTagsTo(allocator, target.tags);
}

pub fn deleteObjectTagging(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!void {
    return putObjectTagging(self, bucket, key, version_id, &.{});
}

fn writeFlatObjectTags(self: *Fs, bucket: []const u8, key: []const u8, tags: []const storage.Tag) storage.Error!void {
    // Read existing meta, splice tags in, write back atomically.
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = readMeta(self, arena, bucket, key) catch |err| switch (err) {
        error.FileNotFound => return storage.Error.NoSuchKey,
        else => return storage.Error.Io,
    };
    const meta_doc = MetaDoc{
        .key = meta.key,
        .size = meta.size,
        .etag = meta.etag,
        .content_type = meta.content_type,
        .last_modified_unix = meta.last_modified_unix,
        .user_metadata = meta.user_metadata,
        .tags = tags,
        .acl = meta.acl,
        .retention_mode = meta.retention_mode,
        .retain_until_unix = meta.retain_until_unix,
        .legal_hold = meta.legal_hold,
        .restore_in_progress = meta.restore_in_progress,
        .restore_expiry_unix = meta.restore_expiry_unix,
        .sse_algorithm = meta.sse_algorithm,
        .sse_kms_key_id = meta.sse_kms_key_id,
    };
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/meta.json", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;
}

fn rewriteVersionMeta(self: *Fs, bucket: []const u8, key: []const u8, v: *const VersionEntry) storage.Error!void {
    const meta_doc = VersionedMetaDoc{
        .key = key,
        .size = v.size,
        .etag = v.etag,
        .content_type = v.content_type,
        .last_modified_unix = v.last_modified_unix,
        .user_metadata = v.user_metadata,
        .is_delete_marker = v.is_delete_marker,
        .tags = v.tags,
        .acl = v.acl,
        .retention_mode = v.retention_mode,
        .retain_until_unix = v.retain_until_unix,
        .legal_hold = v.legal_hold,
        .restore_in_progress = v.restore_in_progress,
        .restore_expiry_unix = v.restore_expiry_unix,
        .sse_algorithm = v.sse_algorithm,
        .sse_kms_key_id = v.sse_kms_key_id,
    };
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/versions/{s}/meta.json", .{ self.base_dir, bucket, &hash, v.version_id }) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;
}

// ---------------------------------------------------------------------------
// ACLs + policies + ownership + public access block (M10). Bucket-level
// state lives in the registry; object ACLs live inside per-object/
// per-version meta.json. Accept-store-roundtrip — no enforcement.

pub fn putBucketAcl(self: *Fs, bucket: []const u8, acl: storage.Acl) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.ownership_controls) |oc| {
        if (oc == .BucketOwnerEnforced) return storage.Error.AccessControlListNotSupported;
    }
    const new_acl = dupeAclOwned(self.allocator, acl) catch return storage.Error.OutOfMemory;
    if (slot.acl) |old| freeAclOwned(self.allocator, old);
    slot.acl = new_acl;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketAcl(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.Acl {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    if (slot.acl) |a| return dupeAclOwned(allocator, a) catch return storage.Error.OutOfMemory;
    return defaultAcl(allocator) catch return storage.Error.OutOfMemory;
}

pub fn putObjectAcl(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8, acl: storage.Acl) storage.Error!void {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    if (slot.ownership_controls) |oc| {
        if (oc == .BucketOwnerEnforced) return storage.Error.AccessControlListNotSupported;
    }

    if (slot.versioning_status == .none) {
        if (version_id) |_| return storage.Error.NoSuchKey;
        return writeFlatObjectAcl(self, bucket, key, acl);
    }

    const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target_idx: usize = 0;
    if (version_id) |vid| {
        var found: ?usize = null;
        for (chain.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                found = i;
                break;
            }
        }
        target_idx = found orelse return storage.Error.NoSuchKey;
    }
    if (chain.items[target_idx].is_delete_marker) return storage.Error.NoSuchKey;

    const new_acl = dupeAclOwned(self.allocator, acl) catch return storage.Error.OutOfMemory;
    if (chain.items[target_idx].acl) |old| freeAclOwned(self.allocator, old);
    chain.items[target_idx].acl = new_acl;
    try rewriteVersionMeta(self, bucket, key, &chain.items[target_idx]);
}

pub fn getObjectAcl(self: *Fs, allocator: Allocator, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!storage.Acl {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        if (version_id) |_| return storage.Error.NoSuchKey;
        const meta = readMeta(self, allocator, bucket, key) catch |err| switch (err) {
            error.FileNotFound => return storage.Error.NoSuchKey,
            else => return storage.Error.Io,
        };
        defer freeObjectMetaOwned(allocator, meta);
        if (meta.acl) |a| return dupeAclOwned(allocator, a) catch return storage.Error.OutOfMemory;
        return defaultAcl(allocator) catch return storage.Error.OutOfMemory;
    }

    const chain = slot.versions.get(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target: VersionEntry = chain.items[0];
    if (version_id) |vid| {
        var found = false;
        for (chain.items) |entry| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                target = entry;
                found = true;
                break;
            }
        }
        if (!found) return storage.Error.NoSuchKey;
    }
    if (target.is_delete_marker) return storage.Error.NoSuchKey;
    if (target.acl) |a| return dupeAclOwned(allocator, a) catch return storage.Error.OutOfMemory;
    return defaultAcl(allocator) catch return storage.Error.OutOfMemory;
}

pub fn putBucketPolicy(self: *Fs, bucket: []const u8, policy_json: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const copy = self.allocator.dupe(u8, policy_json) catch return storage.Error.OutOfMemory;
    if (slot.policy_json) |old| self.allocator.free(old);
    slot.policy_json = copy;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketPolicy(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const p = slot.policy_json orelse return storage.Error.NoSuchBucketPolicy;
    return allocator.dupe(u8, p) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucketPolicy(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.policy_json) |old| {
        self.allocator.free(old);
        slot.policy_json = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

pub fn putBucketOwnershipControls(self: *Fs, bucket: []const u8, oc: storage.OwnershipControl) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    slot.ownership_controls = oc;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketOwnershipControls(self: *Fs, bucket: []const u8) storage.Error!storage.OwnershipControl {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    return slot.ownership_controls orelse return storage.Error.OwnershipControlsNotFound;
}

pub fn deleteBucketOwnershipControls(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.ownership_controls) |_| {
        slot.ownership_controls = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

pub fn putPublicAccessBlock(self: *Fs, bucket: []const u8, pab: storage.PublicAccessBlockConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    slot.public_access_block = pab;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getPublicAccessBlock(self: *Fs, bucket: []const u8) storage.Error!storage.PublicAccessBlockConfig {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    return slot.public_access_block orelse return storage.Error.NoSuchPublicAccessBlockConfiguration;
}

pub fn deletePublicAccessBlock(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.public_access_block) |_| {
        slot.public_access_block = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

// ---------------------------------------------------------------------------
// M11 bucket configurations. Each Put dupes the input into backend-owned
// memory, swaps in, persists via saveRegistry. Each Get clones into the
// caller's allocator. Delete clears + persists; idempotent.

pub fn putBucketCors(self: *Fs, bucket: []const u8, cfg: storage.CorsConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    const dup = dupeCorsConfig(self.allocator, cfg) catch return storage.Error.OutOfMemory;
    if (slot.cors) |old| freeCorsConfig(self.allocator, old);
    slot.cors = dup;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketCors(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.CorsConfig {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const cfg = slot.cors orelse return storage.Error.NoSuchCorsConfiguration;
    return dupeCorsConfig(allocator, cfg) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucketCors(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.cors) |old| {
        freeCorsConfig(self.allocator, old);
        slot.cors = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

pub fn putBucketEncryption(self: *Fs, bucket: []const u8, cfg: storage.EncryptionConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    const dup = dupeEncryptionConfig(self.allocator, cfg) catch return storage.Error.OutOfMemory;
    if (slot.encryption) |old| freeEncryptionConfig(self.allocator, old);
    slot.encryption = dup;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketEncryption(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.EncryptionConfig {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const cfg = slot.encryption orelse return storage.Error.ServerSideEncryptionConfigurationNotFound;
    return dupeEncryptionConfig(allocator, cfg) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucketEncryption(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.encryption) |old| {
        freeEncryptionConfig(self.allocator, old);
        slot.encryption = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

pub fn putBucketLifecycle(self: *Fs, bucket: []const u8, cfg: storage.LifecycleConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    const dup = dupeLifecycleConfig(self.allocator, cfg) catch return storage.Error.OutOfMemory;
    if (slot.lifecycle) |old| freeLifecycleConfig(self.allocator, old);
    slot.lifecycle = dup;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketLifecycle(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.LifecycleConfig {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const cfg = slot.lifecycle orelse return storage.Error.NoSuchLifecycleConfiguration;
    return dupeLifecycleConfig(allocator, cfg) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucketLifecycle(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.lifecycle) |old| {
        freeLifecycleConfig(self.allocator, old);
        slot.lifecycle = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

pub fn putBucketNotification(self: *Fs, bucket: []const u8, cfg: storage.NotificationConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    // Empty Put removes; matches AWS-exact behaviour.
    if (cfg.entries.len == 0) {
        if (slot.notification) |old| freeNotificationConfig(self.allocator, old);
        slot.notification = null;
        saveRegistry(self) catch return storage.Error.Io;
        return;
    }
    const dup = dupeNotificationConfig(self.allocator, cfg) catch return storage.Error.OutOfMemory;
    if (slot.notification) |old| freeNotificationConfig(self.allocator, old);
    slot.notification = dup;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketNotification(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.NotificationConfig {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    if (slot.notification) |cfg| return dupeNotificationConfig(allocator, cfg) catch return storage.Error.OutOfMemory;
    // AWS-exact: untouched bucket returns 200 with empty config (no error).
    return .{ .entries = &.{} };
}

pub fn putBucketWebsite(self: *Fs, bucket: []const u8, cfg: storage.WebsiteConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    const dup = dupeWebsiteConfig(self.allocator, cfg) catch return storage.Error.OutOfMemory;
    if (slot.website) |old| freeWebsiteConfig(self.allocator, old);
    slot.website = dup;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketWebsite(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.WebsiteConfig {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const cfg = slot.website orelse return storage.Error.NoSuchWebsiteConfiguration;
    return dupeWebsiteConfig(allocator, cfg) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucketWebsite(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.website) |old| {
        freeWebsiteConfig(self.allocator, old);
        slot.website = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

// ---------------------------------------------------------------------------
// Object Lock + retention + legal hold (M12).

pub fn putObjectLockConfig(self: *Fs, bucket: []const u8, cfg: storage.ObjectLockConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    // AWS-exact: enabling Object Lock after bucket creation requires a
    // token-based flow we don't support. The bucket must have been
    // created with Object Lock enabled.
    if (!slot.object_lock_enabled) return storage.Error.InvalidBucketState;
    slot.object_lock_config = cfg;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getObjectLockConfig(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.ObjectLockConfig {
    _ = allocator;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    if (!slot.object_lock_enabled) return storage.Error.ObjectLockConfigurationNotFound;
    // AWS-exact: when locked but no Put*Config has run, return the
    // bare "Enabled" config (no rule).
    return slot.object_lock_config orelse storage.ObjectLockConfig{ .object_lock_enabled = true, .rule = null };
}

pub fn putObjectRetention(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8, retention: storage.ObjectRetention, bypass: bool) storage.Error!void {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    // Object Lock must be enabled for retention to be meaningful.
    if (!slot.object_lock_enabled) return storage.Error.InvalidBucketState;
    if (slot.versioning_status == .none) return storage.Error.NoSuchKey;

    const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target_idx: usize = 0;
    if (version_id) |vid| {
        var found: ?usize = null;
        for (chain.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                found = i;
                break;
            }
        }
        target_idx = found orelse return storage.Error.NoSuchKey;
    }
    if (chain.items[target_idx].is_delete_marker) return storage.Error.NoSuchKey;

    // Mode-transition rules (AWS-exact).
    const now = nowUnixSeconds(self.io);
    const existing = chain.items[target_idx];
    if (existing.retention_mode) |existing_mode| {
        switch (existing_mode) {
            .COMPLIANCE => {
                // COMPLIANCE is immutable: only extendable, never weakened
                // or removed; mode cannot change.
                if (retention.mode != .COMPLIANCE) return storage.Error.AccessDenied;
                if (retention.retain_until_unix < existing.retain_until_unix) return storage.Error.AccessDenied;
            },
            .GOVERNANCE => {
                // GOVERNANCE: shortening or weakening requires bypass.
                const weakening = retention.retain_until_unix < existing.retain_until_unix or
                    (retention.mode == .GOVERNANCE and retention.retain_until_unix < existing.retain_until_unix);
                _ = weakening;
                // Simpler rule: any change that reduces protection while the
                // current retention is still active needs bypass.
                if (existing.retain_until_unix > now) {
                    if (retention.retain_until_unix < existing.retain_until_unix and !bypass) {
                        return storage.Error.AccessDenied;
                    }
                }
            },
        }
    }

    chain.items[target_idx].retention_mode = retention.mode;
    chain.items[target_idx].retain_until_unix = retention.retain_until_unix;
    try rewriteVersionMeta(self, bucket, key, &chain.items[target_idx]);
}

pub fn getObjectRetention(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!storage.ObjectRetention {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) return storage.Error.NoSuchKey;
    const chain = slot.versions.get(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target: VersionEntry = chain.items[0];
    if (version_id) |vid| {
        var found = false;
        for (chain.items) |entry| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                target = entry;
                found = true;
                break;
            }
        }
        if (!found) return storage.Error.NoSuchKey;
    }
    const mode = target.retention_mode orelse return storage.Error.ObjectLockConfigurationNotFound;
    return .{ .mode = mode, .retain_until_unix = target.retain_until_unix };
}

pub fn putObjectLegalHold(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8, status: storage.LegalHoldStatus) storage.Error!void {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (!slot.object_lock_enabled) return storage.Error.InvalidBucketState;
    if (slot.versioning_status == .none) return storage.Error.NoSuchKey;

    const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target_idx: usize = 0;
    if (version_id) |vid| {
        var found: ?usize = null;
        for (chain.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                found = i;
                break;
            }
        }
        target_idx = found orelse return storage.Error.NoSuchKey;
    }
    if (chain.items[target_idx].is_delete_marker) return storage.Error.NoSuchKey;

    chain.items[target_idx].legal_hold = (status == .ON);
    try rewriteVersionMeta(self, bucket, key, &chain.items[target_idx]);
}

pub fn getObjectLegalHold(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8) storage.Error!storage.LegalHoldStatus {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) return storage.Error.NoSuchKey;
    const chain = slot.versions.get(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target: VersionEntry = chain.items[0];
    if (version_id) |vid| {
        var found = false;
        for (chain.items) |entry| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                target = entry;
                found = true;
                break;
            }
        }
        if (!found) return storage.Error.NoSuchKey;
    }
    return if (target.legal_hold) .ON else .OFF;
}

// ---------------------------------------------------------------------------
// M13: PolicyStatus, RestoreObject, UpdateObjectEncryption, Replication.

pub fn restoreObject(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8, days: u32) storage.Error!storage.RestoreOutcome {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        // Restore on a flat object: rewrite meta.json.
        if (version_id) |_| return storage.Error.NoSuchKey;
        try writeFlatRestore(self, bucket, key, days);
    } else {
        const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
        if (chain.items.len == 0) return storage.Error.NoSuchKey;
        var target_idx: usize = 0;
        if (version_id) |vid| {
            var found: ?usize = null;
            for (chain.items, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.version_id, vid)) {
                    found = i;
                    break;
                }
            }
            target_idx = found orelse return storage.Error.NoSuchKey;
        }
        if (chain.items[target_idx].is_delete_marker) return storage.Error.NoSuchKey;

        const now = nowUnixSeconds(self.io);
        chain.items[target_idx].restore_in_progress = true;
        chain.items[target_idx].restore_expiry_unix = now + @as(i64, @intCast(days)) * 86400;
        try rewriteVersionMeta(self, bucket, key, &chain.items[target_idx]);
    }

    // Drift #21: AWS returns 200 for an "already restored" idempotent
    // RestoreObject and 202 for a fresh restore. State is in-memory only
    // — lost on restart, acceptable for local-dev semantics.
    const dedup_key = std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{
        bucket, key, version_id orelse "",
    }) catch return storage.Error.OutOfMemory;
    const entry = self.restored_objects.getOrPut(self.allocator, dedup_key) catch {
        self.allocator.free(dedup_key);
        return storage.Error.OutOfMemory;
    };
    if (entry.found_existing) {
        // Free the redundant key — the existing map entry owns its own copy.
        self.allocator.free(dedup_key);
        return .already_in_progress;
    }
    return .initiated;
}

fn writeFlatRestore(self: *Fs, bucket: []const u8, key: []const u8, days: u32) storage.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = readMeta(self, arena, bucket, key) catch |err| switch (err) {
        error.FileNotFound => return storage.Error.NoSuchKey,
        else => return storage.Error.Io,
    };
    const now = nowUnixSeconds(self.io);
    const meta_doc = MetaDoc{
        .key = meta.key,
        .size = meta.size,
        .etag = meta.etag,
        .content_type = meta.content_type,
        .last_modified_unix = meta.last_modified_unix,
        .user_metadata = meta.user_metadata,
        .tags = meta.tags,
        .acl = meta.acl,
        .retention_mode = meta.retention_mode,
        .retain_until_unix = meta.retain_until_unix,
        .legal_hold = meta.legal_hold,
        .restore_in_progress = true,
        .restore_expiry_unix = now + @as(i64, @intCast(days)) * 86400,
        .sse_algorithm = meta.sse_algorithm,
        .sse_kms_key_id = meta.sse_kms_key_id,
    };
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/meta.json", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;
}

pub fn updateObjectEncryption(self: *Fs, bucket: []const u8, key: []const u8, version_id: ?[]const u8, algorithm: storage.SseAlgorithm, kms_key_id: []const u8) storage.Error!void {
    try storage.validateObjectKey(key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    if (slot.versioning_status == .none) {
        if (version_id) |_| return storage.Error.NoSuchKey;
        return writeFlatObjectEncryption(self, bucket, key, algorithm, kms_key_id);
    }

    const chain = slot.versions.getPtr(key) orelse return storage.Error.NoSuchKey;
    if (chain.items.len == 0) return storage.Error.NoSuchKey;
    var target_idx: usize = 0;
    if (version_id) |vid| {
        var found: ?usize = null;
        for (chain.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.version_id, vid)) {
                found = i;
                break;
            }
        }
        target_idx = found orelse return storage.Error.NoSuchKey;
    }
    if (chain.items[target_idx].is_delete_marker) return storage.Error.NoSuchKey;

    const new_kms: []u8 = if (kms_key_id.len > 0) try self.allocator.dupe(u8, kms_key_id) else &.{};
    if (chain.items[target_idx].sse_kms_key_id.len > 0) self.allocator.free(chain.items[target_idx].sse_kms_key_id);
    chain.items[target_idx].sse_algorithm = algorithm;
    chain.items[target_idx].sse_kms_key_id = new_kms;
    try rewriteVersionMeta(self, bucket, key, &chain.items[target_idx]);
}

fn writeFlatObjectEncryption(self: *Fs, bucket: []const u8, key: []const u8, algorithm: storage.SseAlgorithm, kms_key_id: []const u8) storage.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = readMeta(self, arena, bucket, key) catch |err| switch (err) {
        error.FileNotFound => return storage.Error.NoSuchKey,
        else => return storage.Error.Io,
    };
    const meta_doc = MetaDoc{
        .key = meta.key,
        .size = meta.size,
        .etag = meta.etag,
        .content_type = meta.content_type,
        .last_modified_unix = meta.last_modified_unix,
        .user_metadata = meta.user_metadata,
        .tags = meta.tags,
        .acl = meta.acl,
        .retention_mode = meta.retention_mode,
        .retain_until_unix = meta.retain_until_unix,
        .legal_hold = meta.legal_hold,
        .restore_in_progress = meta.restore_in_progress,
        .restore_expiry_unix = meta.restore_expiry_unix,
        .sse_algorithm = algorithm,
        .sse_kms_key_id = kms_key_id,
    };
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/meta.json", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;
}

pub fn putBucketReplication(self: *Fs, bucket: []const u8, cfg: storage.ReplicationConfig) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    const dup = dupeReplicationConfig(self.allocator, cfg) catch return storage.Error.OutOfMemory;
    if (slot.replication) |old| freeReplicationConfig(self.allocator, old);
    slot.replication = dup;
    saveRegistry(self) catch return storage.Error.Io;
}

pub fn getBucketReplication(self: *Fs, allocator: Allocator, bucket: []const u8) storage.Error!storage.ReplicationConfig {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const cfg = slot.replication orelse return storage.Error.ReplicationConfigurationNotFound;
    return dupeReplicationConfig(allocator, cfg) catch return storage.Error.OutOfMemory;
}

pub fn deleteBucketReplication(self: *Fs, bucket: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.replication) |old| {
        freeReplicationConfig(self.allocator, old);
        slot.replication = null;
        saveRegistry(self) catch return storage.Error.Io;
    }
}

fn writeFlatObjectAcl(self: *Fs, bucket: []const u8, key: []const u8, acl: storage.Acl) storage.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = readMeta(self, arena, bucket, key) catch |err| switch (err) {
        error.FileNotFound => return storage.Error.NoSuchKey,
        else => return storage.Error.Io,
    };
    const meta_doc = MetaDoc{
        .key = meta.key,
        .size = meta.size,
        .etag = meta.etag,
        .content_type = meta.content_type,
        .last_modified_unix = meta.last_modified_unix,
        .user_metadata = meta.user_metadata,
        .tags = meta.tags,
        .acl = acl,
        .retention_mode = meta.retention_mode,
        .retain_until_unix = meta.retain_until_unix,
        .legal_hold = meta.legal_hold,
        .restore_in_progress = meta.restore_in_progress,
        .restore_expiry_unix = meta.restore_expiry_unix,
        .sse_algorithm = meta.sse_algorithm,
        .sse_kms_key_id = meta.sse_kms_key_id,
    };
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/meta.json", .{ self.base_dir, bucket, &hash }) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;
}

/// Clone a tag set into caller-provided allocator (used to surface tags
/// out of the backend without leaking the backend's allocator).
fn cloneTagsTo(allocator: Allocator, src: []const storage.Tag) storage.Error![]storage.Tag {
    const out = allocator.alloc(storage.Tag, src.len) catch return storage.Error.OutOfMemory;
    errdefer allocator.free(out);
    var made: usize = 0;
    errdefer for (out[0..made]) |t| {
        allocator.free(t.key);
        allocator.free(t.value);
    };
    for (src) |t| {
        out[made] = .{
            .key = allocator.dupe(u8, t.key) catch return storage.Error.OutOfMemory,
            .value = allocator.dupe(u8, t.value) catch return storage.Error.OutOfMemory,
        };
        made += 1;
    }
    return out;
}

pub fn listObjectVersions(self: *Fs, allocator: Allocator, in: storage.ListObjectVersionsInput) storage.Error!storage.ListObjectVersionsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    // Collect every (key, version) into a flat list, sort by (key asc,
    // version newest-first within key). For unversioned buckets the
    // result is empty.
    var keys_sorted: std.ArrayList([]const u8) = .empty;
    defer keys_sorted.deinit(allocator);
    {
        var it = slot.versions.iterator();
        while (it.next()) |entry| {
            keys_sorted.append(allocator, entry.key_ptr.*) catch return storage.Error.OutOfMemory;
        }
    }
    std.mem.sort([]const u8, keys_sorted.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var out: std.ArrayList(storage.ObjectVersion) = .empty;
    errdefer {
        for (out.items) |v| {
            allocator.free(v.key);
            allocator.free(v.version_id);
            allocator.free(v.etag);
        }
        out.deinit(allocator);
    }
    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }

    var truncated = false;
    var last_key: []const u8 = "";
    var last_vid: []const u8 = "";
    const limit: usize = if (in.max_keys > 1000) 1000 else in.max_keys;

    outer: for (keys_sorted.items) |k| {
        if (in.prefix.len > 0 and !std.mem.startsWith(u8, k, in.prefix)) continue;

        // Delimiter rollup — group every key whose suffix (after prefix) contains
        // the delimiter, contribute one CommonPrefixes entry.
        if (in.delimiter.len > 0) {
            const after = k[in.prefix.len..];
            if (std.mem.indexOf(u8, after, in.delimiter)) |off| {
                const cp_end = in.prefix.len + off + in.delimiter.len;
                const cp = k[0..cp_end];
                if (prefixes.items.len == 0 or !std.mem.eql(u8, prefixes.items[prefixes.items.len - 1], cp)) {
                    if (out.items.len + prefixes.items.len >= limit) {
                        truncated = true;
                        break :outer;
                    }
                    const owned = allocator.dupe(u8, cp) catch return storage.Error.OutOfMemory;
                    prefixes.append(allocator, owned) catch return storage.Error.OutOfMemory;
                    last_key = k;
                    last_vid = "";
                }
                continue;
            }
        }

        const chain = slot.versions.get(k).?;
        for (chain.items, 0..) |v, i| {
            // Pagination: skip entries on or before (key_marker, version_id_marker).
            if (in.key_marker.len > 0) {
                const cmp = std.mem.order(u8, k, in.key_marker);
                if (cmp == .lt) continue;
                if (cmp == .eq and in.version_id_marker.len > 0) {
                    // We need to skip up through and including version_id_marker.
                    // Use linear scan within the chain: only emit entries that
                    // appear *after* version_id_marker in newest-first order.
                    var seen_marker = false;
                    for (chain.items[0..i]) |earlier| {
                        if (std.mem.eql(u8, earlier.version_id, in.version_id_marker)) {
                            seen_marker = true;
                            break;
                        }
                    }
                    if (!seen_marker) continue;
                }
            }

            if (out.items.len + prefixes.items.len >= limit) {
                truncated = true;
                break :outer;
            }
            const k_dup = allocator.dupe(u8, k) catch return storage.Error.OutOfMemory;
            const id_dup = allocator.dupe(u8, v.version_id) catch {
                allocator.free(k_dup);
                return storage.Error.OutOfMemory;
            };
            const etag_dup = allocator.dupe(u8, v.etag) catch {
                allocator.free(k_dup);
                allocator.free(id_dup);
                return storage.Error.OutOfMemory;
            };
            out.append(allocator, .{
                .key = k_dup,
                .version_id = id_dup,
                .is_latest = (i == 0),
                .is_delete_marker = v.is_delete_marker,
                .last_modified_unix = v.last_modified_unix,
                .etag = etag_dup,
                .size = v.size,
            }) catch {
                allocator.free(k_dup);
                allocator.free(id_dup);
                allocator.free(etag_dup);
                return storage.Error.OutOfMemory;
            };
            last_key = k;
            last_vid = v.version_id;
        }
    }

    const next_key_owned: []const u8 = if (truncated) (allocator.dupe(u8, last_key) catch return storage.Error.OutOfMemory) else "";
    const next_vid_owned: []const u8 = if (truncated) (allocator.dupe(u8, last_vid) catch return storage.Error.OutOfMemory) else "";

    return .{
        .versions = out.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .common_prefixes = prefixes.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_key_marker = next_key_owned,
        .next_version_id_marker = next_vid_owned,
    };
}

// ---------------------------------------------------------------------------
// DynamoDB table operations (M15-tables, Phase 2)
//
// All mutating ops hold `self.mutex` for the validate-then-apply +
// write-through-to-disk path. On startup we walk
// `<base>/dynamodb/tables/*/schema.json` to rebuild the in-memory map.

const ddb = struct {
    const dynamo_state = storage.dynamo_state;
    const TableSlot = storage.TableSlot;
};

fn ensureDynamoDir(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/dynamodb/tables", .{self.base_dir});
    try Io.Dir.cwd().createDirPath(self.io, path);
}

/// Serialise a TableSlot to the on-disk schema.json layout.
/// Format is internal to nanostack; the wire layer translates to/from
/// the AWS-PascalCase JSON shape on requests/responses.
const SchemaDoc = struct {
    version: u32,
    name: []const u8,
    key_schema: []const KeyAttrDoc,
    attribute_definitions: []const AttributeDefDoc,
    billing_mode: []const u8,
    global_secondary_indexes: []const IndexDoc,
    local_secondary_indexes: []const IndexDoc,
    tags: []const TagDoc,
    created_unix: i64,
};
const KeyAttrDoc = struct { name: []const u8, key_type: []const u8 };
const AttributeDefDoc = struct { name: []const u8, type: []const u8 };
const ProjectionDoc = struct { type: []const u8, non_key_attributes: []const []const u8 };
const IndexDoc = struct {
    name: []const u8,
    key_schema: []const KeyAttrDoc,
    projection: ProjectionDoc,
};
const TagDoc = struct { key: []const u8, value: []const u8 };

fn tableDirPath(self: *Fs, name: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/dynamodb/tables/{s}", .{ self.base_dir, name });
}

fn schemaJsonPath(self: *Fs, name: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/dynamodb/tables/{s}/schema.json", .{ self.base_dir, name });
}

fn writeSchemaJson(self: *Fs, slot: *const storage.TableSlot) !void {
    var dir_buf: [4096]u8 = undefined;
    const dir_path = try tableDirPath(self, slot.name, &dir_buf);
    try Io.Dir.cwd().createDirPath(self.io, dir_path);

    const doc = try slotToDoc(self.allocator, slot);
    defer freeDoc(self.allocator, doc);

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(doc, .{}, &aw.writer);
    const body = aw.toOwnedSlice() catch return error.OutOfMemory;
    defer self.allocator.free(body);

    var path_buf: [4096]u8 = undefined;
    const path = try schemaJsonPath(self, slot.name, &path_buf);
    try writeAtomic(self.io, path, body);
}

fn slotToDoc(allocator: Allocator, slot: *const storage.TableSlot) !SchemaDoc {
    const key_schema_doc = try allocator.alloc(KeyAttrDoc, slot.key_schema.len);
    errdefer allocator.free(key_schema_doc);
    for (slot.key_schema, 0..) |k, i| {
        key_schema_doc[i] = .{ .name = k.name, .key_type = k.key_type.toAws() };
    }

    const attr_defs_doc = try allocator.alloc(AttributeDefDoc, slot.attribute_definitions.len);
    errdefer allocator.free(attr_defs_doc);
    for (slot.attribute_definitions, 0..) |a, i| {
        attr_defs_doc[i] = .{ .name = a.name, .type = a.type.toAws() };
    }

    const gsi_doc = try indexesToDoc(allocator, slot.global_secondary_indexes, true);
    errdefer allocator.free(gsi_doc);
    const lsi_doc = try indexesToDoc(allocator, slot.local_secondary_indexes, false);
    errdefer allocator.free(lsi_doc);

    const tags_doc = try allocator.alloc(TagDoc, slot.tags.len);
    errdefer allocator.free(tags_doc);
    for (slot.tags, 0..) |t, i| tags_doc[i] = .{ .key = t.key, .value = t.value };

    return .{
        .version = 1,
        .name = slot.name,
        .key_schema = key_schema_doc,
        .attribute_definitions = attr_defs_doc,
        .billing_mode = slot.billing_mode.toAws(),
        .global_secondary_indexes = gsi_doc,
        .local_secondary_indexes = lsi_doc,
        .tags = tags_doc,
        .created_unix = slot.created_unix,
    };
}

fn indexesToDoc(allocator: Allocator, src_gsi: anytype, _: bool) ![]IndexDoc {
    const out = try allocator.alloc(IndexDoc, src_gsi.len);
    errdefer allocator.free(out);
    for (src_gsi, 0..) |g, i| {
        const ks = try allocator.alloc(KeyAttrDoc, g.key_schema.len);
        for (g.key_schema, 0..) |k, j| ks[j] = .{ .name = k.name, .key_type = k.key_type.toAws() };
        out[i] = .{
            .name = g.name,
            .key_schema = ks,
            .projection = .{ .type = g.projection.type.toAws(), .non_key_attributes = g.projection.non_key_attributes },
        };
    }
    return out;
}

fn freeDoc(allocator: Allocator, doc: SchemaDoc) void {
    allocator.free(doc.key_schema);
    allocator.free(doc.attribute_definitions);
    for (doc.global_secondary_indexes) |g| allocator.free(g.key_schema);
    allocator.free(doc.global_secondary_indexes);
    for (doc.local_secondary_indexes) |l| allocator.free(l.key_schema);
    allocator.free(doc.local_secondary_indexes);
    allocator.free(doc.tags);
}

fn loadDynamoTables(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const tables_path = try std.fmt.bufPrint(&buf, "{s}/dynamodb/tables", .{self.base_dir});

    var dir = Io.Dir.cwd().openDir(self.io, tables_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        try loadSingleTable(self, entry.name);
    }
}

fn loadSingleTable(self: *Fs, name: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const path = try schemaJsonPath(self, name, &path_buf);

    const body = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(body);

    var parsed = std.json.parseFromSlice(SchemaDoc, self.allocator, body, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const doc = parsed.value;

    const slot = try docToSlot(self.allocator, doc);
    const slot_ptr = try self.allocator.create(storage.TableSlot);
    slot_ptr.* = slot;

    // Map key shares ownership with slot.name.
    try self.dynamo_tables.put(self.allocator, slot_ptr.name, slot_ptr);
}

fn docToSlot(allocator: Allocator, doc: SchemaDoc) !storage.TableSlot {
    const name = try allocator.dupe(u8, doc.name);

    const ks = try allocator.alloc(ddb.dynamo_state.KeyAttribute, doc.key_schema.len);
    for (doc.key_schema, 0..) |k, i| {
        ks[i] = .{
            .name = try allocator.dupe(u8, k.name),
            .key_type = ddb.dynamo_state.KeyType.fromAws(k.key_type) orelse .hash,
        };
    }

    const ad = try allocator.alloc(ddb.dynamo_state.AttributeDef, doc.attribute_definitions.len);
    for (doc.attribute_definitions, 0..) |a, i| {
        ad[i] = .{
            .name = try allocator.dupe(u8, a.name),
            .type = ddb.dynamo_state.ScalarType.fromAws(a.type) orelse .string,
        };
    }

    const gsis = try docIndexesToSlot(allocator, doc.global_secondary_indexes, ddb.dynamo_state.GsiDef);
    const lsis = try docIndexesToSlot(allocator, doc.local_secondary_indexes, ddb.dynamo_state.LsiDef);

    const tags = try allocator.alloc(ddb.dynamo_state.Tag, doc.tags.len);
    for (doc.tags, 0..) |t, i| {
        tags[i] = .{
            .key = try allocator.dupe(u8, t.key),
            .value = try allocator.dupe(u8, t.value),
        };
    }

    return .{
        .name = name,
        .key_schema = ks,
        .attribute_definitions = ad,
        .billing_mode = ddb.dynamo_state.BillingMode.fromAws(doc.billing_mode) orelse .pay_per_request,
        .global_secondary_indexes = gsis,
        .local_secondary_indexes = lsis,
        .tags = tags,
        .created_unix = doc.created_unix,
    };
}

fn docIndexesToSlot(allocator: Allocator, doc_indexes: []const IndexDoc, comptime T: type) ![]const T {
    const out = try allocator.alloc(T, doc_indexes.len);
    for (doc_indexes, 0..) |idx, i| {
        const ks = try allocator.alloc(ddb.dynamo_state.KeyAttribute, idx.key_schema.len);
        for (idx.key_schema, 0..) |k, j| {
            ks[j] = .{
                .name = try allocator.dupe(u8, k.name),
                .key_type = ddb.dynamo_state.KeyType.fromAws(k.key_type) orelse .hash,
            };
        }
        const nka = try allocator.alloc([]const u8, idx.projection.non_key_attributes.len);
        for (idx.projection.non_key_attributes, 0..) |a, j| nka[j] = try allocator.dupe(u8, a);
        out[i] = .{
            .name = try allocator.dupe(u8, idx.name),
            .key_schema = ks,
            .projection = .{
                .type = ddb.dynamo_state.ProjectionType.fromAws(idx.projection.type) orelse .all,
                .non_key_attributes = nka,
            },
        };
    }
    return out;
}

pub fn ddbListTables(self: *Fs, allocator: Allocator) storage.Error![]const []const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = self.dynamo_tables.iterator();
    while (it.next()) |entry| {
        const owned = allocator.dupe(u8, entry.key_ptr.*) catch return storage.Error.OutOfMemory;
        names.append(allocator, owned) catch return storage.Error.OutOfMemory;
    }
    // Sort lex-ascending for deterministic output (also matches AWS).
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(allocator) catch storage.Error.OutOfMemory;
}

pub fn ddbCreateTable(self: *Fs, in: storage.CreateTableInput) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.dynamo_tables.contains(in.name)) return storage.Error.TableAlreadyExists;

    const slot = cloneTableSlot(self.allocator, in, nowUnixSeconds(self.io)) catch
        return storage.Error.OutOfMemory;
    const slot_ptr = self.allocator.create(storage.TableSlot) catch {
        var tmp = slot;
        tmp.deinit(self.allocator);
        return storage.Error.OutOfMemory;
    };
    slot_ptr.* = slot;

    writeSchemaJson(self, slot_ptr) catch {
        slot_ptr.deinit(self.allocator);
        self.allocator.destroy(slot_ptr);
        return storage.Error.Io;
    };

    self.dynamo_tables.put(self.allocator, slot_ptr.name, slot_ptr) catch {
        // Disk has the schema but in-memory put failed — leave on disk;
        // next startup will load it via loadDynamoTables. Surface OOM.
        return storage.Error.OutOfMemory;
    };
}

fn cloneTableSlot(allocator: Allocator, in: storage.CreateTableInput, created_unix: i64) !storage.TableSlot {
    const name = try allocator.dupe(u8, in.name);
    errdefer allocator.free(name);

    const ks = try allocator.alloc(ddb.dynamo_state.KeyAttribute, in.key_schema.len);
    var ks_done: usize = 0;
    errdefer {
        for (ks[0..ks_done]) |k| allocator.free(k.name);
        allocator.free(ks);
    }
    for (in.key_schema, 0..) |k, i| {
        ks[i] = .{ .name = try allocator.dupe(u8, k.name), .key_type = k.key_type };
        ks_done = i + 1;
    }

    const ad = try allocator.alloc(ddb.dynamo_state.AttributeDef, in.attribute_definitions.len);
    var ad_done: usize = 0;
    errdefer {
        for (ad[0..ad_done]) |a| allocator.free(a.name);
        allocator.free(ad);
    }
    for (in.attribute_definitions, 0..) |a, i| {
        ad[i] = .{ .name = try allocator.dupe(u8, a.name), .type = a.type };
        ad_done = i + 1;
    }

    const gsis = try cloneIndexes(allocator, ddb.dynamo_state.GsiDef, in.global_secondary_indexes);
    const lsis = try cloneIndexes(allocator, ddb.dynamo_state.LsiDef, in.local_secondary_indexes);

    const tags = try allocator.alloc(ddb.dynamo_state.Tag, in.tags.len);
    for (in.tags, 0..) |t, i| {
        tags[i] = .{
            .key = try allocator.dupe(u8, t.key),
            .value = try allocator.dupe(u8, t.value),
        };
    }

    return .{
        .name = name,
        .key_schema = ks,
        .attribute_definitions = ad,
        .billing_mode = in.billing_mode,
        .global_secondary_indexes = gsis,
        .local_secondary_indexes = lsis,
        .tags = tags,
        .created_unix = created_unix,
    };
}

fn cloneIndexes(allocator: Allocator, comptime T: type, src: anytype) ![]const T {
    const out = try allocator.alloc(T, src.len);
    for (src, 0..) |idx, i| {
        const ks = try allocator.alloc(ddb.dynamo_state.KeyAttribute, idx.key_schema.len);
        for (idx.key_schema, 0..) |k, j| {
            ks[j] = .{ .name = try allocator.dupe(u8, k.name), .key_type = k.key_type };
        }
        const nka = try allocator.alloc([]const u8, idx.projection.non_key_attributes.len);
        for (idx.projection.non_key_attributes, 0..) |a, j| nka[j] = try allocator.dupe(u8, a);
        out[i] = .{
            .name = try allocator.dupe(u8, idx.name),
            .key_schema = ks,
            .projection = .{ .type = idx.projection.type, .non_key_attributes = nka },
        };
    }
    return out;
}

pub fn ddbDescribeTable(self: *Fs, name: []const u8) storage.Error!*const storage.TableSlot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.dynamo_tables.get(name) orelse storage.Error.TableNotFound;
}

pub fn ddbDeleteTable(self: *Fs, name: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(name) orelse return storage.Error.TableNotFound;
    var dir_buf: [4096]u8 = undefined;
    const dir_path = tableDirPath(self, name, &dir_buf) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, dir_path) catch return storage.Error.Io;

    _ = self.dynamo_tables.remove(name);
    slot.deinit(self.allocator);
    self.allocator.destroy(slot);
}

pub fn ddbUpdateTable(self: *Fs, in: storage.UpdateTableInput) storage.Error!*const storage.TableSlot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.name) orelse return storage.Error.TableNotFound;
    if (in.billing_mode) |bm| slot.billing_mode = bm;
    writeSchemaJson(self, slot) catch return storage.Error.Io;
    return slot;
}

// ---------------------------------------------------------------------------
// Internals

pub fn nowUnixSeconds(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

fn findBucket(self: *Fs, name: []const u8) ?usize {
    for (self.buckets.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.meta.name, name)) return i;
    }
    return null;
}

fn keyIndexContains(slot: *const BucketSlot, key: []const u8) bool {
    for (slot.key_index.items) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn orderSlices(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

fn keyHash(key: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(key, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeAtomic(io: Io, path: []const u8, body: []const u8) !void {
    var af = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    var buf: [4096]u8 = undefined;
    var fw = af.file.writer(io, &buf);
    try fw.interface.writeAll(body);
    try fw.interface.flush();
    try af.replace(io);
}

fn ensureS3Dir(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const s3_path = try std.fmt.bufPrint(&buf, "{s}/s3", .{self.base_dir});
    try Io.Dir.cwd().createDirPath(self.io, s3_path);
}

fn registryPath(self: *Fs, buf: []u8) ![]u8 {
    return try std.fmt.bufPrint(buf, "{s}/s3/buckets.json", .{self.base_dir});
}

const RegistryDoc = struct {
    version: u32,
    buckets: []BucketRecord,
};

const BucketRecord = struct {
    name: []const u8,
    region: []const u8,
    created_unix: i64,
    /// M8. Missing/null on records from earlier versions is treated as
    /// `.none` (default for unversioned buckets).
    versioning: ?[]const u8 = null,
    /// M9. Bucket-level tag set. Missing/null on older records is treated
    /// as "no TagSet" (404 NoSuchTagSet on GetBucketTagging).
    tags: ?[]const storage.Tag = null,
    /// M10. Bucket-level ACL. `null` → synthesize default on GetBucketAcl.
    acl: ?storage.Acl = null,
    /// M10. Bucket policy JSON bytes. `null` → 404 NoSuchBucketPolicy.
    policy_json: ?[]const u8 = null,
    /// M10. Tag name for OwnershipControl. `null` → 404
    /// OwnershipControlsNotFoundError.
    ownership_controls: ?[]const u8 = null,
    /// M10. PublicAccessBlock config. `null` → 404
    /// NoSuchPublicAccessBlockConfiguration.
    public_access_block: ?storage.PublicAccessBlockConfig = null,
    /// M11. Bucket configs. All `null` on older records.
    cors: ?storage.CorsConfig = null,
    encryption: ?storage.EncryptionConfig = null,
    lifecycle: ?storage.LifecycleConfig = null,
    notification: ?storage.NotificationConfig = null,
    website: ?storage.WebsiteConfig = null,
    /// M12. Object Lock state.
    object_lock_enabled: bool = false,
    object_lock_config: ?storage.ObjectLockConfig = null,
    /// M13. Replication config.
    replication: ?storage.ReplicationConfig = null,
};

const MetaDoc = struct {
    key: []const u8,
    size: usize,
    etag: []const u8,
    content_type: []const u8,
    last_modified_unix: i64,
    user_metadata: []const storage.Header,
    /// M9. Defaults to empty for older records.
    tags: []const storage.Tag = &.{},
    /// M10. `null` on older records → synthesize default on Get.
    acl: ?storage.Acl = null,
    /// M12. Object Lock state.
    retention_mode: ?storage.RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. Restore + SSE.
    restore_in_progress: bool = false,
    restore_expiry_unix: i64 = 0,
    sse_algorithm: ?storage.SseAlgorithm = null,
    sse_kms_key_id: []const u8 = "",
};

fn loadRegistry(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const path = try registryPath(self, &buf);

    const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(RegistryDoc, self.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    for (parsed.value.buckets) |rec| {
        const name_owned = try self.allocator.dupe(u8, rec.name);
        errdefer self.allocator.free(name_owned);
        const region_owned = try self.allocator.dupe(u8, rec.region);
        errdefer self.allocator.free(region_owned);
        const versioning: storage.VersioningStatus = if (rec.versioning) |v|
            (if (std.mem.eql(u8, v, "enabled")) .enabled else if (std.mem.eql(u8, v, "suspended")) .suspended else .none)
        else
            .none;
        const tags_owned: []storage.Tag = if (rec.tags) |t|
            try dupeTagsOwned(self.allocator, t)
        else
            &.{};
        const acl_owned: ?storage.Acl = if (rec.acl) |a|
            try dupeAclOwned(self.allocator, a)
        else
            null;
        const policy_owned: ?[]u8 = if (rec.policy_json) |p|
            try self.allocator.dupe(u8, p)
        else
            null;
        const oc_parsed: ?storage.OwnershipControl = if (rec.ownership_controls) |s|
            storage.ownershipControlFromString(s) catch null
        else
            null;
        const cors_owned: ?storage.CorsConfig = if (rec.cors) |c| try dupeCorsConfig(self.allocator, c) else null;
        const encryption_owned: ?storage.EncryptionConfig = if (rec.encryption) |c| try dupeEncryptionConfig(self.allocator, c) else null;
        const lifecycle_owned: ?storage.LifecycleConfig = if (rec.lifecycle) |c| try dupeLifecycleConfig(self.allocator, c) else null;
        const notification_owned: ?storage.NotificationConfig = if (rec.notification) |c| try dupeNotificationConfig(self.allocator, c) else null;
        const website_owned: ?storage.WebsiteConfig = if (rec.website) |c| try dupeWebsiteConfig(self.allocator, c) else null;
        var slot: BucketSlot = .{
            .meta = .{
                .name = name_owned,
                .region = region_owned,
                .created_unix = rec.created_unix,
            },
            .key_index = .empty,
            .uploads = std.StringHashMap(MultipartState).init(self.allocator),
            .versioning_status = versioning,
            .versions = std.StringHashMap(VersionChain).init(self.allocator),
            .tags = tags_owned,
            .acl = acl_owned,
            .policy_json = policy_owned,
            .ownership_controls = oc_parsed,
            .public_access_block = rec.public_access_block,
            .cors = cors_owned,
            .encryption = encryption_owned,
            .lifecycle = lifecycle_owned,
            .notification = notification_owned,
            .website = website_owned,
            .object_lock_enabled = rec.object_lock_enabled,
            .object_lock_config = rec.object_lock_config,
            .replication = if (rec.replication) |c| try dupeReplicationConfig(self.allocator, c) else null,
        };
        // Walk objects/ to rebuild the in-memory key index from meta.json files.
        try rebuildKeyIndex(self, &slot);
        // Walk multipart/ to repopulate the in-memory upload index from manifests.
        try rebuildUploadIndex(self, &slot);
        // For versioned buckets, walk objects/*/versions/* to rebuild the chains.
        if (versioning != .none) try rebuildVersionIndex(self, &slot);
        try self.buckets.append(self.allocator, slot);
    }
}

fn rebuildKeyIndex(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const objects_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/objects", .{ self.base_dir, slot.meta.name });
    var dir = Io.Dir.cwd().openDir(self.io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var path_buf: [4096]u8 = undefined;
        const meta_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/meta.json", .{ objects_path, entry.name });
        const meta_bytes = Io.Dir.cwd().readFileAlloc(self.io, meta_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer self.allocator.free(meta_bytes);

        var parsed = std.json.parseFromSlice(struct { key: []const u8 }, self.allocator, meta_bytes, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const key_owned = try self.allocator.dupe(u8, parsed.value.key);
        try slot.key_index.append(self.allocator, key_owned);
    }

    std.mem.sort([]const u8, slot.key_index.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

fn readMeta(self: *Fs, allocator: Allocator, bucket: []const u8, key: []const u8) !storage.Object {
    const hash = keyHash(key);
    var path_buf: [4096]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/objects/{s}/meta.json", .{ self.base_dir, bucket, &hash });
    const bytes = try Io.Dir.cwd().readFileAlloc(self.io, meta_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(MetaDoc, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const value = parsed.value;
    var headers = try allocator.alloc(storage.Header, value.user_metadata.len);
    errdefer allocator.free(headers);
    for (value.user_metadata, 0..) |h, i| {
        headers[i] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value),
        };
    }

    const tags = try cloneTagsTo(allocator, value.tags);
    const acl_out: ?storage.Acl = if (value.acl) |a|
        dupeAclOwned(allocator, a) catch return storage.Error.OutOfMemory
    else
        null;

    return .{
        .key = try allocator.dupe(u8, value.key),
        .size = @intCast(value.size),
        .etag = try allocator.dupe(u8, value.etag),
        .content_type = try allocator.dupe(u8, value.content_type),
        .last_modified_unix = value.last_modified_unix,
        .user_metadata = headers,
        .tags = tags,
        .acl = acl_out,
        .retention_mode = value.retention_mode,
        .retain_until_unix = value.retain_until_unix,
        .legal_hold = value.legal_hold,
        .restore_in_progress = value.restore_in_progress,
        .restore_expiry_unix = value.restore_expiry_unix,
        .sse_algorithm = value.sse_algorithm,
        .sse_kms_key_id = try allocator.dupe(u8, value.sse_kms_key_id),
    };
}

fn saveRegistry(self: *Fs) !void {
    var path_buf: [4096]u8 = undefined;
    const path = try registryPath(self, &path_buf);

    var records = try self.allocator.alloc(BucketRecord, self.buckets.items.len);
    defer self.allocator.free(records);
    for (self.buckets.items, 0..) |b, i| {
        const versioning_str: ?[]const u8 = switch (b.versioning_status) {
            .none => null,
            .enabled => "enabled",
            .suspended => "suspended",
        };
        const tags_field: ?[]const storage.Tag = if (b.tags.len == 0) null else b.tags;
        const oc_str: ?[]const u8 = if (b.ownership_controls) |oc| storage.ownershipControlToString(oc) else null;
        records[i] = .{
            .name = b.meta.name,
            .region = b.meta.region,
            .created_unix = b.meta.created_unix,
            .versioning = versioning_str,
            .tags = tags_field,
            .acl = b.acl,
            .policy_json = b.policy_json,
            .ownership_controls = oc_str,
            .public_access_block = b.public_access_block,
            .cors = b.cors,
            .encryption = b.encryption,
            .lifecycle = b.lifecycle,
            .notification = b.notification,
            .website = b.website,
            .object_lock_enabled = b.object_lock_enabled,
            .object_lock_config = b.object_lock_config,
            .replication = b.replication,
        };
    }
    const doc: RegistryDoc = .{ .version = registry_version, .buckets = records };

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.fmt(doc, .{ .whitespace = .indent_2 }).format(&aw.writer);
    try writeAtomic(self.io, path, aw.written());
}

// ---------------------------------------------------------------------------
// Multipart upload (M6)
//
// Layout:  <base>/s3/<bucket>/multipart/<upload_id>/{manifest.json, part-NNNNN}
// In-memory: BucketSlot.uploads is the source of truth; the on-disk
// manifest is the persistent shadow.

const Md5 = std.crypto.hash.Md5;

const ManifestDoc = struct {
    key: []const u8,
    content_type: []const u8,
    user_metadata: []const storage.Header,
    initiated_unix: i64,
    parts: []const ManifestPart,
    /// M9. Tags applied to the merged object on Complete.
    tags: []const storage.Tag = &.{},
    /// M10. ACL applied to the merged object on Complete.
    acl: ?storage.Acl = null,
    /// M12. Object Lock state applied to the merged object on Complete.
    retention_mode: ?storage.RetentionMode = null,
    retain_until_unix: i64 = 0,
    legal_hold: bool = false,
    /// M13. SSE applied to the merged object on Complete.
    sse_algorithm: ?storage.SseAlgorithm = null,
    sse_kms_key_id: []const u8 = "",
    /// Wave 2 (drift #6). Surfaced via <Initiator> on ListMultipartUploads.
    initiator_id: []const u8 = "",
    initiator_display_name: []const u8 = "",
};

const ManifestPart = struct {
    part_number: u32,
    size: u64,
    etag: []const u8,
    last_modified_unix: i64,
};

pub fn initiateMultipartUpload(self: *Fs, allocator: Allocator, in: storage.InitiateMultipartUploadInput) storage.Error!storage.InitiateMultipartUploadOutput {
    try storage.validateObjectKey(in.key);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];

    const upload_id = newUploadId(self.io, allocator) catch return storage.Error.OutOfMemory;
    errdefer allocator.free(upload_id);

    // On-disk: create the per-upload directory.
    var dir_buf: [4096]u8 = undefined;
    const upload_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/multipart/{s}", .{ self.base_dir, in.bucket, upload_id }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, upload_dir) catch return storage.Error.Io;

    // In-memory state.
    const key_owned = self.allocator.dupe(u8, in.key) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(key_owned);
    const ct_owned = self.allocator.dupe(u8, in.content_type) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(ct_owned);
    const meta_owned = dupeHeadersStorage(self.allocator, in.user_metadata) catch return storage.Error.OutOfMemory;
    errdefer freeHeadersStorage(self.allocator, meta_owned);
    const tags_owned = dupeTagsOwned(self.allocator, in.tags) catch return storage.Error.OutOfMemory;
    errdefer freeTagsOwned(self.allocator, tags_owned);
    const acl_owned: ?storage.Acl = if (in.acl) |a|
        dupeAclOwned(self.allocator, a) catch return storage.Error.OutOfMemory
    else
        null;
    errdefer if (acl_owned) |a| freeAclOwned(self.allocator, a);

    const sse_kms_dup: []u8 = if (in.sse_kms_key_id.len > 0)
        try self.allocator.dupe(u8, in.sse_kms_key_id)
    else
        &.{};
    const initiator_id_dup: []u8 = if (in.initiator_id.len > 0)
        try self.allocator.dupe(u8, in.initiator_id)
    else
        &.{};
    errdefer if (initiator_id_dup.len > 0) self.allocator.free(initiator_id_dup);
    const initiator_dn_dup: []u8 = if (in.initiator_display_name.len > 0)
        try self.allocator.dupe(u8, in.initiator_display_name)
    else
        &.{};
    errdefer if (initiator_dn_dup.len > 0) self.allocator.free(initiator_dn_dup);
    const state: MultipartState = .{
        .key = key_owned,
        .content_type = ct_owned,
        .user_metadata = meta_owned,
        .initiated_unix = nowUnixSeconds(self.io),
        .parts = std.AutoHashMap(u32, PartMeta).init(self.allocator),
        .tags = tags_owned,
        .acl = acl_owned,
        .retention_mode = in.retention_mode,
        .retain_until_unix = in.retain_until_unix,
        .legal_hold = in.legal_hold,
        .sse_algorithm = in.sse_algorithm,
        .sse_kms_key_id = sse_kms_dup,
        .initiator_id = initiator_id_dup,
        .initiator_display_name = initiator_dn_dup,
    };

    const id_for_map = self.allocator.dupe(u8, upload_id) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(id_for_map);
    slot.uploads.put(id_for_map, state) catch return storage.Error.OutOfMemory;

    // Persist manifest.
    writeManifest(self, in.bucket, upload_id, &state) catch return storage.Error.Io;

    return .{ .upload_id = upload_id };
}

pub fn uploadPart(self: *Fs, in: storage.UploadPartInput) storage.Error!storage.UploadPartOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    var state = slot.uploads.getPtr(in.upload_id) orelse return storage.Error.NoSuchUpload;

    const etag = etag_mod.computeEtag(self.allocator, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(etag);

    // Atomically write the part file.
    var path_buf: [4096]u8 = undefined;
    const part_path = std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/multipart/{s}/part-{d:0>5}", .{ self.base_dir, in.bucket, in.upload_id, in.part_number }) catch return storage.Error.Io;
    writeAtomic(self.io, part_path, in.body) catch return storage.Error.Io;

    // Replace any prior part meta for this part_number.
    if (state.parts.fetchRemove(in.part_number)) |kv| {
        self.allocator.free(kv.value.etag);
    }
    state.parts.put(in.part_number, .{
        .part_number = in.part_number,
        .size = in.body.len,
        .etag = etag,
        .last_modified_unix = nowUnixSeconds(self.io),
    }) catch return storage.Error.OutOfMemory;

    writeManifest(self, in.bucket, in.upload_id, state) catch return storage.Error.Io;

    return .{ .etag = self.allocator.dupe(u8, etag) catch return storage.Error.OutOfMemory };
}

pub fn completeMultipartUpload(self: *Fs, allocator: Allocator, in: storage.CompleteMultipartUploadInput) storage.Error!storage.CompleteMultipartUploadOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    const entry = slot.uploads.getEntry(in.upload_id) orelse return storage.Error.NoSuchUpload;
    const state = entry.value_ptr;

    // Validate every requested part exists with the claimed etag. Missing
    // parts or etag mismatch → 400 InvalidPart (AWS-exact); "upload id
    // unknown" is the only path that surfaces NoSuchUpload (handled above).
    var total_size: usize = 0;
    for (in.parts) |p| {
        const stored = state.parts.get(p.part_number) orelse return storage.Error.InvalidPart;
        if (!std.mem.eql(u8, stored.etag, p.etag)) return storage.Error.InvalidPart;
        total_size += stored.size;
    }

    // Concatenate parts from disk into the final body buffer + collect digests.
    const body = self.allocator.alloc(u8, total_size) catch return storage.Error.OutOfMemory;
    defer self.allocator.free(body);
    var digests = self.allocator.alloc([16]u8, in.parts.len) catch return storage.Error.OutOfMemory;
    defer self.allocator.free(digests);
    var off: usize = 0;
    for (in.parts, 0..) |p, i| {
        var part_buf: [4096]u8 = undefined;
        const part_path = std.fmt.bufPrint(&part_buf, "{s}/s3/{s}/multipart/{s}/part-{d:0>5}", .{ self.base_dir, in.bucket, in.upload_id, p.part_number }) catch return storage.Error.Io;
        const part_bytes = Io.Dir.cwd().readFileAlloc(self.io, part_path, self.allocator, .limited(5 * 1024 * 1024 * 1024)) catch return storage.Error.Io;
        defer self.allocator.free(part_bytes);
        @memcpy(body[off .. off + part_bytes.len], part_bytes);
        off += part_bytes.len;
        Md5.hash(part_bytes, &digests[i], .{});
    }

    const final_etag = etag_mod.computeMultipartEtag(self.allocator, digests, @intCast(in.parts.len)) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(final_etag);

    // Write the final object (data + meta.json) atomically.
    const hash = keyHash(state.key);
    var dir_buf: [4096]u8 = undefined;
    const key_dir = std.fmt.bufPrint(&dir_buf, "{s}/s3/{s}/objects/{s}", .{ self.base_dir, in.bucket, &hash }) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, key_dir) catch return storage.Error.Io;

    var data_buf: [4096]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}/data", .{key_dir}) catch return storage.Error.Io;
    writeAtomic(self.io, data_path, body) catch return storage.Error.Io;

    // M12: apply bucket default retention if manifest has no explicit lock.
    const effective_mpu = applyDefaultRetentionMpu(slot, state, nowUnixSeconds(self.io));
    const meta_doc = MetaDoc{
        .key = state.key,
        .size = total_size,
        .etag = final_etag,
        .content_type = state.content_type,
        .last_modified_unix = nowUnixSeconds(self.io),
        .user_metadata = state.user_metadata,
        .tags = state.tags,
        .acl = state.acl,
        .retention_mode = effective_mpu.mode,
        .retain_until_unix = effective_mpu.retain_until_unix,
        .legal_hold = effective_mpu.legal_hold,
        .sse_algorithm = state.sse_algorithm,
        .sse_kms_key_id = state.sse_kms_key_id,
    };
    var meta_buf: [4096]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}/meta.json", .{key_dir}) catch return storage.Error.Io;
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    std.json.fmt(meta_doc, .{}).format(&aw.writer) catch return storage.Error.Io;
    writeAtomic(self.io, meta_path, aw.written()) catch return storage.Error.Io;

    // Update sorted key index.
    if (!keyIndexContains(slot, state.key)) {
        const owned = self.allocator.dupe(u8, state.key) catch return storage.Error.OutOfMemory;
        errdefer self.allocator.free(owned);
        const pos = std.sort.upperBound([]const u8, slot.key_index.items, state.key, orderSlices);
        slot.key_index.insert(self.allocator, pos, owned) catch return storage.Error.OutOfMemory;
    }

    // Remove upload state + on-disk dir.
    var upload_dir_buf: [4096]u8 = undefined;
    const upload_dir = std.fmt.bufPrint(&upload_dir_buf, "{s}/s3/{s}/multipart/{s}", .{ self.base_dir, in.bucket, in.upload_id }) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, upload_dir) catch {};

    const id_owned = entry.key_ptr.*;
    var state_copy = entry.value_ptr.*;
    _ = slot.uploads.remove(in.upload_id);
    self.allocator.free(id_owned);
    state_copy.deinit(self.allocator);

    return .{ .etag = allocator.dupe(u8, final_etag) catch return storage.Error.OutOfMemory };
}

pub fn abortMultipartUpload(self: *Fs, bucket: []const u8, key: []const u8, upload_id: []const u8) storage.Error!void {
    _ = key;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, bucket) orelse return storage.Error.NoSuchBucket;
    var slot = &self.buckets.items[idx];
    if (slot.uploads.fetchRemove(upload_id)) |kv| {
        self.allocator.free(kv.key);
        var st = kv.value;
        st.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        const upload_dir = std.fmt.bufPrint(&buf, "{s}/s3/{s}/multipart/{s}", .{ self.base_dir, bucket, upload_id }) catch return storage.Error.Io;
        Io.Dir.cwd().deleteTree(self.io, upload_dir) catch return storage.Error.Io;
        return;
    }
    return storage.Error.NoSuchUpload;
}

pub fn listMultipartUploads(self: *Fs, allocator: Allocator, in: storage.ListMultipartUploadsInput) storage.Error!storage.ListMultipartUploadsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];

    // Snapshot uploads sorted by (key, upload_id).
    const Row = struct {
        id: []const u8,
        key: []const u8,
        initiated_unix: i64,
        initiator_id: []const u8,
        initiator_display_name: []const u8,
    };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var it = slot.uploads.iterator();
    while (it.next()) |entry| {
        rows.append(allocator, .{
            .id = entry.key_ptr.*,
            .key = entry.value_ptr.key,
            .initiated_unix = entry.value_ptr.initiated_unix,
            .initiator_id = entry.value_ptr.initiator_id,
            .initiator_display_name = entry.value_ptr.initiator_display_name,
        }) catch return storage.Error.OutOfMemory;
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            const ord = std.mem.order(u8, a.key, b.key);
            if (ord != .eq) return ord == .lt;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);

    var uploads: std.ArrayList(storage.MultipartUploadInfo) = .empty;
    errdefer {
        for (uploads.items) |u| {
            allocator.free(u.key);
            allocator.free(u.upload_id);
            if (u.initiator_id.len > 0) allocator.free(u.initiator_id);
            if (u.initiator_display_name.len > 0) allocator.free(u.initiator_display_name);
        }
        uploads.deinit(allocator);
    }
    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }

    var truncated = false;
    var last_key: []const u8 = "";
    var last_id: []const u8 = "";
    const limit: usize = if (in.max_uploads > 1000) 1000 else in.max_uploads;

    var i: usize = 0;
    while (i < rows.items.len) : (i += 1) {
        const row = rows.items[i];
        if (in.key_marker.len > 0) {
            const cmp = std.mem.order(u8, row.key, in.key_marker);
            if (cmp == .lt) continue;
            if (cmp == .eq) {
                if (in.upload_id_marker.len == 0) continue;
                if (!std.mem.lessThan(u8, in.upload_id_marker, row.id)) continue;
            }
        }
        if (in.prefix.len > 0 and !std.mem.startsWith(u8, row.key, in.prefix)) continue;

        if (in.delimiter.len > 0) {
            const after = row.key[in.prefix.len..];
            if (std.mem.indexOf(u8, after, in.delimiter)) |off| {
                const cp_end = in.prefix.len + off + in.delimiter.len;
                const cp = row.key[0..cp_end];
                if (prefixes.items.len == 0 or !std.mem.eql(u8, prefixes.items[prefixes.items.len - 1], cp)) {
                    if (uploads.items.len + prefixes.items.len >= limit) {
                        truncated = true;
                        break;
                    }
                    const owned = allocator.dupe(u8, cp) catch return storage.Error.OutOfMemory;
                    prefixes.append(allocator, owned) catch {
                        allocator.free(owned);
                        return storage.Error.OutOfMemory;
                    };
                    last_key = row.key;
                    last_id = row.id;
                }
                continue;
            }
        }

        if (uploads.items.len + prefixes.items.len >= limit) {
            truncated = true;
            break;
        }
        const k_dup = allocator.dupe(u8, row.key) catch return storage.Error.OutOfMemory;
        const id_dup = allocator.dupe(u8, row.id) catch {
            allocator.free(k_dup);
            return storage.Error.OutOfMemory;
        };
        const init_id_dup = allocator.dupe(u8, row.initiator_id) catch {
            allocator.free(k_dup);
            allocator.free(id_dup);
            return storage.Error.OutOfMemory;
        };
        const init_dn_dup = allocator.dupe(u8, row.initiator_display_name) catch {
            allocator.free(k_dup);
            allocator.free(id_dup);
            allocator.free(init_id_dup);
            return storage.Error.OutOfMemory;
        };
        uploads.append(allocator, .{
            .key = k_dup,
            .upload_id = id_dup,
            .initiated_unix = row.initiated_unix,
            .initiator_id = init_id_dup,
            .initiator_display_name = init_dn_dup,
        }) catch {
            allocator.free(k_dup);
            allocator.free(id_dup);
            allocator.free(init_id_dup);
            allocator.free(init_dn_dup);
            return storage.Error.OutOfMemory;
        };
        last_key = row.key;
        last_id = row.id;
    }

    const next_key: []const u8 = if (truncated) (allocator.dupe(u8, last_key) catch return storage.Error.OutOfMemory) else "";
    const next_id: []const u8 = if (truncated) (allocator.dupe(u8, last_id) catch return storage.Error.OutOfMemory) else "";

    return .{
        .uploads = uploads.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .common_prefixes = prefixes.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_key_marker = next_key,
        .next_upload_id_marker = next_id,
    };
}

pub fn listParts(self: *Fs, allocator: Allocator, in: storage.ListPartsInput) storage.Error!storage.ListPartsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const idx = findBucket(self, in.bucket) orelse return storage.Error.NoSuchBucket;
    const slot = &self.buckets.items[idx];
    const state = slot.uploads.get(in.upload_id) orelse return storage.Error.NoSuchUpload;

    var nums: std.ArrayList(u32) = .empty;
    defer nums.deinit(allocator);
    var it = state.parts.iterator();
    while (it.next()) |entry| nums.append(allocator, entry.key_ptr.*) catch return storage.Error.OutOfMemory;
    std.mem.sort(u32, nums.items, {}, std.sort.asc(u32));

    var out: std.ArrayList(storage.PartInfo) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p.etag);
        out.deinit(allocator);
    }
    var truncated = false;
    var last: u32 = 0;
    const limit: usize = if (in.max_parts > 1000) 1000 else in.max_parts;

    for (nums.items) |n| {
        if (n <= in.part_number_marker) continue;
        if (out.items.len >= limit) {
            truncated = true;
            break;
        }
        const stored = state.parts.get(n).?;
        const etag_dup = allocator.dupe(u8, stored.etag) catch return storage.Error.OutOfMemory;
        out.append(allocator, .{
            .part_number = n,
            .size = stored.size,
            .etag = etag_dup,
            .last_modified_unix = stored.last_modified_unix,
        }) catch {
            allocator.free(etag_dup);
            return storage.Error.OutOfMemory;
        };
        last = n;
    }

    return .{
        .parts = out.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .is_truncated = truncated,
        .next_part_number_marker = if (truncated) last else 0,
    };
}

fn writeManifest(self: *Fs, bucket: []const u8, upload_id: []const u8, state: *const MultipartState) !void {
    // Snapshot parts into a flat slice for serialization.
    var parts = try self.allocator.alloc(ManifestPart, state.parts.count());
    defer self.allocator.free(parts);
    var i: usize = 0;
    var it = state.parts.iterator();
    while (it.next()) |entry| : (i += 1) {
        const p = entry.value_ptr.*;
        parts[i] = .{
            .part_number = p.part_number,
            .size = p.size,
            .etag = p.etag,
            .last_modified_unix = p.last_modified_unix,
        };
    }
    const doc: ManifestDoc = .{
        .key = state.key,
        .content_type = state.content_type,
        .user_metadata = state.user_metadata,
        .initiated_unix = state.initiated_unix,
        .parts = parts,
        .tags = state.tags,
        .acl = state.acl,
        .retention_mode = state.retention_mode,
        .retain_until_unix = state.retain_until_unix,
        .legal_hold = state.legal_hold,
        .sse_algorithm = state.sse_algorithm,
        .sse_kms_key_id = state.sse_kms_key_id,
        .initiator_id = state.initiator_id,
        .initiator_display_name = state.initiator_display_name,
    };
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.fmt(doc, .{}).format(&aw.writer);

    var path_buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/s3/{s}/multipart/{s}/manifest.json", .{ self.base_dir, bucket, upload_id });
    try writeAtomic(self.io, path, aw.written());
}

fn rebuildUploadIndex(self: *Fs, slot: *BucketSlot) !void {
    var buf: [4096]u8 = undefined;
    const multipart_path = try std.fmt.bufPrint(&buf, "{s}/s3/{s}/multipart", .{ self.base_dir, slot.meta.name });
    var dir = Io.Dir.cwd().openDir(self.io, multipart_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        var path_buf: [4096]u8 = undefined;
        const manifest_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/manifest.json", .{ multipart_path, entry.name });
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer self.allocator.free(bytes);

        var parsed = std.json.parseFromSlice(ManifestDoc, self.allocator, bytes, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        const value = parsed.value;

        const acl_dup: ?storage.Acl = if (value.acl) |a|
            try dupeAclOwned(self.allocator, a)
        else
            null;
        var state: MultipartState = .{
            .key = try self.allocator.dupe(u8, value.key),
            .content_type = try self.allocator.dupe(u8, value.content_type),
            .user_metadata = try dupeHeadersStorage(self.allocator, value.user_metadata),
            .initiated_unix = value.initiated_unix,
            .parts = std.AutoHashMap(u32, PartMeta).init(self.allocator),
            .tags = try dupeTagsOwned(self.allocator, value.tags),
            .acl = acl_dup,
            .retention_mode = value.retention_mode,
            .retain_until_unix = value.retain_until_unix,
            .legal_hold = value.legal_hold,
            .sse_algorithm = value.sse_algorithm,
            .sse_kms_key_id = try self.allocator.dupe(u8, value.sse_kms_key_id),
            .initiator_id = try self.allocator.dupe(u8, value.initiator_id),
            .initiator_display_name = try self.allocator.dupe(u8, value.initiator_display_name),
        };
        for (value.parts) |p| {
            const etag_owned = try self.allocator.dupe(u8, p.etag);
            try state.parts.put(p.part_number, .{
                .part_number = p.part_number,
                .size = p.size,
                .etag = etag_owned,
                .last_modified_unix = p.last_modified_unix,
            });
        }

        const id_owned = try self.allocator.dupe(u8, entry.name);
        try slot.uploads.put(id_owned, state);
    }
}

fn dupeHeadersStorage(allocator: Allocator, src: []const storage.Header) ![]storage.Header {
    const out = try allocator.alloc(storage.Header, src.len);
    errdefer allocator.free(out);
    var made: usize = 0;
    errdefer for (out[0..made]) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    };
    for (src) |h| {
        out[made] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value),
        };
        made += 1;
    }
    return out;
}

fn freeHeadersStorage(allocator: Allocator, hs: []storage.Header) void {
    for (hs) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(hs);
}

fn newUploadId(io: Io, allocator: Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, &raw);
    return out;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn newTestFs(tmp: *std.testing.TmpDir) !*Fs {
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    return try Fs.init(testing.allocator, testing.io, buf[0..len]);
}

fn freeObjectMeta(obj: storage.Object) void {
    testing.allocator.free(obj.key);
    testing.allocator.free(obj.etag);
    testing.allocator.free(obj.content_type);
    for (obj.user_metadata) |h| {
        testing.allocator.free(h.name);
        testing.allocator.free(h.value);
    }
    testing.allocator.free(obj.user_metadata);
}

test "fs: create + head + list + delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fs = try newTestFs(&tmp);
    defer fs.deinit();

    try fs.createBucket(.{ .name = "alpha" });
    try fs.headBucket("alpha");

    const buckets = try fs.listBuckets(testing.allocator);
    defer {
        for (buckets) |b| {
            testing.allocator.free(b.name);
            testing.allocator.free(b.region);
        }
        testing.allocator.free(buckets);
    }
    try testing.expectEqual(@as(usize, 1), buckets.len);
    try testing.expectEqualStrings("alpha", buckets[0].name);
    try testing.expectEqualStrings(default_region, buckets[0].region);

    try fs.deleteBucket("alpha");
    try testing.expectError(storage.Error.NoSuchBucket, fs.headBucket("alpha"));
}

test "fs: createBucket validates name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try testing.expectError(storage.Error.InvalidBucketName, fs.createBucket(.{ .name = "Bad_Name" }));
}

test "fs: duplicate create returns BucketAlreadyOwnedByYou" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try fs.createBucket(.{ .name = "dupes" });
    try testing.expectError(storage.Error.BucketAlreadyOwnedByYou, fs.createBucket(.{ .name = "dupes" }));
}

test "fs: delete missing returns NoSuchBucket" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try testing.expectError(storage.Error.NoSuchBucket, fs.deleteBucket("ghost"));
}

test "fs: registry survives reopen + key index rebuild" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    const path = buf[0..len];

    {
        var fs1 = try Fs.init(testing.allocator, testing.io, path);
        defer fs1.deinit();
        try fs1.createBucket(.{ .name = "persist-me" });
        const out = try fs1.putObject(.{
            .bucket = "persist-me",
            .key = "alpha",
            .body = "v1",
            .content_type = "text/plain",
        });
        testing.allocator.free(out.etag);
    }
    {
        var fs2 = try Fs.init(testing.allocator, testing.io, path);
        defer fs2.deinit();
        try fs2.headBucket("persist-me");
        const idx = findBucket(fs2, "persist-me").?;
        try testing.expectEqual(@as(usize, 1), fs2.buckets.items[idx].key_index.items.len);
        try testing.expectEqualStrings("alpha", fs2.buckets.items[idx].key_index.items[0]);
    }
}

test "fs: put + head + get + delete object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();

    try fs.createBucket(.{ .name = "bkt" });
    const out = try fs.putObject(.{
        .bucket = "bkt",
        .key = "hello.txt",
        .body = "hello world",
        .content_type = "text/plain",
    });
    testing.allocator.free(out.etag);

    {
        const meta = try fs.headObject(testing.allocator, .{ .bucket = "bkt", .key = "hello.txt" });
        defer freeObjectMeta(meta);
        try testing.expectEqual(@as(u64, "hello world".len), meta.size);
        try testing.expectEqualStrings("text/plain", meta.content_type);
    }

    {
        const got = try fs.getObject(testing.allocator, .{ .bucket = "bkt", .key = "hello.txt" });
        defer {
            testing.allocator.free(got.body);
            freeObjectMeta(got.meta);
        }
        try testing.expectEqualStrings("hello world", got.body);
    }

    _ = try fs.deleteObject(.{ .bucket = "bkt", .key = "hello.txt" });
    try testing.expectError(storage.Error.NoSuchKey, fs.headObject(testing.allocator, .{ .bucket = "bkt", .key = "hello.txt" }));
    _ = try fs.deleteObject(.{ .bucket = "bkt", .key = "hello.txt" }); // idempotent
}

test "fs: deleteBucket with object → BucketNotEmpty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = try newTestFs(&tmp);
    defer fs.deinit();
    try fs.createBucket(.{ .name = "bkt" });
    const out = try fs.putObject(.{ .bucket = "bkt", .key = "k", .body = "v", .content_type = "text/plain" });
    testing.allocator.free(out.etag);
    try testing.expectError(storage.Error.BucketNotEmpty, fs.deleteBucket("bkt"));
}
