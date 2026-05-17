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
/// SQS queues, in-memory (v0.3.0). Keys are the queue name (owned by
/// the slot itself). Persistence layout:
/// `<base>/sqs/queues/<name>/{attributes,tags}.json` + messages dir.
sqs_queues: std.StringHashMapUnmanaged(*storage.SqsQueueSlot),
/// TTL sweeper state (v0.2.3). The thread runs `ttlSweepLoop` until
/// `sweeper_stop` is set; on each tick it scans every TTL-enabled
/// table and evicts expired items.
ttl_sweep_interval_secs: u32,
sweeper_thread: ?std.Thread,
sweeper_stop: std.atomic.Value(bool),

pub const InitError = error{
    OutOfMemory,
    Io,
    ThreadSpawn,
};

pub const Options = struct {
    /// Default 5s for local-dev responsiveness. AWS uses hours.
    ttl_sweep_interval_seconds: u32 = 5,
    /// Spawn the TTL sweeper thread? Default true in production; tests
    /// use the 3-arg `init` shim which disables the sweeper because the
    /// Zig test runner doesn't tolerate dangling threads at teardown.
    spawn_ttl_sweeper: bool = true,
};

/// Test-friendly init: no background sweeper. Use `initWithOptions` in
/// production / `main.zig`.
pub fn init(allocator: Allocator, io: Io, base_dir: []const u8) InitError!*Fs {
    return initWithOptions(allocator, io, base_dir, .{ .spawn_ttl_sweeper = false });
}

pub fn initWithOptions(allocator: Allocator, io: Io, base_dir: []const u8, opts: Options) InitError!*Fs {
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
        .sqs_queues = .empty,
        .ttl_sweep_interval_secs = opts.ttl_sweep_interval_seconds,
        .sweeper_thread = null,
        .sweeper_stop = .init(false),
    };

    ensureS3Dir(self) catch return InitError.Io;
    loadRegistry(self) catch return InitError.Io;
    ensureDynamoDir(self) catch return InitError.Io;
    ensureBackupsDir(self) catch return InitError.Io;
    loadDynamoTables(self) catch return InitError.Io;
    ensureSqsDir(self) catch return InitError.Io;
    loadSqsQueues(self) catch return InitError.Io;

    if (opts.spawn_ttl_sweeper) {
        self.sweeper_thread = std.Thread.spawn(.{}, ttlSweepLoop, .{self}) catch return InitError.ThreadSpawn;
    }
    return self;
}

