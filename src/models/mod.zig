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
pub const IssueType = @import("issue_type.zig").IssueType;
pub const DependencyType = @import("dependency.zig").DependencyType;
pub const Dependency = @import("dependency.zig").Dependency;
pub const Comment = @import("comment.zig").Comment;
pub const CommentError = @import("comment.zig").CommentError;
pub const EventType = @import("event.zig").EventType;
pub const Event = @import("event.zig").Event;
pub const EventError = @import("event.zig").EventError;

test {
    std.testing.refAllDecls(@This());
}
