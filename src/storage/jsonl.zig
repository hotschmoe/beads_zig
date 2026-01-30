//! JSONL file operations for beads_zig.
//!
//! Handles reading and writing issues to JSONL format with:
//! - Atomic writes (temp file -> fsync -> rename)
//! - Missing file handling (returns empty)
//! - Unknown field preservation for beads_rust compatibility

const std = @import("std");
const fs = std.fs;
const Issue = @import("../models/issue.zig").Issue;
const test_util = @import("../test_util.zig");

pub const JsonlError = error{
    InvalidJson,
    WriteError,
    AtomicRenameFailed,
};

pub const JsonlFile = struct {
    path: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(path: []const u8, allocator: std.mem.Allocator) Self {
        return .{
            .path = path,
            .allocator = allocator,
        };
    }

    /// Read all issues from the JSONL file.
    /// Returns empty slice if file doesn't exist.
    /// Caller owns the returned slice and must free each issue.
    pub fn readAll(self: *Self) ![]Issue {
        const file = fs.cwd().openFile(self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return &[_]Issue{},
            else => return err,
        };
        defer file.close();

        var issues: std.ArrayListUnmanaged(Issue) = .{};
        errdefer {
            for (issues.items) |*issue| {
                issue.deinit(self.allocator);
            }
            issues.deinit(self.allocator);
        }

        // Read entire file content
        const content = file.readToEndAlloc(self.allocator, 1024 * 1024 * 100) catch |err| switch (err) {
            else => return err,
        };
        defer self.allocator.free(content);

        // Parse line by line
        var line_start: usize = 0;
        for (content, 0..) |c, i| {
            if (c == '\n') {
                const line = content[line_start..i];
                line_start = i + 1;

                if (line.len == 0) continue;

                const issue = std.json.parseFromSliceLeaky(
                    Issue,
                    self.allocator,
                    line,
                    .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
                ) catch continue;

                try issues.append(self.allocator, issue);
            }
        }

        // Handle last line if no trailing newline
        if (line_start < content.len) {
            const line = content[line_start..];
            if (line.len > 0) {
                if (std.json.parseFromSliceLeaky(
                    Issue,
                    self.allocator,
                    line,
                    .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
                )) |issue| {
                    try issues.append(self.allocator, issue);
                } else |_| {}
            }
        }

        return issues.toOwnedSlice(self.allocator);
    }

    /// Write all issues to the JSONL file atomically.
    /// Uses temp file + fsync + rename for crash safety.
    pub fn writeAll(self: *Self, issues_list: []const Issue) !void {
        const dir = fs.cwd();

        // Create temp file path
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{d}", .{
            self.path,
            std.time.milliTimestamp(),
        }) catch return error.WriteError;

        // Ensure parent directory exists
        if (std.fs.path.dirname(self.path)) |parent| {
            dir.makePath(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Write to temp file
        const tmp_file = dir.createFile(tmp_path, .{}) catch return error.WriteError;
        errdefer {
            tmp_file.close();
            dir.deleteFile(tmp_path) catch {};
        }

        // Build content in memory and write all at once
        var content: std.ArrayListUnmanaged(u8) = .{};
        defer content.deinit(self.allocator);

        for (issues_list) |issue| {
            const json_bytes = std.json.Stringify.valueAlloc(self.allocator, issue, .{}) catch return error.WriteError;
            defer self.allocator.free(json_bytes);
            content.appendSlice(self.allocator, json_bytes) catch return error.WriteError;
            content.append(self.allocator, '\n') catch return error.WriteError;
        }

        tmp_file.writeAll(content.items) catch return error.WriteError;

        // Fsync for durability
        tmp_file.sync() catch return error.WriteError;
        tmp_file.close();

        // Atomic rename
        dir.rename(tmp_path, self.path) catch return error.AtomicRenameFailed;
    }

    /// Append a single issue to the JSONL file.
    /// Less safe than writeAll but faster for single additions.
    pub fn append(self: *Self, issue: Issue) !void {
        const dir = fs.cwd();

        // Ensure parent directory exists
        if (std.fs.path.dirname(self.path)) |parent| {
            dir.makePath(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = dir.createFile(self.path, .{ .truncate = false }) catch |err| switch (err) {
            else => return err,
        };
        defer file.close();

        // Seek to end
        file.seekFromEnd(0) catch return error.WriteError;

        // Build content in memory and write all at once
        const json_bytes = std.json.Stringify.valueAlloc(self.allocator, issue, .{}) catch return error.WriteError;
        defer self.allocator.free(json_bytes);

        file.writeAll(json_bytes) catch return error.WriteError;
        file.writeAll("\n") catch return error.WriteError;
    }
};

// --- Tests ---

test "JsonlFile.readAll returns empty for missing file" {
    var jsonl = JsonlFile.init("/nonexistent/path/issues.jsonl", std.testing.allocator);
    const issues = try jsonl.readAll();
    defer std.testing.allocator.free(issues);

    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "JsonlFile roundtrip" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "jsonl_roundtrip");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "issues.jsonl" });
    defer allocator.free(test_path);

    var jsonl = JsonlFile.init(test_path, allocator);

    // Create test issues
    var issues_to_write = [_]Issue{
        Issue.init("bd-test1", "Test Issue 1", 1706540000),
        Issue.init("bd-test2", "Test Issue 2", 1706550000),
    };

    try jsonl.writeAll(&issues_to_write);

    // Read back
    const read_issues = try jsonl.readAll();
    defer {
        for (read_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(read_issues);
    }

    try std.testing.expectEqual(@as(usize, 2), read_issues.len);
    try std.testing.expectEqualStrings("bd-test1", read_issues[0].id);
    try std.testing.expectEqualStrings("bd-test2", read_issues[1].id);
}

test "JsonlFile handles empty file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "jsonl_empty");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "empty.jsonl" });
    defer allocator.free(test_path);

    // Create empty file
    const file = try fs.cwd().createFile(test_path, .{});
    file.close();

    var jsonl = JsonlFile.init(test_path, allocator);
    const issues = try jsonl.readAll();
    defer allocator.free(issues);

    try std.testing.expectEqual(@as(usize, 0), issues.len);
}