pub fn deinit(self: *Fs) void {
    if (self.sweeper_thread) |t| {
        self.sweeper_stop.store(true, .release);
        t.join();
    }
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
    {
        var it = self.sqs_queues.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sqs_queues.deinit(self.allocator);
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

/// SQS-flavoured view of the same `Fs` (v0.3.0). Persistence path is
/// `<data_dir>/profiles/<profile>/sqs/queues/...`, parallel to S3
/// and DynamoDB.
pub fn sqsBackend(self: *Fs) storage.SqsBackend {
    return .{ .ctx = self, .vtable = &sqs_vtable };
}

const sqs_vtable: storage.SqsBackend.VTable = .{
    .createQueue = vtSqsCreateQueue,
    .deleteQueue = vtSqsDeleteQueue,
    .listQueues = vtSqsListQueues,
    .getQueueUrl = vtSqsGetQueueUrl,
    .getQueueAttributes = vtSqsGetQueueAttributes,
    .setQueueAttributes = vtSqsSetQueueAttributes,
    .purgeQueue = vtSqsPurgeQueue,
    .sendMessage = vtSqsSendMessage,
    .receiveMessage = vtSqsReceiveMessage,
    .deleteMessage = vtSqsDeleteMessage,
    .changeMessageVisibility = vtSqsChangeMessageVisibility,
    .tagQueue = vtSqsTagQueue,
    .untagQueue = vtSqsUntagQueue,
    .listQueueTags = vtSqsListQueueTags,
};

fn vtSqsCreateQueue(ctx: *anyopaque, in: storage.CreateQueueInput) storage.Error!*const storage.SqsQueueSlot {
    return sqsCreateQueue(@ptrCast(@alignCast(ctx)), in);
}
fn vtSqsDeleteQueue(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return sqsDeleteQueue(@ptrCast(@alignCast(ctx)), name);
}
fn vtSqsListQueues(ctx: *anyopaque, allocator: Allocator, in: storage.ListQueuesInput) storage.Error!storage.ListQueuesOutput {
    return sqsListQueues(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtSqsGetQueueUrl(ctx: *anyopaque, name: []const u8) storage.Error!*const storage.SqsQueueSlot {
    return sqsGetQueueUrl(@ptrCast(@alignCast(ctx)), name);
}
fn vtSqsGetQueueAttributes(ctx: *anyopaque, name: []const u8) storage.Error!storage.QueueAttributes {
    return sqsGetQueueAttributes(@ptrCast(@alignCast(ctx)), name);
}
fn vtSqsSetQueueAttributes(ctx: *anyopaque, in: storage.SetQueueAttributesInput) storage.Error!void {
    return sqsSetQueueAttributes(@ptrCast(@alignCast(ctx)), in);
}
fn vtSqsPurgeQueue(ctx: *anyopaque, name: []const u8) storage.Error!void {
    return sqsPurgeQueue(@ptrCast(@alignCast(ctx)), name);
}
fn vtSqsSendMessage(ctx: *anyopaque, allocator: Allocator, in: storage.SendMessageInput) storage.Error!storage.SendMessageOutput {
    return sqsSendMessage(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtSqsReceiveMessage(ctx: *anyopaque, allocator: Allocator, in: storage.ReceiveMessageInput) storage.Error!storage.ReceiveMessageOutput {
    return sqsReceiveMessage(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtSqsDeleteMessage(ctx: *anyopaque, in: storage.DeleteMessageInput) storage.Error!void {
    return sqsDeleteMessage(@ptrCast(@alignCast(ctx)), in);
}
fn vtSqsChangeMessageVisibility(ctx: *anyopaque, in: storage.ChangeMessageVisibilityInput) storage.Error!void {
    return sqsChangeMessageVisibility(@ptrCast(@alignCast(ctx)), in);
}
fn vtSqsTagQueue(ctx: *anyopaque, in: storage.TagQueueInput) storage.Error!void {
    return sqsTagQueue(@ptrCast(@alignCast(ctx)), in);
}
fn vtSqsUntagQueue(ctx: *anyopaque, in: storage.UntagQueueInput) storage.Error!void {
    return sqsUntagQueue(@ptrCast(@alignCast(ctx)), in);
}
fn vtSqsListQueueTags(ctx: *anyopaque, allocator: Allocator, queue_name: []const u8) storage.Error!storage.ListQueueTagsOutput {
    return sqsListQueueTags(@ptrCast(@alignCast(ctx)), allocator, queue_name);
}

const dynamo_vtable: storage.DynamoBackend.VTable = .{
    .listTables = vtDdbListTables,
    .createTable = vtDdbCreateTable,
    .describeTable = vtDdbDescribeTable,
    .deleteTable = vtDdbDeleteTable,
    .updateTable = vtDdbUpdateTable,
    .putItem = vtDdbPutItem,
    .getItem = vtDdbGetItem,
    .deleteItem = vtDdbDeleteItem,
    .updateItem = vtDdbUpdateItem,
    .query = vtDdbQuery,
    .transactGetItems = vtDdbTransactGet,
    .transactWriteItems = vtDdbTransactWrite,
    .listStreams = vtDdbListStreams,
    .describeStream = vtDdbDescribeStream,
    .getShardIterator = vtDdbGetShardIterator,
    .getRecords = vtDdbGetRecords,
    .updateTimeToLive = vtDdbUpdateTimeToLive,
    .describeTimeToLive = vtDdbDescribeTimeToLive,
    .createBackup = vtDdbCreateBackup,
    .listBackups = vtDdbListBackups,
    .describeBackup = vtDdbDescribeBackup,
    .deleteBackup = vtDdbDeleteBackup,
    .restoreTableFromBackup = vtDdbRestoreFromBackup,
    .updateContinuousBackups = vtDdbUpdateContinuousBackups,
    .describeContinuousBackups = vtDdbDescribeContinuousBackups,
    .restoreTableToPointInTime = vtDdbRestoreToPit,
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
fn vtDdbPutItem(ctx: *anyopaque, allocator: Allocator, in: storage.PutItemInput) storage.Error!storage.PutItemResult {
    return ddbPutItem(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbGetItem(ctx: *anyopaque, allocator: Allocator, in: storage.GetItemInput) storage.Error!storage.GetItemResult {
    return ddbGetItem(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbDeleteItem(ctx: *anyopaque, allocator: Allocator, in: storage.DeleteItemInput) storage.Error!storage.DeleteItemResult {
    return ddbDeleteItem(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbUpdateItem(ctx: *anyopaque, allocator: Allocator, in: storage.UpdateItemInput) storage.Error!storage.UpdateItemResult {
    return ddbUpdateItem(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbQuery(ctx: *anyopaque, allocator: Allocator, in: storage.QueryInput) storage.Error!storage.QueryResult {
    return ddbQuery(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbTransactGet(ctx: *anyopaque, allocator: Allocator, ops: []const storage.TxGetItem) storage.Error!storage.TxGetResult {
    return ddbTransactGet(@ptrCast(@alignCast(ctx)), allocator, ops);
}
fn vtDdbTransactWrite(ctx: *anyopaque, allocator: Allocator, ops: []const storage.TxWriteOp, reasons_out: *[]?[]const u8) storage.Error!void {
    return ddbTransactWrite(@ptrCast(@alignCast(ctx)), allocator, ops, reasons_out);
}
fn vtDdbListStreams(ctx: *anyopaque, allocator: Allocator, in: storage.ListStreamsInput) storage.Error!storage.ListStreamsOutput {
    return ddbListStreams(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbDescribeStream(ctx: *anyopaque, allocator: Allocator, in: storage.DescribeStreamInput) storage.Error!storage.DescribeStreamOutput {
    return ddbDescribeStream(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbGetShardIterator(ctx: *anyopaque, allocator: Allocator, in: storage.GetShardIteratorInput) storage.Error![]const u8 {
    return ddbGetShardIterator(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbGetRecords(ctx: *anyopaque, allocator: Allocator, in: storage.GetRecordsInput) storage.Error!storage.GetRecordsOutput {
    return ddbGetRecords(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbUpdateTimeToLive(ctx: *anyopaque, in: storage.UpdateTimeToLiveInput) storage.Error!storage.dynamo_state.TimeToLiveSpec {
    return ddbUpdateTimeToLive(@ptrCast(@alignCast(ctx)), in);
}
fn vtDdbDescribeTimeToLive(ctx: *anyopaque, name: []const u8) storage.Error!?storage.dynamo_state.TimeToLiveSpec {
    return ddbDescribeTimeToLive(@ptrCast(@alignCast(ctx)), name);
}
fn vtDdbCreateBackup(ctx: *anyopaque, allocator: Allocator, in: storage.CreateBackupInput) storage.Error!storage.BackupSummary {
    return ddbCreateBackup(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbListBackups(ctx: *anyopaque, allocator: Allocator, in: storage.ListBackupsInput) storage.Error!storage.ListBackupsOutput {
    return ddbListBackups(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbDescribeBackup(ctx: *anyopaque, allocator: Allocator, arn: []const u8) storage.Error!storage.BackupDescription {
    return ddbDescribeBackup(@ptrCast(@alignCast(ctx)), allocator, arn);
}
fn vtDdbDeleteBackup(ctx: *anyopaque, allocator: Allocator, arn: []const u8) storage.Error!storage.BackupDescription {
    return ddbDeleteBackup(@ptrCast(@alignCast(ctx)), allocator, arn);
}
fn vtDdbRestoreFromBackup(ctx: *anyopaque, allocator: Allocator, in: storage.RestoreTableFromBackupInput) storage.Error!*const storage.TableSlot {
    return ddbRestoreTableFromBackup(@ptrCast(@alignCast(ctx)), allocator, in);
}
fn vtDdbUpdateContinuousBackups(ctx: *anyopaque, in: storage.UpdateContinuousBackupsInput) storage.Error!storage.ContinuousBackupsDescription {
    return ddbUpdateContinuousBackups(@ptrCast(@alignCast(ctx)), in);
}
fn vtDdbDescribeContinuousBackups(ctx: *anyopaque, name: []const u8) storage.Error!storage.ContinuousBackupsDescription {
    return ddbDescribeContinuousBackups(@ptrCast(@alignCast(ctx)), name);
}
fn vtDdbRestoreToPit(ctx: *anyopaque, allocator: Allocator, in: storage.RestoreTableToPointInTimeInput) storage.Error!*const storage.TableSlot {
    return ddbRestoreTableToPointInTime(@ptrCast(@alignCast(ctx)), allocator, in);
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

fn ensureBackupsDir(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/dynamodb/backups", .{self.base_dir});
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
    /// Streams config. `stream_enabled = null` ⇔ never configured.
    /// `stream_enabled_unix` is non-null whenever a spec has ever been
    /// applied (used to derive LatestStreamLabel / ARN).
    stream_enabled: ?bool = null,
    stream_view_type: ?[]const u8 = null,
    stream_enabled_unix: ?i64 = null,
    /// TTL config (v0.2.3). `ttl_status` ∈ {"ENABLED", "DISABLED"};
    /// we never persist the transient ENABLING / DISABLING states
    /// because we snap directly to the terminal state. Null when never
    /// configured.
    ttl_status: ?[]const u8 = null,
    ttl_attribute_name: ?[]const u8 = null,
    /// PITR / continuous backups (v0.2.5). pitr_status ∈ {"ENABLED",
    /// "DISABLED"}. `pitr_enabled_unix` is non-null whenever PITR has
    /// ever been enabled (used to derive EarliestRestorableDateTime).
    pitr_status: ?[]const u8 = null,
    pitr_enabled_unix: ?i64 = null,
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
        .stream_enabled = if (slot.stream_spec) |sp| sp.enabled else null,
        .stream_view_type = if (slot.stream_spec) |sp| sp.view_type.toAws() else null,
        .stream_enabled_unix = slot.stream_enabled_unix,
        .ttl_status = if (slot.ttl_spec) |sp| sp.status.toAws() else null,
        .ttl_attribute_name = if (slot.ttl_spec) |sp| sp.attribute_name else null,
        .pitr_status = slot.continuous_backup.pitr_status.toAws(),
        .pitr_enabled_unix = slot.continuous_backup.enabled_unix,
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

    // Streams: spec persists, records do not. If the spec is enabled,
    // attach a fresh (empty) ring buffer.
    if (slot_ptr.stream_spec) |spec| if (spec.enabled) {
        attachStream(self, slot_ptr) catch {};
    };

    // Map key shares ownership with slot.name.
    try self.dynamo_tables.put(self.allocator, slot_ptr.name, slot_ptr);

    // v0.2.1: rebuild the in-memory items map by walking <table>/items/*.json.
    // Corrupted files are skipped with a warning — same policy as schema.json.
    try loadTableItems(self, slot_ptr);
}

fn loadTableItems(self: *Fs, slot: *storage.TableSlot) !void {
    var dir_buf: [4096]u8 = undefined;
    const items_path = try std.fmt.bufPrint(&dir_buf, "{s}/dynamodb/tables/{s}/items", .{ self.base_dir, slot.name });

    var dir = Io.Dir.cwd().openDir(self.io, items_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // freshly created table with no items yet
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        loadSingleItem(self, slot, entry.name) catch |err| {
            std.log.warn("dynamodb: skipping corrupted item file {s}/items/{s}: {s}", .{
                slot.name, entry.name, @errorName(err),
            });
        };
    }
}

fn loadSingleItem(self: *Fs, slot: *storage.TableSlot, file_name: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/dynamodb/tables/{s}/items/{s}", .{ self.base_dir, slot.name, file_name });

    const body = try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(4 * 1024 * 1024));
    defer self.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedItemFile;
    const obj = parsed.value.object;

    // Build an Item from the JSON object: each (name, AttributeValue) pair.
    const n = obj.count();
    const names = try self.allocator.alloc([]const u8, n);
    var names_done: usize = 0;
    errdefer {
        for (names[0..names_done]) |nm| self.allocator.free(nm);
        self.allocator.free(names);
    }
    const values = try self.allocator.alloc(@import("../wire/dynamodb/attribute_value.zig").AttributeValue, n);
    var values_done: usize = 0;
    errdefer {
        for (values[0..values_done]) |*v| {
            var copy = v.*;
            @import("../wire/dynamodb/attribute_value.zig").deinit(self.allocator, &copy);
        }
        self.allocator.free(values);
    }
    var entry_it = obj.iterator();
    var i: usize = 0;
    while (entry_it.next()) |entry| : (i += 1) {
        names[i] = try self.allocator.dupe(u8, entry.key_ptr.*);
        names_done = i + 1;
        values[i] = try @import("../wire/dynamodb/attribute_value.zig").parseValue(self.allocator, entry.value_ptr.*);
        values_done = i + 1;
    }

    const item_ptr = try self.allocator.create(storage.Item);
    item_ptr.* = .{ .names = names, .values = values };

    // Compute the composite key the same way ddbPutItem does so post-restart
    // lookups hit. If the item lacks key attributes (shouldn't happen — write
    // path validates), surface as MalformedItemFile so the warn-and-skip path
    // fires.
    const key_str = storage.dynamo_state.buildItemKey(self.allocator, slot, item_ptr) catch {
        item_ptr.deinit(self.allocator);
        self.allocator.destroy(item_ptr);
        return error.MalformedItemFile;
    };

    slot.items.put(self.allocator, key_str, item_ptr) catch {
        self.allocator.free(key_str);
        item_ptr.deinit(self.allocator);
        self.allocator.destroy(item_ptr);
        return error.OutOfMemory;
    };
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

    const stream_spec: ?ddb.dynamo_state.StreamSpecification = if (doc.stream_enabled) |enabled| .{
        .enabled = enabled,
        .view_type = if (doc.stream_view_type) |vt|
            ddb.dynamo_state.StreamViewType.fromAws(vt) orelse .new_and_old_images
        else
            .new_and_old_images,
    } else null;

    const ttl_spec: ?ddb.dynamo_state.TimeToLiveSpec = blk: {
        const status_str = doc.ttl_status orelse break :blk null;
        const status: ddb.dynamo_state.TimeToLiveStatus = if (std.mem.eql(u8, status_str, "ENABLED"))
            .enabled
        else
            .disabled;
        const attr_src = doc.ttl_attribute_name orelse "";
        break :blk .{
            .status = status,
            .attribute_name = try allocator.dupe(u8, attr_src),
        };
    };

    const pitr: ddb.dynamo_state.ContinuousBackupSpec = blk: {
        const status_str = doc.pitr_status orelse break :blk .{};
        const status: ddb.dynamo_state.PitrStatus = if (std.mem.eql(u8, status_str, "ENABLED"))
            .enabled
        else
            .disabled;
        break :blk .{ .pitr_status = status, .enabled_unix = doc.pitr_enabled_unix };
    };

    return .{
        .name = name,
        .key_schema = ks,
        .attribute_definitions = ad,
        .billing_mode = ddb.dynamo_state.BillingMode.fromAws(doc.billing_mode) orelse .pay_per_request,
        .global_secondary_indexes = gsis,
        .local_secondary_indexes = lsis,
        .tags = tags,
        .stream_spec = stream_spec,
        .stream_enabled_unix = doc.stream_enabled_unix,
        .ttl_spec = ttl_spec,
        .continuous_backup = pitr,
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

    // If streams were enabled at create, allocate the in-memory ring.
    if (slot_ptr.stream_spec) |spec| if (spec.enabled) {
        attachStream(self, slot_ptr) catch {
            slot_ptr.deinit(self.allocator);
            self.allocator.destroy(slot_ptr);
            return storage.Error.OutOfMemory;
        };
    };

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

/// Allocate + attach a Stream to a slot. Caller must guarantee
/// `slot.stream_spec.?.enabled and slot.stream_enabled_unix != null`.
/// Tears down any prior stream on the same slot.
fn attachStream(self: *Fs, slot: *storage.TableSlot) !void {
    if (slot.stream) |old| {
        old.deinit();
        self.allocator.destroy(old);
        slot.stream = null;
    }
    const enable_unix = slot.stream_enabled_unix orelse return;
    const view_type = slot.stream_spec.?.view_type;
    const shard_id = try storage.dynamo_streams.formatShardId(self.allocator, enable_unix);
    defer self.allocator.free(shard_id);
    const stream_ptr = try self.allocator.create(storage.Stream);
    errdefer self.allocator.destroy(stream_ptr);
    stream_ptr.* = try storage.Stream.init(self.allocator, view_type, shard_id);
    slot.stream = stream_ptr;
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
        .stream_spec = in.stream_spec,
        .stream_enabled_unix = if (in.stream_spec) |sp| (if (sp.enabled) created_unix else null) else null,
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
    if (in.stream_spec) |sp| {
        slot.stream_spec = sp;
        // Re-stamp the enable timestamp on any enable→enable or
        // disable→enable transition so the LatestStreamLabel matches
        // observed AWS behaviour. Disable leaves the prior timestamp
        // in place — AWS keeps the label around until streams are
        // re-enabled.
        if (sp.enabled) {
            slot.stream_enabled_unix = nowUnixSeconds(self.io);
            attachStream(self, slot) catch return storage.Error.OutOfMemory;
        } else if (slot.stream) |old| {
            old.deinit();
            self.allocator.destroy(old);
            slot.stream = null;
        }
    }
    writeSchemaJson(self, slot) catch return storage.Error.Io;
    return slot;
}

// ---------------------------------------------------------------------------
// DynamoDB item operations (M15-items, Phase 3)
//
// Items live in-memory in `slot.items` and are persisted to
// <table>/items/<safe_key>.json. The "safe key" is sha256 hex of the
// composite key string — avoids filename-encoding nightmares and keeps
// the dir flat.

const ddb_attr = @import("../wire/dynamodb/attribute_value.zig");
const wire_tables = @import("../wire/dynamodb/tables.zig");

fn itemKeyHash(key: []const u8) [64]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(key);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn itemPath(self: *Fs, table: []const u8, key_hash: *const [64]u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/dynamodb/tables/{s}/items/{s}.json", .{ self.base_dir, table, key_hash });
}

fn writeItemJson(self: *Fs, table: []const u8, key_hash: *const [64]u8, item: *const storage.Item) !void {
    var dir_buf: [4096]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/dynamodb/tables/{s}/items", .{ self.base_dir, table });
    try Io.Dir.cwd().createDirPath(self.io, dir_path);

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try renderItem(&s, self.allocator, item);
    const body = aw.toOwnedSlice() catch return error.OutOfMemory;
    defer self.allocator.free(body);

    var path_buf: [4096]u8 = undefined;
    const path = try itemPath(self, table, key_hash, &path_buf);
    try writeAtomic(self.io, path, body);
}

fn renderItem(s: *std.json.Stringify, allocator: Allocator, item: *const storage.Item) !void {
    try s.beginObject();
    for (item.names, item.values) |name, value| {
        try s.objectField(name);
        try ddb_attr.renderValue(s, allocator, value);
    }
    try s.endObject();
}

fn cloneItem(allocator: Allocator, item: *const storage.Item) !storage.Item {
    return storage.dynamo_state.cloneItem(allocator, item);
}

pub fn ddbPutItem(self: *Fs, allocator: Allocator, in: storage.PutItemInput) storage.Error!storage.PutItemResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.table) orelse return storage.Error.TableNotFound;

    // Build the composite key from the item's key attributes.
    const key_str = storage.dynamo_state.buildItemKey(self.allocator, slot, in.item) catch
        return storage.Error.OutOfMemory;
    errdefer self.allocator.free(key_str);

    // Condition check (under the mutex, against the in-memory state).
    if (in.condition) |c| {
        const existing_ptr: ?*const storage.Item = slot.items.get(key_str);
        if (!c.evaluate(existing_ptr)) return storage.Error.ConditionalCheckFailed;
    }

    var result: storage.PutItemResult = .{};
    var had_existing = false;

    // If an item already exists at this key, surface it as old_item (using
    // the caller's allocator) and free the in-memory copy.
    if (slot.items.fetchRemove(key_str)) |existing| {
        had_existing = true;
        result.old_item = cloneItem(allocator, existing.value) catch return storage.Error.OutOfMemory;
        self.allocator.free(existing.key);
        existing.value.deinit(self.allocator);
        self.allocator.destroy(existing.value);
    }

    // Deep-copy the new item into long-lived state.
    const owned = cloneItem(self.allocator, in.item) catch return storage.Error.OutOfMemory;
    const owned_ptr = self.allocator.create(storage.Item) catch return storage.Error.OutOfMemory;
    owned_ptr.* = owned;

    const key_hash = itemKeyHash(key_str);
    writeItemJson(self, slot.name, &key_hash, owned_ptr) catch {
        owned_ptr.deinit(self.allocator);
        self.allocator.destroy(owned_ptr);
        self.allocator.free(key_str);
        return storage.Error.Io;
    };

    slot.items.put(self.allocator, key_str, owned_ptr) catch return storage.Error.OutOfMemory;

    captureWrite(self, slot, if (had_existing) .modify else .insert, in.item, if (result.old_item) |*oi| oi else null, owned_ptr, .user);
    return result;
}

/// Stream capture wrapper — no-op when the slot has no attached stream.
/// `kind` is the AWS-flavoured INSERT / MODIFY / REMOVE; `key_src`
/// supplies the keys (we project them down to the table's KeySchema);
/// `old_item` / `new_item` are the pre-/post-images (either may be
/// null for inserts / deletes respectively). The Stream itself decides
/// what to keep based on view-type.
fn captureWrite(
    self: *Fs,
    slot: *storage.TableSlot,
    kind: storage.dynamo_streams.RecordKind,
    key_src: *const storage.Item,
    old_item: ?*const storage.Item,
    new_item: ?*const storage.Item,
    identity: storage.dynamo_streams.UserIdentity,
) void {
    const stream = slot.stream orelse return;
    var keys = storage.dynamo_state.projectKeys(self.allocator, slot, key_src) catch return;
    defer keys.deinit(self.allocator);
    _ = stream.capture(kind, &keys, new_item, old_item, nowUnixSeconds(self.io), identity) catch {};
}

pub fn ddbGetItem(self: *Fs, allocator: Allocator, in: storage.GetItemInput) storage.Error!storage.GetItemResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.table) orelse return storage.Error.TableNotFound;
    const key_str = storage.dynamo_state.buildKeyFromAttrs(self.allocator, slot, in.key) catch
        return storage.Error.OutOfMemory;
    defer self.allocator.free(key_str);

    const stored = slot.items.get(key_str) orelse return .{ .item = null };
    return .{ .item = cloneItem(allocator, stored) catch return storage.Error.OutOfMemory };
}

pub fn ddbDeleteItem(self: *Fs, allocator: Allocator, in: storage.DeleteItemInput) storage.Error!storage.DeleteItemResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.table) orelse return storage.Error.TableNotFound;
    const key_str = storage.dynamo_state.buildKeyFromAttrs(self.allocator, slot, in.key) catch
        return storage.Error.OutOfMemory;
    defer self.allocator.free(key_str);

    if (in.condition) |c| {
        const existing_ptr: ?*const storage.Item = slot.items.get(key_str);
        if (!c.evaluate(existing_ptr)) return storage.Error.ConditionalCheckFailed;
    }

    const removed = slot.items.fetchRemove(key_str) orelse return .{ .old_item = null };

    // Delete the on-disk file (best-effort: missing is fine).
    const key_hash = itemKeyHash(key_str);
    var path_buf: [4096]u8 = undefined;
    const path = itemPath(self, slot.name, &key_hash, &path_buf) catch return storage.Error.Io;
    Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return storage.Error.Io,
    };

    const old = cloneItem(allocator, removed.value) catch return storage.Error.OutOfMemory;
    self.allocator.free(removed.key);
    removed.value.deinit(self.allocator);
    self.allocator.destroy(removed.value);

    captureWrite(self, slot, .remove, in.key, &old, null, .user);
    return .{ .old_item = old };
}

/// UpdateItem: under the mutex, build a writable clone of the existing
/// item (or a fresh key-only item), run the caller-supplied applier,
/// then persist the result. The applier returns false → ApplyError-class
/// failure surfaced as ValidationException by the service.
pub fn ddbUpdateItem(self: *Fs, allocator: Allocator, in: storage.UpdateItemInput) storage.Error!storage.UpdateItemResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.table) orelse return storage.Error.TableNotFound;
    const key_str = storage.dynamo_state.buildKeyFromAttrs(self.allocator, slot, in.key) catch
        return storage.Error.OutOfMemory;
    errdefer self.allocator.free(key_str);

    const existing_ptr: ?*const storage.Item = slot.items.get(key_str);

    if (in.condition) |c| {
        if (!c.evaluate(existing_ptr)) return storage.Error.ConditionalCheckFailed;
    }

    var result: storage.UpdateItemResult = .{};

    // Build a writable working item. Start from existing (deep clone)
    // or the key-only Item if absent (UpdateItem creates if missing).
    var working: storage.Item = if (existing_ptr) |ep|
        cloneItem(allocator, ep) catch return storage.Error.OutOfMemory
    else
        cloneItem(allocator, in.key) catch return storage.Error.OutOfMemory;

    if (existing_ptr) |ep| {
        result.old_item = cloneItem(allocator, ep) catch return storage.Error.OutOfMemory;
    }

    if (!in.apply_fn(in.apply_ctx, &working)) return storage.Error.ConditionalCheckFailed;

    result.new_item = cloneItem(allocator, &working) catch return storage.Error.OutOfMemory;

    // Persist: deep-copy into long-lived state and write to disk.
    const owned = cloneItem(self.allocator, &working) catch return storage.Error.OutOfMemory;
    const owned_ptr = self.allocator.create(storage.Item) catch return storage.Error.OutOfMemory;
    owned_ptr.* = owned;

    const key_hash = itemKeyHash(key_str);
    writeItemJson(self, slot.name, &key_hash, owned_ptr) catch {
        owned_ptr.deinit(self.allocator);
        self.allocator.destroy(owned_ptr);
        return storage.Error.Io;
    };

    // Replace in-memory.
    if (slot.items.fetchRemove(key_str)) |old| {
        self.allocator.free(old.key);
        old.value.deinit(self.allocator);
        self.allocator.destroy(old.value);
    }
    slot.items.put(self.allocator, key_str, owned_ptr) catch return storage.Error.OutOfMemory;

    const kind: storage.dynamo_streams.RecordKind = if (existing_ptr == null) .insert else .modify;
    captureWrite(self, slot, kind, in.key, if (result.old_item) |*oi| oi else null, owned_ptr, .user);
    return result;
}

/// Query: walk all items, apply key_predicate (must match PK + optional
/// sort-key predicate), sort by sort key, apply optional filter, slice
/// by limit + cursor. Phase 5 walks the whole table; Phase 8 (GSI) adds
/// per-partition indexing for O(K) reads.
pub fn ddbQuery(self: *Fs, allocator: Allocator, in: storage.QueryInput) storage.Error!storage.QueryResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.table) orelse return storage.Error.TableNotFound;

    // Collect all matching items + their composite keys.
    const MatchEntry = struct { item: *const storage.Item, key: []const u8 };
    var matches: std.ArrayList(MatchEntry) = .empty;
    defer matches.deinit(allocator);

    var it = slot.items.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        if (!in.key_predicate.match(item)) continue;
        try matches.append(allocator, .{ .item = item, .key = entry.key_ptr.* });
    }

    // Sort by composite key (which embeds PK + SK). Forward vs reverse.
    const ctx_struct = struct {
        fn lt(_: void, a: MatchEntry, b: MatchEntry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
        fn gt(_: void, a: MatchEntry, b: MatchEntry) bool {
            return std.mem.lessThan(u8, b.key, a.key);
        }
    };
    if (in.forward) {
        std.mem.sort(MatchEntry, matches.items, {}, ctx_struct.lt);
    } else {
        std.mem.sort(MatchEntry, matches.items, {}, ctx_struct.gt);
    }

    // Apply ExclusiveStartKey cursor.
    var start_idx: usize = 0;
    if (in.exclusive_start_key) |cursor| {
        for (matches.items, 0..) |m, i| {
            const after_cursor = if (in.forward)
                std.mem.lessThan(u8, cursor, m.key)
            else
                std.mem.lessThan(u8, m.key, cursor);
            if (after_cursor) {
                start_idx = i;
                break;
            }
        } else start_idx = matches.items.len;
    }

    // Apply filter predicate + limit while collecting output.
    var out: std.ArrayList(storage.Item) = .empty;
    errdefer {
        for (out.items) |*item_to_free| {
            var copy = item_to_free.*;
            copy.deinit(allocator);
        }
        out.deinit(allocator);
    }

    var scanned_count: u32 = 0;
    var last_key: ?[]const u8 = null;
    var idx: usize = start_idx;
    while (idx < matches.items.len) : (idx += 1) {
        const m = matches.items[idx];
        scanned_count += 1;
        if (in.filter_predicate) |f| {
            if (!f.match(m.item)) continue;
        }
        const cloned = cloneItem(allocator, m.item) catch return storage.Error.OutOfMemory;
        try out.append(allocator, cloned);
        last_key = m.key;
        if (in.limit != 0 and out.items.len >= in.limit) {
            idx += 1;
            break;
        }
    }

    const truncated = idx < matches.items.len;
    const cursor_out: ?[]const u8 = if (truncated and last_key != null)
        allocator.dupe(u8, last_key.?) catch return storage.Error.OutOfMemory
    else
        null;

    const count: u32 = @intCast(out.items.len);
    return .{
        .items = out.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory,
        .count = count,
        .scanned_count = scanned_count,
        .last_evaluated_key = cursor_out,
    };
}

/// TransactGetItems: read N items atomically under the mutex.
pub fn ddbTransactGet(self: *Fs, allocator: Allocator, ops: []const storage.TxGetItem) storage.Error!storage.TxGetResult {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const out = allocator.alloc(?storage.Item, ops.len) catch return storage.Error.OutOfMemory;
    for (ops, 0..) |op, i| {
        const slot = self.dynamo_tables.get(op.table) orelse return storage.Error.TableNotFound;
        const key_str = storage.dynamo_state.buildKeyFromAttrs(self.allocator, slot, op.key) catch
            return storage.Error.OutOfMemory;
        defer self.allocator.free(key_str);
        if (slot.items.get(key_str)) |stored| {
            out[i] = cloneItem(allocator, stored) catch return storage.Error.OutOfMemory;
        } else {
            out[i] = null;
        }
    }
    return .{ .items = out };
}

/// TransactWriteItems: validate all conditions, then apply all writes.
/// All-or-nothing atomicity (single mutex hold).
pub fn ddbTransactWrite(
    self: *Fs,
    allocator: Allocator,
    ops: []const storage.TxWriteOp,
    reasons_out: *[]?[]const u8,
) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // Pass 1: validate every condition.
    var any_failed = false;
    const reasons = allocator.alloc(?[]const u8, ops.len) catch return storage.Error.OutOfMemory;
    for (reasons) |*r| r.* = null;

    for (ops, 0..) |op, i| {
        const slot = self.dynamo_tables.get(op.table) orelse {
            reasons[i] = "ResourceNotFound";
            any_failed = true;
            continue;
        };
        if (op.condition) |c| {
            // For put: build key from item; otherwise op.item_or_key IS the key.
            const key_item = op.item_or_key;
            const key_str = storage.dynamo_state.buildKeyFromAttrs(self.allocator, slot, key_item) catch
                return storage.Error.OutOfMemory;
            defer self.allocator.free(key_str);
            const existing_ptr: ?*const storage.Item = slot.items.get(key_str);
            if (!c.evaluate(existing_ptr)) {
                reasons[i] = "ConditionalCheckFailed";
                any_failed = true;
            }
        }
    }

    if (any_failed) {
        reasons_out.* = reasons;
        return storage.Error.TransactionCanceled;
    }

    // Pass 2: apply all writes inline (mutex already held; do NOT call
    // the public ddbPutItem/etc. — they relock and deadlock).
    for (ops) |op| {
        const slot = self.dynamo_tables.get(op.table) orelse return storage.Error.Io;
        switch (op.kind) {
            .put => try applyPutLocked(self, slot, op.item_or_key),
            .delete => try applyDeleteLocked(self, slot, op.item_or_key, .user),
            .update => try applyUpdateLocked(self, allocator, slot, op.item_or_key, op.apply_fn.?, op.apply_ctx.?),
            .condition_check => {}, // validated, nothing to apply
        }
    }
    reasons_out.* = &.{};
}

fn applyPutLocked(self: *Fs, slot: *storage.TableSlot, item: *const storage.Item) storage.Error!void {
    const key_str = storage.dynamo_state.buildItemKey(self.allocator, slot, item) catch
        return storage.Error.OutOfMemory;
    errdefer self.allocator.free(key_str);

    // Snapshot the existing item before mutation so capture can carry
    // it as old_image on a MODIFY.
    var had_existing = false;
    var old_snapshot: storage.Item = undefined;
    if (slot.items.fetchRemove(key_str)) |existing| {
        had_existing = true;
        old_snapshot = cloneItem(self.allocator, existing.value) catch return storage.Error.OutOfMemory;
        self.allocator.free(existing.key);
        existing.value.deinit(self.allocator);
        self.allocator.destroy(existing.value);
    }
    defer if (had_existing) old_snapshot.deinit(self.allocator);

    const owned = cloneItem(self.allocator, item) catch return storage.Error.OutOfMemory;
    const owned_ptr = self.allocator.create(storage.Item) catch return storage.Error.OutOfMemory;
    owned_ptr.* = owned;

    const key_hash = itemKeyHash(key_str);
    writeItemJson(self, slot.name, &key_hash, owned_ptr) catch return storage.Error.Io;

    slot.items.put(self.allocator, key_str, owned_ptr) catch return storage.Error.OutOfMemory;

    captureWrite(self, slot, if (had_existing) .modify else .insert, item, if (had_existing) &old_snapshot else null, owned_ptr, .user);
}

fn applyDeleteLocked(
    self: *Fs,
    slot: *storage.TableSlot,
    key_item: *const storage.Item,
    identity: storage.dynamo_streams.UserIdentity,
) storage.Error!void {
    const key_str = storage.dynamo_state.buildKeyFromAttrs(self.allocator, slot, key_item) catch
        return storage.Error.OutOfMemory;
    defer self.allocator.free(key_str);

    const removed = slot.items.fetchRemove(key_str) orelse return;
    const key_hash = itemKeyHash(key_str);
    var path_buf: [4096]u8 = undefined;
    const path = itemPath(self, slot.name, &key_hash, &path_buf) catch return storage.Error.Io;
    Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return storage.Error.Io,
    };

    // Snapshot the removed item so capture can carry it as old_image.
    var old_snapshot = cloneItem(self.allocator, removed.value) catch return storage.Error.OutOfMemory;
    defer old_snapshot.deinit(self.allocator);

    self.allocator.free(removed.key);
    removed.value.deinit(self.allocator);
    self.allocator.destroy(removed.value);

    captureWrite(self, slot, .remove, key_item, &old_snapshot, null, identity);
}

fn applyUpdateLocked(
    self: *Fs,
    allocator: Allocator,
    slot: *storage.TableSlot,
    key_item: *const storage.Item,
    apply_fn: *const fn (ctx: *anyopaque, item: *storage.Item) bool,
    apply_ctx: *anyopaque,
) storage.Error!void {
    const key_str = storage.dynamo_state.buildKeyFromAttrs(self.allocator, slot, key_item) catch
        return storage.Error.OutOfMemory;
    errdefer self.allocator.free(key_str);

    const existing_ptr: ?*const storage.Item = slot.items.get(key_str);
    var working: storage.Item = if (existing_ptr) |ep|
        cloneItem(allocator, ep) catch return storage.Error.OutOfMemory
    else
        cloneItem(allocator, key_item) catch return storage.Error.OutOfMemory;

    // Snapshot the pre-image for capture.
    var had_existing = false;
    var old_snapshot: storage.Item = undefined;
    if (existing_ptr) |ep| {
        had_existing = true;
        old_snapshot = cloneItem(self.allocator, ep) catch return storage.Error.OutOfMemory;
    }
    defer if (had_existing) old_snapshot.deinit(self.allocator);

    if (!apply_fn(apply_ctx, &working)) return storage.Error.TransactionCanceled;

    const owned = cloneItem(self.allocator, &working) catch return storage.Error.OutOfMemory;
    const owned_ptr = self.allocator.create(storage.Item) catch return storage.Error.OutOfMemory;
    owned_ptr.* = owned;

    const key_hash = itemKeyHash(key_str);
    writeItemJson(self, slot.name, &key_hash, owned_ptr) catch return storage.Error.Io;

    if (slot.items.fetchRemove(key_str)) |old| {
        self.allocator.free(old.key);
        old.value.deinit(self.allocator);
        self.allocator.destroy(old.value);
    }
    slot.items.put(self.allocator, key_str, owned_ptr) catch return storage.Error.OutOfMemory;

    captureWrite(self, slot, if (had_existing) .modify else .insert, key_item, if (had_existing) &old_snapshot else null, owned_ptr, .user);
}

// ---------------------------------------------------------------------------
// DynamoDB Streams sub-service (v0.2.2)

/// Compute the ARN for a stream-enabled slot. Caller owns the returned
/// slice via the supplied allocator.
fn streamArn(allocator: Allocator, region: []const u8, table_name: []const u8, label: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "arn:aws:dynamodb:{s}:000000000000:table/{s}/stream/{s}", .{ region, table_name, label });
}

/// Extract a `(table_name, label)` pair from a stream ARN. Returns
/// `InvalidStreamArn` on any malformed input.
fn parseStreamArn(arn: []const u8) storage.Error!struct { table: []const u8, label: []const u8 } {
    const prefix = "arn:aws:dynamodb:";
    if (!std.mem.startsWith(u8, arn, prefix)) return storage.Error.InvalidStreamArn;
    // skip "<region>:<account>:" → land at "table/..."
    var i = prefix.len;
    var colons: u8 = 0;
    while (i < arn.len and colons < 2) : (i += 1) {
        if (arn[i] == ':') colons += 1;
    }
    if (colons != 2) return storage.Error.InvalidStreamArn;
    // arn[i..] should be `table/<name>/stream/<label>`
    const tail = arn[i..];
    const table_kw = "table/";
    if (!std.mem.startsWith(u8, tail, table_kw)) return storage.Error.InvalidStreamArn;
    const after_table = tail[table_kw.len..];
    const slash_idx = std.mem.indexOfScalar(u8, after_table, '/') orelse return storage.Error.InvalidStreamArn;
    const table_name = after_table[0..slash_idx];
    const after_name = after_table[slash_idx + 1 ..];
    const stream_kw = "stream/";
    if (!std.mem.startsWith(u8, after_name, stream_kw)) return storage.Error.InvalidStreamArn;
    const label = after_name[stream_kw.len..];
    if (table_name.len == 0 or label.len == 0) return storage.Error.InvalidStreamArn;
    return .{ .table = table_name, .label = label };
}

pub fn ddbListStreams(self: *Fs, allocator: Allocator, in: storage.ListStreamsInput) storage.Error!storage.ListStreamsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var summaries: std.ArrayList(storage.StreamSummary) = .empty;
    errdefer {
        for (summaries.items) |s| {
            allocator.free(s.arn);
            allocator.free(s.table_name);
            allocator.free(s.label);
        }
        summaries.deinit(allocator);
    }

    var it = self.dynamo_tables.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        if (in.table_name) |filter| if (!std.mem.eql(u8, slot.name, filter)) continue;
        const spec = slot.stream_spec orelse continue;
        if (!spec.enabled) continue;
        const enable_unix = slot.stream_enabled_unix orelse continue;

        var label_buf: [32]u8 = undefined;
        const label_slice = wire_tables.formatStreamLabel(enable_unix, &label_buf) catch
            return storage.Error.OutOfMemory;
        const label = try allocator.dupe(u8, label_slice);
        errdefer allocator.free(label);
        const arn = try streamArn(allocator, in.region, slot.name, label);
        errdefer allocator.free(arn);
        const table_name = try allocator.dupe(u8, slot.name);
        errdefer allocator.free(table_name);

        try summaries.append(allocator, .{ .arn = arn, .table_name = table_name, .label = label });
    }

    // Sort by ARN for stable pagination.
    std.mem.sort(storage.StreamSummary, summaries.items, {}, struct {
        fn lt(_: void, a: storage.StreamSummary, b: storage.StreamSummary) bool {
            return std.mem.lessThan(u8, a.arn, b.arn);
        }
    }.lt);

    var start: usize = 0;
    if (in.exclusive_start_stream_arn) |cursor| {
        for (summaries.items, 0..) |s, idx| {
            if (std.mem.eql(u8, s.arn, cursor)) {
                start = idx + 1;
                break;
            }
        }
    }
    const end = @min(start + in.limit, summaries.items.len);

    // Slice into the page; free the items outside the page.
    const owned_slice = summaries.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory;
    // Free trailing items.
    if (end < owned_slice.len) {
        for (owned_slice[end..]) |s| {
            allocator.free(s.arn);
            allocator.free(s.table_name);
            allocator.free(s.label);
        }
    }
    // Free leading items (before the cursor).
    for (owned_slice[0..start]) |s| {
        allocator.free(s.arn);
        allocator.free(s.table_name);
        allocator.free(s.label);
    }
    // Build the page as a fresh slice referencing the kept items.
    const page = allocator.alloc(storage.StreamSummary, end - start) catch return storage.Error.OutOfMemory;
    for (owned_slice[start..end], 0..) |s, i| page[i] = s;
    const next_arn: ?[]const u8 = if (end < owned_slice.len)
        // Last item in the page IS the LastEvaluatedStreamArn cursor.
        try allocator.dupe(u8, page[page.len - 1].arn)
    else
        null;
    allocator.free(owned_slice);
    return .{ .streams = page, .last_evaluated_stream_arn = next_arn };
}

pub fn ddbDescribeStream(self: *Fs, allocator: Allocator, in: storage.DescribeStreamInput) storage.Error!storage.DescribeStreamOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const parts = try parseStreamArn(in.arn);
    const slot = self.dynamo_tables.get(parts.table) orelse return storage.Error.StreamNotFound;
    const spec = slot.stream_spec orelse return storage.Error.StreamNotFound;
    const enable_unix = slot.stream_enabled_unix orelse return storage.Error.StreamNotFound;

    var label_buf: [32]u8 = undefined;
    const current_label = wire_tables.formatStreamLabel(enable_unix, &label_buf) catch
        return storage.Error.OutOfMemory;
    if (!std.mem.eql(u8, current_label, parts.label)) return storage.Error.StreamNotFound;

    const stream = slot.stream orelse return storage.Error.StreamNotFound;

    // Build shard description. We always have exactly one open shard.
    var shards: []storage.ShardDescription = try allocator.alloc(storage.ShardDescription, 1);
    errdefer allocator.free(shards);
    const start_seq = if (stream.records.items.len == 0)
        try formatSeq(allocator, 0)
    else
        try formatSeq(allocator, stream.records.items[0].seq);
    shards[0] = .{
        .shard_id = try allocator.dupe(u8, stream.shard_id),
        .starting_sequence_number = start_seq,
        .ending_sequence_number = null, // open shard
    };

    // Clone the key schema.
    const ks_out = try allocator.alloc(storage.dynamo_state.KeyAttribute, slot.key_schema.len);
    for (slot.key_schema, 0..) |k, i| ks_out[i] = .{
        .name = try allocator.dupe(u8, k.name),
        .key_type = k.key_type,
    };

    return .{
        .arn = try allocator.dupe(u8, in.arn),
        .label = try allocator.dupe(u8, parts.label),
        .status = if (spec.enabled) .enabled else .disabled,
        .view_type = spec.view_type,
        .creation_request_unix = enable_unix,
        .table_name = try allocator.dupe(u8, slot.name),
        .key_schema = ks_out,
        .shards = shards,
        .last_evaluated_shard_id = null,
    };
}

/// Sequence numbers render as 21-digit zero-padded decimals to match
/// AWS's observed format.
fn formatSeq(allocator: Allocator, seq: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d:0>21}", .{seq});
}

pub fn ddbGetShardIterator(self: *Fs, allocator: Allocator, in: storage.GetShardIteratorInput) storage.Error![]const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const parts = try parseStreamArn(in.arn);
    const slot = self.dynamo_tables.get(parts.table) orelse return storage.Error.StreamNotFound;
    const stream = slot.stream orelse return storage.Error.StreamNotFound;
    if (!std.mem.eql(u8, stream.shard_id, in.shard_id)) return storage.Error.ShardNotFound;

    const seq_or_zero: u64 = if (in.sequence_number) |s|
        std.fmt.parseInt(u64, s, 10) catch return storage.Error.InvalidShardIterator
    else
        0;

    const pos: storage.dynamo_streams.Stream.Position = switch (in.iterator_type) {
        .trim_horizon => .trim_horizon,
        .latest => .{ .after_seq = stream.latestSeq() },
        .at_sequence_number => .{ .at_seq = seq_or_zero },
        .after_sequence_number => .{ .after_seq = seq_or_zero },
    };

    return try encodeIterator(allocator, in.arn, in.shard_id, pos);
}

pub fn ddbGetRecords(self: *Fs, allocator: Allocator, in: storage.GetRecordsInput) storage.Error!storage.GetRecordsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const decoded = decodeIterator(allocator, in.shard_iterator) catch return storage.Error.InvalidShardIterator;
    defer {
        allocator.free(decoded.arn);
        allocator.free(decoded.shard_id);
    }
    const parts = try parseStreamArn(decoded.arn);
    const slot = self.dynamo_tables.get(parts.table) orelse return storage.Error.StreamNotFound;
    const stream = slot.stream orelse return storage.Error.StreamNotFound;
    if (!std.mem.eql(u8, stream.shard_id, decoded.shard_id)) return storage.Error.ShardNotFound;

    var read_result = stream.read(allocator, decoded.position, in.limit) catch return storage.Error.OutOfMemory;
    defer read_result.deinit(allocator);

    var out_records: []storage.StreamRecordOut = try allocator.alloc(storage.StreamRecordOut, read_result.records.len);
    var produced: usize = 0;
    errdefer {
        for (out_records[0..produced]) |*r| {
            allocator.free(r.seq);
            r.keys.deinit(allocator);
            if (r.new_image) |*ni| ni.deinit(allocator);
            if (r.old_image) |*oi| oi.deinit(allocator);
        }
        allocator.free(out_records);
    }
    for (read_result.records, 0..) |src, i| {
        out_records[i] = .{
            .seq = try formatSeq(allocator, src.seq),
            .kind = src.kind,
            .keys = try storage.dynamo_state.cloneItem(allocator, &src.keys),
            .new_image = if (src.new_image) |ni| try storage.dynamo_state.cloneItem(allocator, &ni) else null,
            .old_image = if (src.old_image) |oi| try storage.dynamo_state.cloneItem(allocator, &oi) else null,
            .created_unix = src.created_unix,
            .identity = src.identity,
        };
        produced = i + 1;
    }

    // Open shard → always a non-null next iterator.
    const next_iter = encodeIterator(allocator, decoded.arn, decoded.shard_id, read_result.next_position) catch
        return storage.Error.OutOfMemory;

    return .{ .records = out_records, .next_shard_iterator = next_iter };
}

const IteratorBlob = struct {
    arn: []const u8,
    shard_id: []const u8,
    position: storage.dynamo_streams.Stream.Position,
};

/// Encode + decode the opaque shard-iterator token as base64-url over a
/// pipe-delimited string: `arn|shard|kind|seq`. `kind` ∈ {T,A,L,N}
/// (T=trim_horizon, A=at_seq, N=after_seq; L=after-seq(0) is folded into N).
fn encodeIterator(allocator: Allocator, arn: []const u8, shard_id: []const u8, pos: storage.dynamo_streams.Stream.Position) ![]const u8 {
    var raw_buf: std.ArrayList(u8) = .empty;
    defer raw_buf.deinit(allocator);
    try raw_buf.appendSlice(allocator, arn);
    try raw_buf.append(allocator, '|');
    try raw_buf.appendSlice(allocator, shard_id);
    try raw_buf.append(allocator, '|');
    switch (pos) {
        .trim_horizon => try raw_buf.appendSlice(allocator, "T|0"),
        .at_seq => |s| {
            const tail = try std.fmt.allocPrint(allocator, "A|{d}", .{s});
            defer allocator.free(tail);
            try raw_buf.appendSlice(allocator, tail);
        },
        .after_seq => |s| {
            const tail = try std.fmt.allocPrint(allocator, "N|{d}", .{s});
            defer allocator.free(tail);
            try raw_buf.appendSlice(allocator, tail);
        },
    }
    const enc = std.base64.url_safe_no_pad.Encoder;
    const enc_len = enc.calcSize(raw_buf.items.len);
    const out = try allocator.alloc(u8, enc_len);
    _ = enc.encode(out, raw_buf.items);
    return out;
}

fn decodeIterator(allocator: Allocator, token: []const u8) !IteratorBlob {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const max_len = dec.calcSizeForSlice(token) catch return error.InvalidShardIterator;
    const buf = try allocator.alloc(u8, max_len);
    defer allocator.free(buf);
    dec.decode(buf, token) catch return error.InvalidShardIterator;

    var it = std.mem.splitScalar(u8, buf, '|');
    const arn = it.next() orelse return error.InvalidShardIterator;
    const shard = it.next() orelse return error.InvalidShardIterator;
    const kind = it.next() orelse return error.InvalidShardIterator;
    const seq_s = it.next() orelse return error.InvalidShardIterator;
    if (kind.len != 1) return error.InvalidShardIterator;

    const arn_owned = try allocator.dupe(u8, arn);
    errdefer allocator.free(arn_owned);
    const shard_owned = try allocator.dupe(u8, shard);
    errdefer allocator.free(shard_owned);

    const pos: storage.dynamo_streams.Stream.Position = switch (kind[0]) {
        'T' => .trim_horizon,
        'A' => .{ .at_seq = std.fmt.parseInt(u64, seq_s, 10) catch return error.InvalidShardIterator },
        'N' => .{ .after_seq = std.fmt.parseInt(u64, seq_s, 10) catch return error.InvalidShardIterator },
        else => return error.InvalidShardIterator,
    };
    return .{ .arn = arn_owned, .shard_id = shard_owned, .position = pos };
}

// ---------------------------------------------------------------------------
// DynamoDB TTL (v0.2.3)

pub fn ddbUpdateTimeToLive(self: *Fs, in: storage.UpdateTimeToLiveInput) storage.Error!storage.dynamo_state.TimeToLiveSpec {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.name) orelse return storage.Error.TableNotFound;

    // Free the old attribute_name if any. AWS allows changing the
    // attribute name on a re-enable; we accept any spec the user
    // sends and overwrite. Simpler than modelling the transient
    // DISABLING→ENABLING handoff AWS uses.
    if (slot.ttl_spec) |existing| self.allocator.free(existing.attribute_name);
    const attr_owned = self.allocator.dupe(u8, in.attribute_name) catch return storage.Error.OutOfMemory;
    const new_spec: storage.dynamo_state.TimeToLiveSpec = .{
        .status = if (in.enabled) .enabled else .disabled,
        .attribute_name = attr_owned,
    };
    slot.ttl_spec = new_spec;

    writeSchemaJson(self, slot) catch {
        self.allocator.free(attr_owned);
        slot.ttl_spec = null;
        return storage.Error.Io;
    };
    return new_spec;
}

pub fn ddbDescribeTimeToLive(self: *Fs, name: []const u8) storage.Error!?storage.dynamo_state.TimeToLiveSpec {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const slot = self.dynamo_tables.get(name) orelse return storage.Error.TableNotFound;
    return slot.ttl_spec;
}

/// Sweeper main loop. Spawned from `init`; runs until `sweeper_stop`
/// is set by `deinit`. Sleeps in small chunks so shutdown observes the
/// stop flag promptly even when the interval is set high.
fn ttlSweepLoop(self: *Fs) void {
    const tick_ms: u32 = 250;
    while (true) {
        const interval_ms: u32 = self.ttl_sweep_interval_secs * 1000;
        var slept: u32 = 0;
        while (slept < interval_ms) {
            if (self.sweeper_stop.load(.acquire)) return;
            const chunk: u32 = @min(tick_ms, interval_ms - slept);
            // Use Linux nanosleep directly. std.posix.poll(&[], ms) is
            // tempting but panics with EFAULT on an empty slice in Zig
            // 0.16 (the slice's .ptr is non-null but invalid).
            const req: std.os.linux.timespec = .{
                .sec = @intCast(@divTrunc(chunk, 1000)),
                .nsec = @intCast(@as(i64, @mod(chunk, 1000)) * std.time.ns_per_ms),
            };
            _ = std.os.linux.nanosleep(&req, null);
            slept += chunk;
        }
        if (self.sweeper_stop.load(.acquire)) return;
        ttlSweepOnce(self);
    }
}

/// One pass: lock the table mutex, iterate every TTL-enabled table,
/// collect expired item keys (TTL attribute is a Number ≤ now()), and
/// evict each via the existing transaction-write delete path.
/// Wrong-type or missing TTL attributes are ignored per AWS semantics.
pub fn ttlSweepOnce(self: *Fs) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const now = nowUnixSeconds(self.io);
    var it = self.dynamo_tables.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const spec = slot.ttl_spec orelse continue;
        if (spec.status != .enabled) continue;
        sweepTableLocked(self, slot, spec.attribute_name, now);
    }
}

fn sweepTableLocked(self: *Fs, slot: *storage.TableSlot, attr_name: []const u8, now_unix: i64) void {
    // Snapshot the expired keys first; we can't mutate the map while
    // iterating it (Zig hash-map iterator is invalidated on modify).
    var victims: std.ArrayList(storage.Item) = .empty;
    defer {
        for (victims.items) |*v| v.deinit(self.allocator);
        victims.deinit(self.allocator);
    }

    var it = slot.items.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        const av = item.attributeValue(attr_name) orelse continue;
        const n_str = switch (av.*) {
            .n => |n| n,
            else => continue, // wrong type → ignored per AWS
        };
        const ttl_val = std.fmt.parseFloat(f64, n_str) catch continue;
        if (ttl_val > @as(f64, @floatFromInt(now_unix))) continue;

        // Project keys for the delete call.
        const key_only = storage.dynamo_state.projectKeys(self.allocator, slot, item) catch continue;
        victims.append(self.allocator, key_only) catch {
            var k = key_only;
            k.deinit(self.allocator);
            continue;
        };
    }

    for (victims.items) |*key_only| {
        applyDeleteLocked(self, slot, key_only, .ttl_sweeper) catch {};
    }
}

// ---------------------------------------------------------------------------
// DynamoDB Backups (v0.2.5)
//
// Disk layout: `<base>/dynamodb/backups/<backup_id>/` holds:
//   - manifest.json — source table name, backup ARN, type, status,
//     creation_unix, size_bytes, item_count.
//   - schema.json — snapshotted SchemaDoc (same shape as the live table's).
//   - items/<sha256>.json — one file per item.
//
// Backups are independent of the source table: `DeleteTable` does not
// cascade. Backup IDs are `<14-digit-unix-ms>-<8-hex-random>` (matches
// AWS's opaque shape).

const BackupManifest = struct {
    backup_id: []const u8,
    backup_name: []const u8,
    source_table: []const u8,
    creation_unix: i64,
    status: []const u8, // "AVAILABLE" / "DELETED"
    backup_type: []const u8, // "USER"
    size_bytes: u64,
    item_count: u64,
};

fn backupsRootPath(self: *Fs, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/dynamodb/backups", .{self.base_dir});
}

fn backupDirPath(self: *Fs, backup_id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/dynamodb/backups/{s}", .{ self.base_dir, backup_id });
}

fn backupItemsDirPath(self: *Fs, backup_id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/dynamodb/backups/{s}/items", .{ self.base_dir, backup_id });
}

/// `arn:aws:dynamodb:<region>:000000000000:table/<source>/backup/<id>`
fn buildBackupArn(allocator: Allocator, region: []const u8, source_table: []const u8, backup_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "arn:aws:dynamodb:{s}:000000000000:table/{s}/backup/{s}", .{ region, source_table, backup_id });
}

/// Pull the backup ID from the trailing `/backup/<id>` segment.
fn parseBackupId(arn: []const u8) storage.Error![]const u8 {
    const marker = "/backup/";
    const idx = std.mem.lastIndexOf(u8, arn, marker) orelse return storage.Error.InvalidBackupArn;
    const id = arn[idx + marker.len ..];
    if (id.len == 0) return storage.Error.InvalidBackupArn;
    return id;
}

/// `<14-digit unix-ms>-<8-hex>`. The 8-hex tail is the low 32 bits of
/// the sub-millisecond nanosecond remainder, which gives us
/// monotonically-increasing IDs without an RNG dependency. Collision
/// probability is negligible for a local-dev emulator (concurrent
/// backups on the same nanosecond are not a realistic case).
fn generateBackupId(allocator: Allocator, io: Io) ![]const u8 {
    const ts = Io.Timestamp.now(io, .real);
    const total_ns: u64 = @intCast(ts.nanoseconds);
    const ms: u64 = total_ns / std.time.ns_per_ms;
    const sub_ms_ns: u32 = @truncate(total_ns % std.time.ns_per_ms);
    return std.fmt.allocPrint(allocator, "{d:0>14}-{x:0>8}", .{ ms, sub_ms_ns });
}

pub fn ddbCreateBackup(self: *Fs, allocator: Allocator, in: storage.CreateBackupInput) storage.Error!storage.BackupSummary {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.table_name) orelse return storage.Error.TableNotFound;

    const backup_id = generateBackupId(self.allocator, self.io) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(backup_id);

    var dir_buf: [4096]u8 = undefined;
    const backup_dir = backupDirPath(self, backup_id, &dir_buf) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, backup_dir) catch return storage.Error.Io;

    var items_buf: [4096]u8 = undefined;
    const items_dir = backupItemsDirPath(self, backup_id, &items_buf) catch return storage.Error.Io;
    Io.Dir.cwd().createDirPath(self.io, items_dir) catch return storage.Error.Io;

    // schema.json — reuse slotToDoc.
    {
        const doc = slotToDoc(self.allocator, slot) catch return storage.Error.OutOfMemory;
        defer freeDoc(self.allocator, doc);
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(doc, .{}, &aw.writer) catch return storage.Error.OutOfMemory;
        const body = aw.toOwnedSlice() catch return storage.Error.OutOfMemory;
        defer self.allocator.free(body);
        var schema_path_buf: [4096]u8 = undefined;
        const schema_path = std.fmt.bufPrint(&schema_path_buf, "{s}/schema.json", .{backup_dir}) catch return storage.Error.Io;
        writeAtomic(self.io, schema_path, body) catch return storage.Error.Io;
    }

    // Items: walk slot.items and persist a copy at the backup-items path.
    var total_size: u64 = 0;
    var item_count: u64 = 0;
    {
        var it = slot.items.iterator();
        while (it.next()) |entry| {
            const item_ptr = entry.value_ptr.*;
            const key_str = entry.key_ptr.*;
            const key_hash = itemKeyHash(key_str);

            // Render via the existing item-JSON pattern.
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            var s: std.json.Stringify = .{ .writer = &aw.writer };
            s.beginObject() catch return storage.Error.OutOfMemory;
            for (item_ptr.names, item_ptr.values) |name, value| {
                s.objectField(name) catch return storage.Error.OutOfMemory;
                ddb_attr.renderValue(&s, self.allocator, value) catch return storage.Error.OutOfMemory;
            }
            s.endObject() catch return storage.Error.OutOfMemory;
            const body = aw.toOwnedSlice() catch return storage.Error.OutOfMemory;
            defer self.allocator.free(body);

            var item_path_buf: [4096]u8 = undefined;
            const item_path = std.fmt.bufPrint(&item_path_buf, "{s}/{s}.json", .{ items_dir, &key_hash }) catch return storage.Error.Io;
            writeAtomic(self.io, item_path, body) catch return storage.Error.Io;
            total_size += body.len;
            item_count += 1;
        }
    }

    const created_unix = nowUnixSeconds(self.io);
    const backup_name_owned = self.allocator.dupe(u8, in.backup_name) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(backup_name_owned);
    const source_table_owned = self.allocator.dupe(u8, slot.name) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(source_table_owned);

    const manifest: BackupManifest = .{
        .backup_id = backup_id,
        .backup_name = backup_name_owned,
        .source_table = source_table_owned,
        .creation_unix = created_unix,
        .status = "AVAILABLE",
        .backup_type = "USER",
        .size_bytes = total_size,
        .item_count = item_count,
    };
    writeBackupManifest(self, backup_id, manifest) catch return storage.Error.Io;
    self.allocator.free(backup_name_owned);
    self.allocator.free(source_table_owned);

    // Build the public-facing summary using the caller's allocator.
    return .{
        .arn = buildBackupArn(allocator, in.region, slot.name, backup_id) catch return storage.Error.OutOfMemory,
        .backup_id = allocator.dupe(u8, backup_id) catch return storage.Error.OutOfMemory,
        .name = allocator.dupe(u8, in.backup_name) catch return storage.Error.OutOfMemory,
        .table_name = allocator.dupe(u8, slot.name) catch return storage.Error.OutOfMemory,
        .creation_unix = created_unix,
        .status = .available,
        .backup_type = .user,
        .size_bytes = total_size,
    };
}

fn writeBackupManifest(self: *Fs, backup_id: []const u8, manifest: BackupManifest) !void {
    var dir_buf: [4096]u8 = undefined;
    const backup_dir = try backupDirPath(self, backup_id, &dir_buf);
    var path_buf: [4096]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{backup_dir});

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(manifest, .{}, &aw.writer);
    const body = try aw.toOwnedSlice();
    defer self.allocator.free(body);
    try writeAtomic(self.io, manifest_path, body);
}

fn readBackupManifest(self: *Fs, allocator: Allocator, backup_id: []const u8) storage.Error!BackupManifest {
    var dir_buf: [4096]u8 = undefined;
    const backup_dir = backupDirPath(self, backup_id, &dir_buf) catch return storage.Error.Io;
    var path_buf: [4096]u8 = undefined;
    const manifest_path = std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{backup_dir}) catch return storage.Error.Io;

    const body = Io.Dir.cwd().readFileAlloc(self.io, manifest_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return storage.Error.BackupNotFound,
        else => return storage.Error.Io,
    };
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(BackupManifest, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return storage.Error.Io;
    defer parsed.deinit();
    const m = parsed.value;
    // Re-allocate owned copies — caller owns these.
    return .{
        .backup_id = try allocator.dupe(u8, m.backup_id),
        .backup_name = try allocator.dupe(u8, m.backup_name),
        .source_table = try allocator.dupe(u8, m.source_table),
        .creation_unix = m.creation_unix,
        .status = try allocator.dupe(u8, m.status),
        .backup_type = try allocator.dupe(u8, m.backup_type),
        .size_bytes = m.size_bytes,
        .item_count = m.item_count,
    };
}

fn manifestToSummary(allocator: Allocator, region: []const u8, manifest: BackupManifest) !storage.BackupSummary {
    return .{
        .arn = try buildBackupArn(allocator, region, manifest.source_table, manifest.backup_id),
        .backup_id = try allocator.dupe(u8, manifest.backup_id),
        .name = try allocator.dupe(u8, manifest.backup_name),
        .table_name = try allocator.dupe(u8, manifest.source_table),
        .creation_unix = manifest.creation_unix,
        .status = if (std.mem.eql(u8, manifest.status, "AVAILABLE")) .available else .deleted,
        .backup_type = .user,
        .size_bytes = manifest.size_bytes,
    };
}

pub fn ddbListBackups(self: *Fs, allocator: Allocator, in: storage.ListBackupsInput) storage.Error!storage.ListBackupsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var summaries: std.ArrayList(storage.BackupSummary) = .empty;
    errdefer summaries.deinit(allocator);

    var root_buf: [4096]u8 = undefined;
    const root = backupsRootPath(self, &root_buf) catch return storage.Error.Io;
    var dir = Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .backups = &.{}, .last_evaluated_backup_arn = null },
        else => return storage.Error.Io,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (it.next(self.io) catch return storage.Error.Io) |entry| {
        if (entry.kind != .directory) continue;
        const manifest = self.readBackupManifest(allocator, entry.name) catch continue;
        defer {
            allocator.free(manifest.backup_id);
            allocator.free(manifest.backup_name);
            allocator.free(manifest.source_table);
            allocator.free(manifest.status);
            allocator.free(manifest.backup_type);
        }
        if (in.table_name) |filter| if (!std.mem.eql(u8, filter, manifest.source_table)) continue;
        const summary = manifestToSummary(allocator, in.region, manifest) catch return storage.Error.OutOfMemory;
        summaries.append(allocator, summary) catch return storage.Error.OutOfMemory;
    }

    // Sort by ARN for stable pagination.
    std.mem.sort(storage.BackupSummary, summaries.items, {}, struct {
        fn lt(_: void, a: storage.BackupSummary, b: storage.BackupSummary) bool {
            return std.mem.lessThan(u8, a.arn, b.arn);
        }
    }.lt);

    // Cursor: skip everything <= start_arn.
    var start_idx: usize = 0;
    if (in.exclusive_start_backup_arn) |cursor| {
        for (summaries.items, 0..) |s, idx| {
            if (std.mem.eql(u8, s.arn, cursor)) {
                start_idx = idx + 1;
                break;
            }
        }
    }
    const end_idx = @min(start_idx + in.limit, summaries.items.len);
    const owned = summaries.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory;

    // Free anything outside the requested page.
    for (owned[0..start_idx]) |s| freeSummary(allocator, s);
    for (owned[end_idx..]) |s| freeSummary(allocator, s);
    const page = allocator.alloc(storage.BackupSummary, end_idx - start_idx) catch return storage.Error.OutOfMemory;
    for (owned[start_idx..end_idx], 0..) |s, i| page[i] = s;
    const next: ?[]const u8 = if (end_idx < owned.len)
        allocator.dupe(u8, page[page.len - 1].arn) catch return storage.Error.OutOfMemory
    else
        null;
    allocator.free(owned);
    return .{ .backups = page, .last_evaluated_backup_arn = next };
}

fn freeSummary(allocator: Allocator, s: storage.BackupSummary) void {
    allocator.free(s.arn);
    allocator.free(s.backup_id);
    allocator.free(s.name);
    allocator.free(s.table_name);
}

pub fn ddbDescribeBackup(self: *Fs, allocator: Allocator, backup_arn: []const u8) storage.Error!storage.BackupDescription {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return describeBackupLocked(self, allocator, backup_arn);
}

/// Caller must hold `self.mutex`.
fn describeBackupLocked(self: *Fs, allocator: Allocator, backup_arn: []const u8) storage.Error!storage.BackupDescription {
    const backup_id = try parseBackupId(backup_arn);
    const manifest = try self.readBackupManifest(allocator, backup_id);
    errdefer {
        allocator.free(manifest.backup_id);
        allocator.free(manifest.backup_name);
        allocator.free(manifest.source_table);
        allocator.free(manifest.status);
        allocator.free(manifest.backup_type);
    }

    var dir_buf: [4096]u8 = undefined;
    const backup_dir = backupDirPath(self, backup_id, &dir_buf) catch return storage.Error.Io;
    var schema_path_buf: [4096]u8 = undefined;
    const schema_path = std.fmt.bufPrint(&schema_path_buf, "{s}/schema.json", .{backup_dir}) catch return storage.Error.Io;
    const body = Io.Dir.cwd().readFileAlloc(self.io, schema_path, allocator, .limited(1024 * 1024)) catch
        return storage.Error.Io;
    defer allocator.free(body);
    var parsed = std.json.parseFromSlice(SchemaDoc, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return storage.Error.Io;
    defer parsed.deinit();
    const doc = parsed.value;

    const ks = allocator.alloc(storage.dynamo_state.KeyAttribute, doc.key_schema.len) catch return storage.Error.OutOfMemory;
    for (doc.key_schema, 0..) |k, i| ks[i] = .{
        .name = allocator.dupe(u8, k.name) catch return storage.Error.OutOfMemory,
        .key_type = storage.dynamo_state.KeyType.fromAws(k.key_type) orelse .hash,
    };
    const ad = allocator.alloc(storage.dynamo_state.AttributeDef, doc.attribute_definitions.len) catch return storage.Error.OutOfMemory;
    for (doc.attribute_definitions, 0..) |a, i| ad[i] = .{
        .name = allocator.dupe(u8, a.name) catch return storage.Error.OutOfMemory,
        .type = storage.dynamo_state.ScalarType.fromAws(a.type) orelse .string,
    };

    return .{
        .summary = .{
            .arn = buildBackupArn(allocator, "us-east-1", manifest.source_table, manifest.backup_id) catch
                return storage.Error.OutOfMemory,
            .backup_id = manifest.backup_id,
            .name = manifest.backup_name,
            .table_name = allocator.dupe(u8, manifest.source_table) catch return storage.Error.OutOfMemory,
            .creation_unix = manifest.creation_unix,
            .status = .available,
            .backup_type = .user,
            .size_bytes = manifest.size_bytes,
        },
        .table_name = manifest.source_table,
        .key_schema = ks,
        .attribute_definitions = ad,
        .billing_mode = storage.dynamo_state.BillingMode.fromAws(doc.billing_mode) orelse .pay_per_request,
        .table_created_unix = doc.created_unix,
        .item_count = manifest.item_count,
    };
}

pub fn ddbDeleteBackup(self: *Fs, allocator: Allocator, backup_arn: []const u8) storage.Error!storage.BackupDescription {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // Read the full description (manifest + schema) BEFORE deleting so
    // the caller gets back the same shape DescribeBackup would have
    // returned — with BackupStatus flipped to DELETED.
    var desc = try describeBackupLocked(self, allocator, backup_arn);
    desc.summary.status = .deleted;

    const backup_id = try parseBackupId(backup_arn);
    var dir_buf: [4096]u8 = undefined;
    const backup_dir = backupDirPath(self, backup_id, &dir_buf) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, backup_dir) catch return storage.Error.Io;

    return desc;
}

pub fn ddbRestoreTableFromBackup(self: *Fs, allocator: Allocator, in: storage.RestoreTableFromBackupInput) storage.Error!*const storage.TableSlot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.dynamo_tables.contains(in.target_table_name)) return storage.Error.TableAlreadyExists;

    const backup_id = try parseBackupId(in.backup_arn);

    // Read the snapshotted schema.
    var dir_buf: [4096]u8 = undefined;
    const backup_dir = backupDirPath(self, backup_id, &dir_buf) catch return storage.Error.Io;
    var schema_path_buf: [4096]u8 = undefined;
    const schema_path = std.fmt.bufPrint(&schema_path_buf, "{s}/schema.json", .{backup_dir}) catch return storage.Error.Io;

    const body = Io.Dir.cwd().readFileAlloc(self.io, schema_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return storage.Error.BackupNotFound,
        else => return storage.Error.Io,
    };
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(SchemaDoc, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return storage.Error.Io;
    defer parsed.deinit();
    const doc = parsed.value;

    // Reconstruct a CreateTableInput from the snapshotted schema, but
    // with the *target* name (not the source). Allocations live in the
    // per-request arena.
    const ks_in = allocator.alloc(storage.dynamo_state.KeyAttribute, doc.key_schema.len) catch return storage.Error.OutOfMemory;
    for (doc.key_schema, 0..) |k, i| ks_in[i] = .{
        .name = allocator.dupe(u8, k.name) catch return storage.Error.OutOfMemory,
        .key_type = storage.dynamo_state.KeyType.fromAws(k.key_type) orelse .hash,
    };
    const ad_in = allocator.alloc(storage.dynamo_state.AttributeDef, doc.attribute_definitions.len) catch return storage.Error.OutOfMemory;
    for (doc.attribute_definitions, 0..) |a, i| ad_in[i] = .{
        .name = allocator.dupe(u8, a.name) catch return storage.Error.OutOfMemory,
        .type = storage.dynamo_state.ScalarType.fromAws(a.type) orelse .string,
    };

    const create_in: storage.CreateTableInput = .{
        .name = in.target_table_name,
        .key_schema = ks_in,
        .attribute_definitions = ad_in,
        .billing_mode = storage.dynamo_state.BillingMode.fromAws(doc.billing_mode) orelse .pay_per_request,
        // GSIs/LSIs/Tags/Stream/TTL would round-trip here too in a
        // future patch. For now restore the basic schema; clients can
        // re-apply richer features on the restored table.
    };
    // ddbCreateTable would re-lock the mutex; inline the body.
    try createTableLocked(self, create_in);

    // Walk the backup's items/ dir + reinsert into the new table.
    var items_dir_buf: [4096]u8 = undefined;
    const items_dir = backupItemsDirPath(self, backup_id, &items_dir_buf) catch return storage.Error.Io;
    var dir = Io.Dir.cwd().openDir(self.io, items_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            // Backup had no items — restored table is empty, return slot.
            return self.dynamo_tables.get(in.target_table_name).?;
        },
        else => return storage.Error.Io,
    };
    defer dir.close(self.io);

    const target_slot = self.dynamo_tables.get(in.target_table_name).?;
    var it = dir.iterate();
    while (it.next(self.io) catch return storage.Error.Io) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        var item_path_buf: [4096]u8 = undefined;
        const item_path = std.fmt.bufPrint(&item_path_buf, "{s}/{s}", .{ items_dir, entry.name }) catch return storage.Error.Io;
        const item_body = Io.Dir.cwd().readFileAlloc(self.io, item_path, self.allocator, .limited(4 * 1024 * 1024)) catch
            return storage.Error.Io;
        defer self.allocator.free(item_body);

        var item_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, item_body, .{}) catch continue;
        defer item_parsed.deinit();
        if (item_parsed.value != .object) continue;

        const item = parseItemFromJson(self.allocator, item_parsed.value.object) catch continue;
        defer {
            var owned = item;
            owned.deinit(self.allocator);
        }
        applyPutLocked(self, target_slot, &item) catch continue;
    }

    return target_slot;
}

