//! Data model definitions for beads_zig.
//!
//! Core types:
//! - Issue: Primary entity with all fields
//! - Status, Priority, IssueType: Classification enums
//! - Dependency: Issue relationships
//! - Comment: Issue comments
//! - Event: Audit log entries
//!
//! All models support JSON serialization for JSONL export.

const std = @import("std");

pub const Status = @import("status.zig").Status;
pub const Priority = @import("priority.zig").Priority;

test {
    std.testing.refAllDecls(@This());
}
