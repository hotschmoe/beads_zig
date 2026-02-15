//! Schema command for beads_zig.
//!
//! Outputs JSON Schema (draft-07) describing the output types that
//! commands produce (matching br's schema command).

const std = @import("std");
const output = @import("../output/mod.zig");
const version_cmd = @import("version.zig");

pub const SchemaError = error{
    WriteError,
    OutOfMemory,
};

pub const SchemaResult = struct {
    success: bool = true,
};

pub fn run(global: anytype, allocator: std.mem.Allocator) SchemaError!SchemaResult {
    var out = output.Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    // Build timestamp string
    const now = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var ts_buf: [25]u8 = undefined;
    const generated_at = std.fmt.bufPrint(&ts_buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @as(u32, month_day.month.numeric()),
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "unknown";

    // Schema is always JSON output (even in text mode, matching br)
    out.raw(
        \\{
        \\  "tool": "bz",
        \\  "generated_at": "
    ) catch return SchemaError.WriteError;
    out.raw(generated_at) catch return SchemaError.WriteError;
    out.raw(
        \\",
        \\  "schemas": {
        \\    "Issue": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "Issue",
        \\      "description": "A beads issue",
        \\      "type": "object",
        \\      "required": ["id", "title", "status", "priority", "issue_type", "created_at", "updated_at"],
        \\      "properties": {
        \\        "id": {"type": "string", "description": "Issue ID (prefix-hash format)"},
        \\        "title": {"type": "string", "description": "Issue title"},
        \\        "description": {"type": ["string", "null"], "description": "Detailed description"},
        \\        "status": {"type": "string", "enum": ["open", "in_progress", "blocked", "deferred", "closed", "tombstone", "pinned"]},
        \\        "priority": {"type": "integer", "minimum": 0, "maximum": 4},
        \\        "issue_type": {"type": "string", "enum": ["task", "bug", "feature", "epic", "chore", "docs", "question"]},
        \\        "assignee": {"type": ["string", "null"]},
        \\        "created_at": {"type": "string", "format": "date-time"},
        \\        "created_by": {"type": ["string", "null"]},
        \\        "updated_at": {"type": "string", "format": "date-time"},
        \\        "closed_at": {"type": ["string", "null"], "format": "date-time"},
        \\        "labels": {"type": "array", "items": {"type": "string"}},
        \\        "dependencies": {"type": "array", "items": {"$ref": "#/schemas/DependencyInfo"}},
        \\        "comments": {"type": "array", "items": {"$ref": "#/schemas/Comment"}}
        \\      }
        \\    },
        \\    "DependencyInfo": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "DependencyInfo",
        \\      "description": "A dependency relationship between issues",
        \\      "type": "object",
        \\      "required": ["issue_id", "depends_on_id", "dep_type"],
        \\      "properties": {
        \\        "issue_id": {"type": "string"},
        \\        "depends_on_id": {"type": "string"},
        \\        "dep_type": {"type": "string", "enum": ["blocks", "parent_child", "waits_for", "related"]},
        \\        "created_at": {"type": "string", "format": "date-time"},
        \\        "created_by": {"type": ["string", "null"]}
        \\      }
        \\    },
        \\    "Comment": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "Comment",
        \\      "description": "An issue comment",
        \\      "type": "object",
        \\      "required": ["id", "issue_id", "author", "text", "created_at"],
        \\      "properties": {
        \\        "id": {"type": "integer"},
        \\        "issue_id": {"type": "string"},
        \\        "author": {"type": "string"},
        \\        "text": {"type": "string"},
        \\        "created_at": {"type": "string", "format": "date-time"}
        \\      }
        \\    },
        \\    "CountResult": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "CountResult",
        \\      "description": "Result of a count query",
        \\      "type": "object",
        \\      "required": ["count"],
        \\      "properties": {
        \\        "count": {"type": "integer"}
        \\      }
        \\    },
        \\    "StatsResult": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "StatsResult",
        \\      "description": "Project statistics summary",
        \\      "type": "object",
        \\      "required": ["summary"],
        \\      "properties": {
        \\        "summary": {
        \\          "type": "object",
        \\          "properties": {
        \\            "total_issues": {"type": "integer"},
        \\            "open_issues": {"type": "integer"},
        \\            "in_progress_issues": {"type": "integer"},
        \\            "closed_issues": {"type": "integer"},
        \\            "blocked_issues": {"type": "integer"},
        \\            "deferred_issues": {"type": "integer"},
        \\            "ready_issues": {"type": "integer"}
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "InfoResult": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "InfoResult",
        \\      "description": "Workspace information",
        \\      "type": "object",
        \\      "required": ["database_path", "beads_dir", "mode", "issue_count", "db_size"],
        \\      "properties": {
        \\        "database_path": {"type": "string"},
        \\        "beads_dir": {"type": "string"},
        \\        "mode": {"type": "string"},
        \\        "daemon_connected": {"type": "boolean"},
        \\        "issue_count": {"type": "integer"},
        \\        "db_size": {"type": "integer"}
        \\      }
        \\    },
        \\    "DoctorResult": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "DoctorResult",
        \\      "description": "Health check results",
        \\      "type": "object",
        \\      "required": ["checks"],
        \\      "properties": {
        \\        "checks": {
        \\          "type": "array",
        \\          "items": {
        \\            "type": "object",
        \\            "properties": {
        \\              "name": {"type": "string"},
        \\              "status": {"type": "string", "enum": ["ok", "warn", "error"]},
        \\              "message": {"type": "string"}
        \\            }
        \\          }
        \\        }
        \\      }
        \\    },
        \\    "BlockedIssue": {
        \\      "$schema": "http://json-schema.org/draft-07/schema#",
        \\      "title": "BlockedIssue",
        \\      "description": "An issue that is blocked by dependencies",
        \\      "type": "object",
        \\      "required": ["id", "title", "status", "priority", "blocked_by"],
        \\      "properties": {
        \\        "id": {"type": "string"},
        \\        "title": {"type": "string"},
        \\        "status": {"type": "string"},
        \\        "priority": {"type": "integer"},
        \\        "blocked_by": {"type": "array", "items": {"type": "string"}},
        \\        "blocks": {"type": "array", "items": {"type": "string"}}
        \\      }
        \\    }
        \\  }
        \\}
        \\
    ) catch return SchemaError.WriteError;

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