/// Caller must hold self.mutex. Same body as ddbCreateTable minus the
/// lock.
fn createTableLocked(self: *Fs, in: storage.CreateTableInput) storage.Error!void {
    if (self.dynamo_tables.contains(in.name)) return storage.Error.TableAlreadyExists;
    const slot = cloneTableSlot(self.allocator, in, nowUnixSeconds(self.io)) catch
        return storage.Error.OutOfMemory;
    const slot_ptr = self.allocator.create(storage.TableSlot) catch {
        var tmp = slot;
        tmp.deinit(self.allocator);
        return storage.Error.OutOfMemory;
    };
    slot_ptr.* = slot;
    if (slot_ptr.stream_spec) |spec| if (spec.enabled) {
        attachStream(self, slot_ptr) catch {
            slot_ptr.deinit(self.allocator);
            self.allocator.destroy(slot_ptr);
            return storage.Error.OutOfMemory;
        };
    };
    writeSchemaJson(self, slot_ptr) catch {
        slot_ptr.deinit(self.allocator);
        self.allocator.destroy(slot_ptr);
        return storage.Error.Io;
    };
    self.dynamo_tables.put(self.allocator, slot_ptr.name, slot_ptr) catch
        return storage.Error.OutOfMemory;
}

pub fn ddbUpdateContinuousBackups(self: *Fs, in: storage.UpdateContinuousBackupsInput) storage.Error!storage.ContinuousBackupsDescription {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.dynamo_tables.get(in.table_name) orelse return storage.Error.TableNotFound;

    const now = nowUnixSeconds(self.io);
    if (in.pitr_enabled) {
        slot.continuous_backup.pitr_status = .enabled;
        // Re-stamp the enabled_unix on every enable transition.
        if (slot.continuous_backup.enabled_unix == null) slot.continuous_backup.enabled_unix = now;
    } else {
        slot.continuous_backup.pitr_status = .disabled;
        // Leave enabled_unix in place — matches AWS behaviour where
        // the timestamp survives a disable.
    }
    writeSchemaJson(self, slot) catch return storage.Error.Io;
    return describeContinuousBackupsLocked(self, slot);
}

