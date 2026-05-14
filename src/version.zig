//! Single source of truth for the version string.
//!
//! Versioning scheme (see CHANGELOG.md):
//!   patch — significant pinned cut of work
//!   minor — one AWS service fully implemented
//!   major — curated multi-service surface ready for real workflows

pub const string: []const u8 = "0.0.2";
