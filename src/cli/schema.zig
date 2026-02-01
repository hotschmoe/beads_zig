//! Schema command for beads_zig.
//!
//! Displays the storage schema (JSONL field definitions).
//! Unlike SQLite-based storage, beads_zig uses JSONL files,
//! so this command shows the JSON schema for issues.

const std = @import("std");
const output = @import("../output/mod.zig");
const Issue = @import("../models/issue.zig").Issue;
const Status = @import("../models/status.zig").Status;
const Priority = @import("../models/priority.zig").Priority;
const IssueType = @import("../models/issue_type.zig").IssueType;

pub const SchemaError = error{
    WriteError,
    OutOfMemory,
};

pub const SchemaObject = struct {
    name: []const u8,
    obj_type: []const u8,
    description: []const u8,
};

pub const SchemaResult = struct {
    success: bool = true,
};

const ISSUE_SCHEMA =
    \\## Issue (beads.jsonl)
    \\
    \\One JSON object per line in the main JSONL file.
    \\
    \\### Fields
    \\
    \\| Field | Type | Required | Description |
    \\|-------|------|----------|-------------|
    \\| id | string | yes | Issue ID (bd-XXXXX format) |
    \\| content_hash | string | no | SHA256 hash for deduplication |
    \\| title | string | yes | Issue title (1-500 chars) |
    \\| description | string | no | Detailed description |
    \\| design | string | no | Design notes |
    \\| acceptance_criteria | string | no | Definition of done |
    \\| notes | string | no | Additional notes |
    \\| status | string | yes | open, in_progress, blocked, deferred, closed, tombstone, pinned |
    \\| priority | number | yes | 0 (critical) to 4 (backlog) |
    \\| issue_type | string | yes | task, bug, feature, epic, chore, docs, question |
    \\| assignee | string | no | Assigned user |
    \\| owner | string | no | Issue owner |
    \\| created_at | string | yes | RFC3339 timestamp |
    \\| created_by | string | no | Creator |
    \\| updated_at | string | yes | RFC3339 timestamp |
    \\| closed_at | string | no | RFC3339 timestamp when closed |
    \\| close_reason | string | no | Reason for closing |
    \\| due_at | string | no | RFC3339 due date |
    \\| defer_until | string | no | RFC3339 defer date |
    \\| estimated_minutes | number | no | Time estimate |
    \\| external_ref | string | no | External tracker link |
    \\| source_system | string | no | Import source |
    \\| pinned | boolean | yes | High-priority display flag |
    \\| is_template | boolean | yes | Template flag |
    \\| labels | array | yes | String array of labels |
    \\| dependencies | array | yes | Array of Dependency objects |
    \\| comments | array | yes | Array of Comment objects |
    \\
;

const WAL_SCHEMA =
    \\## WAL Entry (beads.wal)
    \\
    \\Write-ahead log for concurrent writes.
    \\
    \\### Fields
    \\
    \\| Field | Type | Description |
    \\|-------|------|-------------|
    \\| op | string | add, update, close, reopen, delete, set_blocked, unset_blocked |
    \\| ts | number | Unix timestamp for ordering |
    \\| id | string | Issue ID |
    \\| data | object | Full Issue object (for add/update) or null |
    \\
;

const DEPENDENCY_SCHEMA =
    \\## Dependency
    \\
    \\Embedded in Issue.dependencies array.
    \\
    \\### Fields
    \\
    \\| Field | Type | Description |
    \\|-------|------|-------------|
    \\| issue_id | string | Dependent issue |
    \\| depends_on_id | string | Blocker issue |
    \\| dep_type | string | blocks, parent_child, waits_for, related, etc. |
    \\| created_at | string | RFC3339 timestamp |
    \\| created_by | string | Creator |
    \\| metadata | string | JSON blob for extra data |
    \\| thread_id | string | Optional thread reference |
    \\
;

const COMMENT_SCHEMA =
    \\## Comment
    \\
    \\Embedded in Issue.comments array.
    \\
    \\### Fields
    \\
    \\| Field | Type | Description |
    \\|-------|------|-------------|
    \\| id | number | Comment ID |
    \\| issue_id | string | Parent issue ID |
    \\| author | string | Comment author |
    \\| body | string | Comment text |
    \\| created_at | string | RFC3339 timestamp |
    \\
;

pub fn run(global: anytype, allocator: std.mem.Allocator) SchemaError!SchemaResult {
    var out = output.Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    const objects = [_]SchemaObject{
        .{ .name = "Issue", .obj_type = "entity", .description = "Primary issue record stored in beads.jsonl" },
        .{ .name = "WalEntry", .obj_type = "log", .description = "WAL operation entry in beads.wal" },
        .{ .name = "Dependency", .obj_type = "embedded", .description = "Dependency relationship" },
        .{ .name = "Comment", .obj_type = "embedded", .description = "Issue comment" },
    };

    if (global.json) {
        out.printJson(.{
            .storage_type = "jsonl",
            .files = .{
                .main = "beads.jsonl",
                .wal = "beads.wal",
                .lock = "beads.lock",
            },
            .objects = objects,
        }) catch return SchemaError.WriteError;
    } else {
        out.raw(
            \\# beads_zig Storage Schema
            \\
            \\Storage Type: JSONL (JSON Lines)
            \\
            \\## Files
            \\
            \\- `.beads/beads.jsonl` - Main issue storage (git-tracked)
            \\- `.beads/beads.wal` - Write-ahead log (gitignored)
            \\- `.beads/beads.lock` - Lock file for flock (gitignored)
            \\
            \\
        ) catch return SchemaError.WriteError;

        out.raw(ISSUE_SCHEMA) catch return SchemaError.WriteError;
        out.raw("\n") catch return SchemaError.WriteError;
        out.raw(WAL_SCHEMA) catch return SchemaError.WriteError;
        out.raw("\n") catch return SchemaError.WriteError;
        out.raw(DEPENDENCY_SCHEMA) catch return SchemaError.WriteError;
        out.raw("\n") catch return SchemaError.WriteError;
        out.raw(COMMENT_SCHEMA) catch return SchemaError.WriteError;
    }

    return .{};
}

// --- Tests ---

test "run displays schema" {
    const allocator = std.testing.allocator;

    _ = try run(.{
        .json = false,
        .toon = false,
        .quiet = true,
        .no_color = true,
    }, allocator);
}

test "run with json option" {
    const allocator = std.testing.allocator;

    _ = try run(.{
        .json = true,
        .toon = false,
        .quiet = false,
        .no_color = true,
    }, allocator);
}