pub fn ddbDescribeContinuousBackups(self: *Fs, table_name: []const u8) storage.Error!storage.ContinuousBackupsDescription {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const slot = self.dynamo_tables.get(table_name) orelse return storage.Error.TableNotFound;
    return describeContinuousBackupsLocked(self, slot);
}

fn describeContinuousBackupsLocked(self: *Fs, slot: *const storage.TableSlot) storage.ContinuousBackupsDescription {
    const now = nowUnixSeconds(self.io);
    // AWS-real: 35 day window. Earliest = max(table_created, now - 35d).
    const window_secs: i64 = 35 * 24 * 3600;
    const earliest = @max(slot.created_unix, now - window_secs);
    return .{
        .continuous_backups_status = .enabled,
        .pitr_status = slot.continuous_backup.pitr_status,
        .earliest_restorable_unix = earliest,
        .latest_restorable_unix = now,
    };
}

pub fn ddbRestoreTableToPointInTime(self: *Fs, allocator: Allocator, in: storage.RestoreTableToPointInTimeInput) storage.Error!*const storage.TableSlot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.dynamo_tables.contains(in.target_table_name)) return storage.Error.TableAlreadyExists;

    const source = self.dynamo_tables.get(in.source_table_name) orelse return storage.Error.TableNotFound;

    // Documented divergence: we ignore `restore_date_time` /
    // `use_latest_restorable_time` and always snapshot the current
    // state. LocalStack does the same.
    _ = allocator;

    // Clone source schema → CreateTableInput for the target.
    const create_in: storage.CreateTableInput = .{
        .name = in.target_table_name,
        .key_schema = source.key_schema,
        .attribute_definitions = source.attribute_definitions,
        .billing_mode = source.billing_mode,
    };
    try createTableLocked(self, create_in);
    const target = self.dynamo_tables.get(in.target_table_name).?;

    // Copy every item from source into target.
    var it = source.items.iterator();
    while (it.next()) |entry| {
        const item_ptr = entry.value_ptr.*;
        applyPutLocked(self, target, item_ptr) catch continue;
    }

    return target;
}

