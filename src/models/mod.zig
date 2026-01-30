//! Data model definitions for beads_zig.
//!
//! Core types:
//! - Issue: Primary entity with all fields
//! - Status, Priority, IssueType: Classification enums
//! - Dependency: Issue relationships
//! - Comment: Issue comments
//! - Event: Audit log entries
//!
//! Utilities:
//! - timestamp: RFC3339 parsing/formatting for JSONL compatibility
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
pub const Issue = @import("issue.zig").Issue;
pub const IssueError = @import("issue.zig").IssueError;
pub const Rfc3339Timestamp = @import("issue.zig").Rfc3339Timestamp;
pub const OptionalRfc3339Timestamp = @import("issue.zig").OptionalRfc3339Timestamp;

// Timestamp utilities
pub const timestamp = @import("timestamp.zig");
pub const TimestampError = timestamp.TimestampError;
pub const parseRfc3339 = timestamp.parseRfc3339;
pub const parseRfc3339Strict = timestamp.parseRfc3339Strict;
pub const formatRfc3339 = timestamp.formatRfc3339;
pub const formatRfc3339Alloc = timestamp.formatRfc3339Alloc;
pub const timestampNow = timestamp.now;
pub const RFC3339_LEN = timestamp.RFC3339_LEN;
pub const RFC3339_BUFFER_SIZE = timestamp.RFC3339_BUFFER_SIZE;

test {
    std.testing.refAllDecls(@This());
}