/// Build an `Item` from a parsed JSON map. Allocated via the Fs's
/// long-lived allocator (lifetime: until the next deinit).
fn parseItemFromJson(allocator: Allocator, obj: std.json.ObjectMap) !storage.Item {
    const n = obj.count();
    const names = try allocator.alloc([]const u8, n);
    var names_done: usize = 0;
    errdefer {
        for (names[0..names_done]) |nm| allocator.free(nm);
        allocator.free(names);
    }
    const values = try allocator.alloc(ddb_attr.AttributeValue, n);
    var values_done: usize = 0;
    errdefer {
        for (values[0..values_done]) |*v| {
            var copy = v.*;
            ddb_attr.deinit(allocator, &copy);
        }
        allocator.free(values);
    }
    var entry_it = obj.iterator();
    var i: usize = 0;
    while (entry_it.next()) |entry| : (i += 1) {
        names[i] = try allocator.dupe(u8, entry.key_ptr.*);
        names_done = i + 1;
        values[i] = try ddb_attr.parseValue(allocator, entry.value_ptr.*);
        values_done = i + 1;
    }
    return .{ .names = names, .values = values };
}

// ---------------------------------------------------------------------------
// SQS (v0.3.0)
//
// Disk layout: <base>/sqs/queues/<name>/{attributes.json, tags.json,
// messages/<id>.json}. The in-memory `sqs_queues` map holds a pointer
// to each queue's slot; mutations go through `Fs.mutex` for parity
// with the DDB layer.

const sqs_state_mod = @import("sqs_state.zig");

fn ensureSqsDir(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/sqs/queues", .{self.base_dir});
    try Io.Dir.cwd().createDirPath(self.io, path);
}

fn queueDirPath(self: *Fs, name: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/sqs/queues/{s}", .{ self.base_dir, name });
}

fn queueAttrsPath(self: *Fs, name: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/sqs/queues/{s}/attributes.json", .{ self.base_dir, name });
}

const AttributesDoc = struct {
    visibility_timeout: u32,
    delay_seconds: u32,
    receive_message_wait_time_seconds: u32,
    message_retention_period: u32,
    maximum_message_size: u32,
    created_unix: i64,
    redrive_policy: ?[]const u8 = null,
    policy: ?[]const u8 = null,
    is_fifo: bool = false,
    content_based_dedup: bool = false,
    sequence_counter: u128 = 0,
};

fn writeQueueAttrs(self: *Fs, slot: *const storage.SqsQueueSlot) !void {
    var dir_buf: [4096]u8 = undefined;
    const dir_path = try queueDirPath(self, slot.name, &dir_buf);
    try Io.Dir.cwd().createDirPath(self.io, dir_path);

    const doc: AttributesDoc = .{
        .visibility_timeout = slot.attrs.visibility_timeout,
        .delay_seconds = slot.attrs.delay_seconds,
        .receive_message_wait_time_seconds = slot.attrs.receive_message_wait_time_seconds,
        .message_retention_period = slot.attrs.message_retention_period,
        .maximum_message_size = slot.attrs.maximum_message_size,
        .created_unix = slot.created_unix,
        .redrive_policy = slot.attrs.redrive_policy,
        .policy = slot.attrs.policy,
        .is_fifo = slot.attrs.is_fifo,
        .content_based_dedup = slot.attrs.content_based_dedup,
        .sequence_counter = slot.attrs.sequence_counter,
    };

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(doc, .{}, &aw.writer);
    const body = try aw.toOwnedSlice();
    defer self.allocator.free(body);

    var path_buf: [4096]u8 = undefined;
    const path = try queueAttrsPath(self, slot.name, &path_buf);
    try writeAtomic(self.io, path, body);
}

fn loadSqsQueues(self: *Fs) !void {
    var buf: [4096]u8 = undefined;
    const queues_path = try std.fmt.bufPrint(&buf, "{s}/sqs/queues", .{self.base_dir});

    var dir = Io.Dir.cwd().openDir(self.io, queues_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.io);

    var it = dir.iterate();
    while (try it.next(self.io)) |entry| {
        if (entry.kind != .directory) continue;
        loadSingleQueue(self, entry.name) catch |err| {
            std.log.warn("sqs: skipping corrupted queue dir {s}: {s}", .{ entry.name, @errorName(err) });
        };
    }
}

fn loadSingleQueue(self: *Fs, name: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const attrs_path = try queueAttrsPath(self, name, &path_buf);

    const body = Io.Dir.cwd().readFileAlloc(self.io, attrs_path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(body);

    var parsed = std.json.parseFromSlice(AttributesDoc, self.allocator, body, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const doc = parsed.value;

    const slot_ptr = try self.allocator.create(storage.SqsQueueSlot);
    errdefer self.allocator.destroy(slot_ptr);
    slot_ptr.* = .{
        .name = try self.allocator.dupe(u8, name),
        .created_unix = doc.created_unix,
        .attrs = .{
            .visibility_timeout = doc.visibility_timeout,
            .delay_seconds = doc.delay_seconds,
            .receive_message_wait_time_seconds = doc.receive_message_wait_time_seconds,
            .message_retention_period = doc.message_retention_period,
            .maximum_message_size = doc.maximum_message_size,
            .redrive_policy = if (doc.redrive_policy) |s| try self.allocator.dupe(u8, s) else null,
            .policy = if (doc.policy) |s| try self.allocator.dupe(u8, s) else null,
            .is_fifo = doc.is_fifo,
            .content_based_dedup = doc.content_based_dedup,
            .sequence_counter = doc.sequence_counter,
        },
    };

    loadQueueTags(self, slot_ptr);

    try self.sqs_queues.put(self.allocator, slot_ptr.name, slot_ptr);
}

pub fn sqsCreateQueue(self: *Fs, in: storage.CreateQueueInput) storage.Error!*const storage.SqsQueueSlot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // FIFO reconciliation: the `.fifo` name suffix and the `FifoQueue`
    // attribute must agree. AWS-exact: a non-`.fifo` name with
    // FifoQueue=true → InvalidAttributeValue; a `.fifo` name with
    // FifoQueue=false → InvalidAttributeValue. If the attribute is
    // omitted, we derive it from the name.
    const name_is_fifo = sqs_state_mod.hasFifoSuffix(in.name);
    if (in.attrs.is_fifo and !name_is_fifo) return storage.Error.InvalidAttributeValue;
    if (name_is_fifo and !in.attrs.is_fifo and in.fifo_attribute_specified)
        return storage.Error.InvalidAttributeValue;
    const effective_fifo = name_is_fifo;
    // ContentBasedDeduplication is FIFO-only — reject on Standard.
    if (in.attrs.content_based_dedup and !effective_fifo)
        return storage.Error.InvalidAttributeValue;
    // FIFO queues forbid per-queue DelaySeconds > 0.
    if (effective_fifo and in.attrs.delay_seconds > 0)
        return storage.Error.InvalidAttributeValue;

    if (self.sqs_queues.get(in.name)) |existing| {
        // AWS idempotency: CreateQueue with the same name + matching
        // attrs returns the existing queue. If attrs differ, returns
        // QueueNameExists. For local-dev we accept any duplicate-name
        // call as idempotent — the SDKs treat it that way.
        return existing;
    }

    const name_owned = self.allocator.dupe(u8, in.name) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(name_owned);

    const slot_ptr = self.allocator.create(storage.SqsQueueSlot) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.destroy(slot_ptr);
    slot_ptr.* = .{
        .name = name_owned,
        .created_unix = nowUnixSeconds(self.io),
        .attrs = .{
            .visibility_timeout = in.attrs.visibility_timeout,
            .delay_seconds = in.attrs.delay_seconds,
            .receive_message_wait_time_seconds = in.attrs.receive_message_wait_time_seconds,
            .message_retention_period = in.attrs.message_retention_period,
            .maximum_message_size = in.attrs.maximum_message_size,
            .redrive_policy = if (in.attrs.redrive_policy) |s| (self.allocator.dupe(u8, s) catch return storage.Error.OutOfMemory) else null,
            .policy = if (in.attrs.policy) |s| (self.allocator.dupe(u8, s) catch return storage.Error.OutOfMemory) else null,
            .is_fifo = effective_fifo,
            .content_based_dedup = in.attrs.content_based_dedup,
            .sequence_counter = 0,
        },
    };
    writeQueueAttrs(self, slot_ptr) catch return storage.Error.Io;
    self.sqs_queues.put(self.allocator, slot_ptr.name, slot_ptr) catch return storage.Error.OutOfMemory;
    return slot_ptr;
}

pub fn sqsDeleteQueue(self: *Fs, name: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(name) orelse return storage.Error.QueueNotFound;
    var dir_buf: [4096]u8 = undefined;
    const dir_path = queueDirPath(self, name, &dir_buf) catch return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, dir_path) catch return storage.Error.Io;
    _ = self.sqs_queues.remove(name);
    slot.deinit(self.allocator);
    self.allocator.destroy(slot);
}

pub fn sqsGetQueueUrl(self: *Fs, name: []const u8) storage.Error!*const storage.SqsQueueSlot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.sqs_queues.get(name) orelse storage.Error.QueueNotFound;
}

pub fn sqsGetQueueAttributes(self: *Fs, name: []const u8) storage.Error!storage.QueueAttributes {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const slot = self.sqs_queues.get(name) orelse return storage.Error.QueueNotFound;
    return slot.attrs;
}

pub fn sqsSetQueueAttributes(self: *Fs, in: storage.SetQueueAttributesInput) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(in.name) orelse return storage.Error.QueueNotFound;
    // FifoQueue is immutable post-creation. Reject any attempt to set
    // it (even to the current value) — AWS-exact.
    if (in.attrs.fifo_attribute_specified) return storage.Error.InvalidAttributeValue;
    // ContentBasedDeduplication is FIFO-only.
    if (in.attrs.content_based_dedup != null and !slot.attrs.is_fifo)
        return storage.Error.InvalidAttributeValue;
    // FIFO queues forbid DelaySeconds > 0.
    if (in.attrs.delay_seconds) |v| {
        if (slot.attrs.is_fifo and v > 0) return storage.Error.InvalidAttributeValue;
    }

    if (in.attrs.visibility_timeout) |v| slot.attrs.visibility_timeout = v;
    if (in.attrs.delay_seconds) |v| slot.attrs.delay_seconds = v;
    if (in.attrs.receive_message_wait_time_seconds) |v| slot.attrs.receive_message_wait_time_seconds = v;
    if (in.attrs.message_retention_period) |v| slot.attrs.message_retention_period = v;
    if (in.attrs.maximum_message_size) |v| slot.attrs.maximum_message_size = v;
    if (in.attrs.redrive_policy) |s| {
        if (slot.attrs.redrive_policy) |old| self.allocator.free(old);
        slot.attrs.redrive_policy = if (s.len > 0)
            (self.allocator.dupe(u8, s) catch return storage.Error.OutOfMemory)
        else
            null;
    }
    if (in.attrs.policy) |s| {
        if (slot.attrs.policy) |old| self.allocator.free(old);
        slot.attrs.policy = if (s.len > 0)
            (self.allocator.dupe(u8, s) catch return storage.Error.OutOfMemory)
        else
            null;
    }
    if (in.attrs.content_based_dedup) |v| slot.attrs.content_based_dedup = v;
    writeQueueAttrs(self, slot) catch return storage.Error.Io;
}

pub fn sqsListQueues(self: *Fs, allocator: Allocator, in: storage.ListQueuesInput) storage.Error!storage.ListQueuesOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = self.sqs_queues.iterator();
    while (it.next()) |entry| {
        if (in.name_prefix) |pfx| if (!std.mem.startsWith(u8, entry.key_ptr.*, pfx)) continue;
        const owned = allocator.dupe(u8, entry.key_ptr.*) catch return storage.Error.OutOfMemory;
        names.append(allocator, owned) catch return storage.Error.OutOfMemory;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Pagination: MaxResults clamps to in.max_results; NextToken is the
    // last name returned (clients pass it back as `NextToken`).
    var start_idx: usize = 0;
    if (in.next_token) |tok| {
        for (names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, tok)) {
                start_idx = i + 1;
                break;
            }
        }
    }
    const end_idx = @min(start_idx + in.max_results, names.items.len);
    const owned = names.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory;
    for (owned[0..start_idx]) |n| allocator.free(n);
    for (owned[end_idx..]) |n| allocator.free(n);
    const page = allocator.alloc([]const u8, end_idx - start_idx) catch return storage.Error.OutOfMemory;
    for (owned[start_idx..end_idx], 0..) |n, i| page[i] = n;
    const next: ?[]const u8 = if (end_idx < owned.len)
        allocator.dupe(u8, page[page.len - 1]) catch return storage.Error.OutOfMemory
    else
        null;
    allocator.free(owned);
    return .{ .queue_names = page, .next_token = next };
}

pub fn sqsPurgeQueue(self: *Fs, name: []const u8) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const slot = self.sqs_queues.get(name) orelse return storage.Error.QueueNotFound;

    // Delete all in-memory messages.
    for (slot.messages.items) |m| {
        m.deinit(self.allocator);
        self.allocator.destroy(m);
    }
    slot.messages.clearAndFree(self.allocator);

    // Wipe the messages dir on disk.
    var dir_buf: [4096]u8 = undefined;
    const msgs_dir = std.fmt.bufPrint(&dir_buf, "{s}/sqs/queues/{s}/messages", .{ self.base_dir, name }) catch
        return storage.Error.Io;
    Io.Dir.cwd().deleteTree(self.io, msgs_dir) catch {};
}

// ---------------------------------------------------------------------------
// SQS messages (v0.3.0 Phase 2)

/// Generate a UUID-shaped MessageId from the nanosecond clock. Uniqueness
/// at sub-nanosecond granularity isn't realistic in practice (single
/// host) so this is "good enough for local dev".
fn generateMessageId(allocator: Allocator, io: Io) ![]const u8 {
    const ts = Io.Timestamp.now(io, .real);
    const ns: u128 = @intCast(ts.nanoseconds);
    const a: u32 = @truncate(ns >> 96);
    const b: u16 = @truncate(ns >> 80);
    const c: u16 = @truncate(ns >> 64);
    const d: u16 = @truncate(ns >> 48);
    const e: u48 = @truncate(ns);
    return std.fmt.allocPrint(allocator, "{x:0>8}-{x:0>4}-4{x:0>3}-{x:0>4}-{x:0>12}", .{
        a, b, @as(u16, c & 0xfff), d, e,
    });
}

/// Compute hex-encoded lowercase MD5 of the given input. AWS clients
/// verify this against the response.
fn md5Hex(input: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Receipt handles are opaque to clients. We encode
/// `<queue_name>|<message_id>|<receive_count>` then base64-url it.
/// DeleteMessage / ChangeMessageVisibility decode + validate.
fn buildReceiptHandle(
    allocator: Allocator,
    queue_name: []const u8,
    message_id: []const u8,
    receive_count: u32,
) ![]const u8 {
    var raw_buf: std.ArrayList(u8) = .empty;
    defer raw_buf.deinit(allocator);
    try raw_buf.appendSlice(allocator, queue_name);
    try raw_buf.append(allocator, '|');
    try raw_buf.appendSlice(allocator, message_id);
    try raw_buf.append(allocator, '|');
    const tail = try std.fmt.allocPrint(allocator, "{d}", .{receive_count});
    defer allocator.free(tail);
    try raw_buf.appendSlice(allocator, tail);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const out_len = enc.calcSize(raw_buf.items.len);
    const out = try allocator.alloc(u8, out_len);
    _ = enc.encode(out, raw_buf.items);
    return out;
}

const DecodedReceipt = struct {
    queue_name: []const u8,
    message_id: []const u8,
    receive_count: u32,
};

fn decodeReceiptHandle(allocator: Allocator, handle: []const u8) !DecodedReceipt {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const max_len = dec.calcSizeForSlice(handle) catch return error.InvalidReceiptHandle;
    const buf = try allocator.alloc(u8, max_len);
    dec.decode(buf, handle) catch return error.InvalidReceiptHandle;

    var it = std.mem.splitScalar(u8, buf, '|');
    const q = it.next() orelse return error.InvalidReceiptHandle;
    const id = it.next() orelse return error.InvalidReceiptHandle;
    const c = it.next() orelse return error.InvalidReceiptHandle;
    const cnt = std.fmt.parseInt(u32, c, 10) catch return error.InvalidReceiptHandle;
    return .{ .queue_name = q, .message_id = id, .receive_count = cnt };
}

fn messagePath(self: *Fs, queue_name: []const u8, message_id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/sqs/queues/{s}/messages/{s}.json", .{ self.base_dir, queue_name, message_id });
}

const MessageDoc = struct {
    id: []const u8,
    body: []const u8,
    sent_unix: i64,
    visible_unix: i64,
    receive_count: u32,
    md5_of_body: []const u8,
    raw_attributes_json: ?[]const u8 = null,
    message_group_id: ?[]const u8 = null,
    message_deduplication_id: ?[]const u8 = null,
    sequence_number: u128 = 0,
};

fn writeMessageJson(self: *Fs, queue_name: []const u8, m: *const storage.Message) !void {
    var dir_buf: [4096]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/sqs/queues/{s}/messages", .{ self.base_dir, queue_name });
    try Io.Dir.cwd().createDirPath(self.io, dir);

    const doc: MessageDoc = .{
        .id = m.id,
        .body = m.body,
        .sent_unix = m.sent_unix,
        .visible_unix = m.visible_unix,
        .receive_count = m.receive_count,
        .md5_of_body = &m.md5_of_body,
        .raw_attributes_json = m.raw_attributes_json,
        .message_group_id = m.message_group_id,
        .message_deduplication_id = m.message_deduplication_id,
        .sequence_number = m.sequence_number,
    };
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(doc, .{}, &aw.writer);
    const body = try aw.toOwnedSlice();
    defer self.allocator.free(body);

    var path_buf: [4096]u8 = undefined;
    const path = try messagePath(self, queue_name, m.id, &path_buf);
    try writeAtomic(self.io, path, body);
}

pub fn sqsSendMessage(self: *Fs, allocator: Allocator, in: storage.SendMessageInput) storage.Error!storage.SendMessageOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(in.queue_name) orelse return storage.Error.QueueNotFound;
    if (in.body.len > slot.attrs.maximum_message_size) return storage.Error.InvalidMessageBody;

    // FIFO vs Standard parameter validation.
    if (slot.attrs.is_fifo) {
        if (in.message_group_id == null) return storage.Error.MissingParameter;
        // Per-message DelaySeconds is rejected on FIFO (any explicit value).
        if (in.delay_seconds_specified) return storage.Error.InvalidParameterValue;
        // FIFO requires either ContentBasedDeduplication or an explicit dedup id.
        if (in.message_deduplication_id == null and !slot.attrs.content_based_dedup)
            return storage.Error.InvalidParameterValue;
    } else {
        if (in.message_group_id != null) return storage.Error.InvalidParameterValue;
        if (in.message_deduplication_id != null) return storage.Error.InvalidParameterValue;
    }

    const now = nowUnixSeconds(self.io);

    // FIFO dedup window. Compute effective dedup id (explicit, or
    // sha256(body) under ContentBasedDeduplication). Prune expired
    // entries first, then look up.
    var effective_dedup: ?[]const u8 = null;
    var content_hash_buf: [64]u8 = undefined;
    if (slot.attrs.is_fifo) {
        pruneDedupHistory(self, slot, now);
        if (in.message_deduplication_id) |s| {
            effective_dedup = s;
        } else if (slot.attrs.content_based_dedup) {
            effective_dedup = sha256Hex(in.body, &content_hash_buf);
        }
        if (effective_dedup) |key| {
            if (slot.dedup_history.get(key)) |entry| {
                // Return the original send's identifiers; the wire
                // can't tell the dupe was suppressed.
                return .{
                    .message_id = allocator.dupe(u8, entry.message_id) catch return storage.Error.OutOfMemory,
                    .md5_of_body = allocator.dupe(u8, &md5Hex(in.body)) catch return storage.Error.OutOfMemory,
                    .sequence_number = entry.sequence_number,
                };
            }
        }
    }

    const delay: u32 = in.delay_seconds orelse slot.attrs.delay_seconds;

    const id_owned = generateMessageId(self.allocator, self.io) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(id_owned);
    const body_owned = self.allocator.dupe(u8, in.body) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.free(body_owned);
    const attrs_owned: ?[]const u8 = if (in.raw_attributes_json) |s|
        (self.allocator.dupe(u8, s) catch return storage.Error.OutOfMemory)
    else
        null;
    errdefer if (attrs_owned) |s| self.allocator.free(s);
    const group_owned: ?[]const u8 = if (in.message_group_id) |s|
        (self.allocator.dupe(u8, s) catch return storage.Error.OutOfMemory)
    else
        null;
    errdefer if (group_owned) |s| self.allocator.free(s);
    const dedup_owned: ?[]const u8 = if (in.message_deduplication_id) |s|
        (self.allocator.dupe(u8, s) catch return storage.Error.OutOfMemory)
    else
        null;
    errdefer if (dedup_owned) |s| self.allocator.free(s);

    var seq_number: u128 = 0;
    if (slot.attrs.is_fifo) {
        slot.attrs.sequence_counter += 1;
        seq_number = slot.attrs.sequence_counter;
    }

    const md5 = md5Hex(in.body);
    const msg_ptr = self.allocator.create(storage.Message) catch return storage.Error.OutOfMemory;
    errdefer self.allocator.destroy(msg_ptr);
    msg_ptr.* = .{
        .id = id_owned,
        .body = body_owned,
        .sent_unix = now,
        .visible_unix = now + @as(i64, @intCast(delay)),
        .receive_count = 0,
        .md5_of_body = md5,
        .raw_attributes_json = attrs_owned,
        .message_group_id = group_owned,
        .message_deduplication_id = dedup_owned,
        .sequence_number = seq_number,
    };
    writeMessageJson(self, slot.name, msg_ptr) catch return storage.Error.Io;
    slot.messages.append(self.allocator, msg_ptr) catch return storage.Error.OutOfMemory;
    if (slot.attrs.is_fifo) {
        // Persist the bumped sequence_counter so it survives restart.
        writeQueueAttrs(self, slot) catch return storage.Error.Io;
        // Record the dedup id (if any) for the 5-minute window.
        if (effective_dedup) |key| {
            const key_owned = self.allocator.dupe(u8, key) catch return storage.Error.OutOfMemory;
            const msg_id_owned = self.allocator.dupe(u8, id_owned) catch {
                self.allocator.free(key_owned);
                return storage.Error.OutOfMemory;
            };
            slot.dedup_history.put(self.allocator, key_owned, .{
                .message_id = msg_id_owned,
                .sequence_number = seq_number,
                .expire_unix = now + dedup_window_seconds,
            }) catch {
                self.allocator.free(key_owned);
                self.allocator.free(msg_id_owned);
                return storage.Error.OutOfMemory;
            };
        }
    }

    return .{
        .message_id = allocator.dupe(u8, id_owned) catch return storage.Error.OutOfMemory,
        .md5_of_body = allocator.dupe(u8, &md5) catch return storage.Error.OutOfMemory,
        .sequence_number = if (slot.attrs.is_fifo) seq_number else null,
    };
}

const dedup_window_seconds: i64 = 300;

/// Prune entries whose expire_unix <= now. Frees both the key + the
/// stored message_id.
fn pruneDedupHistory(self: *Fs, slot: *storage.SqsQueueSlot, now: i64) void {
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(self.allocator);
    var it = slot.dedup_history.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.expire_unix <= now) {
            to_remove.append(self.allocator, entry.key_ptr.*) catch return;
        }
    }
    for (to_remove.items) |key| {
        if (slot.dedup_history.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.message_id);
        }
    }
}

/// SHA-256 of `data`, hex-encoded lowercase, written into `out_buf`
/// (must be ≥64 bytes). Returns a slice referencing `out_buf`.
fn sha256Hex(data: []const u8, out_buf: *[64]u8) []const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    const hex = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out_buf[i * 2] = hex[(b >> 4) & 0xf];
        out_buf[i * 2 + 1] = hex[b & 0xf];
    }
    return out_buf[0..];
}

pub fn sqsReceiveMessage(self: *Fs, allocator: Allocator, in: storage.ReceiveMessageInput) storage.Error!storage.ReceiveMessageOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(in.queue_name) orelse return storage.Error.QueueNotFound;

    const now = nowUnixSeconds(self.io);
    const vt: i64 = @intCast(in.visibility_timeout orelse slot.attrs.visibility_timeout);
    const max: usize = @min(@as(usize, in.max_messages), 10);

    // Parse RedrivePolicy once per call (lazy).
    const redrive: ?Redrive = parseRedrivePolicy(slot.attrs.redrive_policy);

    var out: std.ArrayList(storage.ReceivedMessage) = .empty;
    errdefer {
        for (out.items) |m| {
            allocator.free(m.message_id);
            allocator.free(m.receipt_handle);
            allocator.free(m.body);
            allocator.free(m.md5_of_body);
            if (m.raw_attributes_json) |s| allocator.free(s);
        }
        out.deinit(allocator);
    }

    // Iterate via index because we may need to remove (DLQ route) mid-pass.
    var i: usize = 0;
    while (i < slot.messages.items.len) {
        if (out.items.len >= max) break;
        const m = slot.messages.items[i];
        if (m.visible_unix > now) {
            i += 1;
            continue;
        }

        // DLQ check: a message that's been delivered maxReceiveCount
        // times before this attempt moves to the DLQ instead of being
        // returned. (AWS-real triggers when receive_count >= max.)
        if (redrive) |rd| if (m.receive_count >= rd.max_receive_count) {
            if (self.sqs_queues.get(rd.dlq_name)) |dlq| {
                _ = slot.messages.orderedRemove(i);
                // Persist the move: write to DLQ's messages dir, delete
                // from source.
                m.visible_unix = now;
                m.receive_count = 0;
                writeMessageJson(self, dlq.name, m) catch return storage.Error.Io;
                var path_buf: [4096]u8 = undefined;
                const src_path = messagePath(self, slot.name, m.id, &path_buf) catch return storage.Error.Io;
                Io.Dir.cwd().deleteFile(self.io, src_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return storage.Error.Io,
                };
                dlq.messages.append(self.allocator, m) catch return storage.Error.OutOfMemory;
                continue; // don't increment i — element at i was removed
            }
            // No DLQ found — fall through and deliver normally (matches
            // AWS behaviour when the DLQ has been deleted).
        };

        m.receive_count += 1;
        m.visible_unix = now + vt;
        writeMessageJson(self, slot.name, m) catch return storage.Error.Io;

        const receipt = buildReceiptHandle(allocator, slot.name, m.id, m.receive_count) catch
            return storage.Error.OutOfMemory;
        try out.append(allocator, .{
            .message_id = allocator.dupe(u8, m.id) catch return storage.Error.OutOfMemory,
            .receipt_handle = receipt,
            .body = allocator.dupe(u8, m.body) catch return storage.Error.OutOfMemory,
            .md5_of_body = allocator.dupe(u8, &m.md5_of_body) catch return storage.Error.OutOfMemory,
            .raw_attributes_json = if (m.raw_attributes_json) |s|
                (allocator.dupe(u8, s) catch return storage.Error.OutOfMemory)
            else
                null,
        });
        i += 1;
    }

    return .{ .messages = out.toOwnedSlice(allocator) catch return storage.Error.OutOfMemory };
}

const Redrive = struct {
    dlq_name: []const u8,
    max_receive_count: u32,
};

/// Parse a RedrivePolicy JSON string of the form
/// `{"deadLetterTargetArn":"arn:aws:sqs:region:account:name","maxReceiveCount":N}`.
/// Returns null on missing-or-malformed (we don't reject — matches AWS).
/// The returned `dlq_name` slice points into the input `json_str`, so
/// callers must hold the slot's lifetime for the duration of use.
fn parseRedrivePolicy(json_str: ?[]const u8) ?Redrive {
    const s = json_str orelse return null;
    // Find "deadLetterTargetArn":"...":name" by manual scan to avoid
    // depending on parsed-arena lifetimes. We accept whitespace + ASCII
    // only; the JSON shape AWS sends is always tight.
    const arn_key = "\"deadLetterTargetArn\"";
    const max_key = "\"maxReceiveCount\"";
    const arn_idx = std.mem.indexOf(u8, s, arn_key) orelse return null;

    // Skip `:`, whitespace, then expect `"...arn..."`.
    var cur = arn_idx + arn_key.len;
    while (cur < s.len and (s[cur] == ':' or s[cur] == ' ')) : (cur += 1) {}
    if (cur >= s.len or s[cur] != '"') return null;
    cur += 1;
    const arn_start = cur;
    while (cur < s.len and s[cur] != '"') : (cur += 1) {}
    if (cur >= s.len) return null;
    const arn = s[arn_start..cur];

    const max_idx = std.mem.indexOf(u8, s, max_key) orelse return null;
    cur = max_idx + max_key.len;
    while (cur < s.len and (s[cur] == ':' or s[cur] == ' ')) : (cur += 1) {}
    // maxReceiveCount may be quoted (string) or unquoted (integer).
    var num_start = cur;
    if (s[cur] == '"') {
        cur += 1;
        num_start = cur;
        while (cur < s.len and s[cur] != '"') : (cur += 1) {}
    } else {
        while (cur < s.len and (s[cur] == '-' or (s[cur] >= '0' and s[cur] <= '9'))) : (cur += 1) {}
    }
    const max_str = s[num_start..cur];
    const max: u32 = std.fmt.parseInt(u32, max_str, 10) catch return null;

    const last_colon = std.mem.lastIndexOfScalar(u8, arn, ':') orelse return null;
    return .{ .dlq_name = arn[last_colon + 1 ..], .max_receive_count = max };
}

pub fn sqsDeleteMessage(self: *Fs, in: storage.DeleteMessageInput) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(in.queue_name) orelse return storage.Error.QueueNotFound;
    var decoded_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer decoded_arena.deinit();
    const dec = decodeReceiptHandle(decoded_arena.allocator(), in.receipt_handle) catch
        return storage.Error.InvalidReceiptHandle;
    if (!std.mem.eql(u8, dec.queue_name, slot.name)) return storage.Error.InvalidReceiptHandle;

    var found_idx: ?usize = null;
    for (slot.messages.items, 0..) |m, i| {
        if (std.mem.eql(u8, m.id, dec.message_id)) {
            found_idx = i;
            break;
        }
    }
    // AWS: DeleteMessage on an already-deleted message is idempotent.
    const idx = found_idx orelse return;

    const m = slot.messages.orderedRemove(idx);
    var path_buf: [4096]u8 = undefined;
    const path = messagePath(self, slot.name, m.id, &path_buf) catch return storage.Error.Io;
    Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return storage.Error.Io,
    };
    m.deinit(self.allocator);
    self.allocator.destroy(m);
}

// ---------------------------------------------------------------------------
// SQS tags (v0.3.0 Phase 5)

fn queueTagsPath(self: *Fs, name: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/sqs/queues/{s}/tags.json", .{ self.base_dir, name });
}

fn writeQueueTags(self: *Fs, slot: *const storage.SqsQueueSlot) !void {
    var dir_buf: [4096]u8 = undefined;
    const dir_path = try queueDirPath(self, slot.name, &dir_buf);
    try Io.Dir.cwd().createDirPath(self.io, dir_path);

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    var it = slot.tags.iterator();
    while (it.next()) |entry| {
        try s.objectField(entry.key_ptr.*);
        try s.write(entry.value_ptr.*);
    }
    try s.endObject();
    const body = try aw.toOwnedSlice();
    defer self.allocator.free(body);

    var path_buf: [4096]u8 = undefined;
    const path = try queueTagsPath(self, slot.name, &path_buf);
    try writeAtomic(self.io, path, body);
}

fn loadQueueTags(self: *Fs, slot: *storage.SqsQueueSlot) void {
    var path_buf: [4096]u8 = undefined;
    const path = queueTagsPath(self, slot.name, &path_buf) catch return;
    const body = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024)) catch return;
    defer self.allocator.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const k = self.allocator.dupe(u8, entry.key_ptr.*) catch return;
        const v = self.allocator.dupe(u8, entry.value_ptr.*.string) catch {
            self.allocator.free(k);
            return;
        };
        slot.tags.put(self.allocator, k, v) catch {
            self.allocator.free(k);
            self.allocator.free(v);
            return;
        };
    }
}

pub fn sqsTagQueue(self: *Fs, in: storage.TagQueueInput) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(in.queue_name) orelse return storage.Error.QueueNotFound;
    for (in.tags) |t| {
        // Replace if present (free old value), insert otherwise.
        if (slot.tags.fetchRemove(t.key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        if (slot.tags.count() >= 50) return storage.Error.TooManyEntries;
        const k = self.allocator.dupe(u8, t.key) catch return storage.Error.OutOfMemory;
        const v = self.allocator.dupe(u8, t.value) catch {
            self.allocator.free(k);
            return storage.Error.OutOfMemory;
        };
        slot.tags.put(self.allocator, k, v) catch {
            self.allocator.free(k);
            self.allocator.free(v);
            return storage.Error.OutOfMemory;
        };
    }
    writeQueueTags(self, slot) catch return storage.Error.Io;
}

pub fn sqsUntagQueue(self: *Fs, in: storage.UntagQueueInput) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(in.queue_name) orelse return storage.Error.QueueNotFound;
    for (in.keys) |k| {
        if (slot.tags.fetchRemove(k)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }
    writeQueueTags(self, slot) catch return storage.Error.Io;
}

pub fn sqsListQueueTags(self: *Fs, allocator: Allocator, queue_name: []const u8) storage.Error!storage.ListQueueTagsOutput {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(queue_name) orelse return storage.Error.QueueNotFound;
    var out = allocator.alloc(storage.Tag, slot.tags.count()) catch return storage.Error.OutOfMemory;
    var i: usize = 0;
    var it = slot.tags.iterator();
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{
            .key = allocator.dupe(u8, entry.key_ptr.*) catch return storage.Error.OutOfMemory,
            .value = allocator.dupe(u8, entry.value_ptr.*) catch return storage.Error.OutOfMemory,
        };
    }
    return .{ .tags = out };
}

pub fn sqsChangeMessageVisibility(self: *Fs, in: storage.ChangeMessageVisibilityInput) storage.Error!void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const slot = self.sqs_queues.get(in.queue_name) orelse return storage.Error.QueueNotFound;
    var decoded_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer decoded_arena.deinit();
    const dec = decodeReceiptHandle(decoded_arena.allocator(), in.receipt_handle) catch
        return storage.Error.InvalidReceiptHandle;
    if (!std.mem.eql(u8, dec.queue_name, slot.name)) return storage.Error.InvalidReceiptHandle;

    for (slot.messages.items) |m| {
        if (std.mem.eql(u8, m.id, dec.message_id)) {
            const now = nowUnixSeconds(self.io);
            m.visible_unix = now + @as(i64, @intCast(in.visibility_timeout));
            writeMessageJson(self, slot.name, m) catch return storage.Error.Io;
            return;
        }
    }
    return storage.Error.MessageNotFound;
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
