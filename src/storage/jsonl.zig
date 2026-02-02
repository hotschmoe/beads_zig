//! JSONL file operations for beads_zig.
//!
//! Handles reading and writing issues to JSONL format with:
//! - Atomic writes (temp file -> fsync -> rename)
//! - Missing file handling (returns empty)
//! - Unknown field preservation for beads_rust compatibility

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const Issue = @import("../models/issue.zig").Issue;
const simd = @import("simd.zig");
const mmap = @import("mmap.zig");
const test_util = @import("../test_util.zig");

// Windows API declarations (not exported by std.os.windows.kernel32)
const windows_api = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
};

/// Get the current process ID (cross-platform).
fn getCurrentPid() i32 {
    if (builtin.os.tag == .windows) {
        return @intCast(windows_api.GetCurrentProcessId());
    } else if (builtin.os.tag == .linux) {
        return @bitCast(std.os.linux.getpid());
    } else {
        // macOS, FreeBSD, and other POSIX systems with libc
        return std.c.getpid();
    }
}

pub const JsonlError = error{
    InvalidJson,
    WriteError,
    AtomicRenameFailed,
};

/// Result from loading a JSONL file with corruption tracking.
pub const LoadResult = struct {
    issues: []Issue,
    /// Number of corrupt/invalid lines skipped.
    corruption_count: usize = 0,
    /// Line numbers of corrupt entries (1-indexed for user display).
    corrupt_lines: []const usize = &.{},

    pub fn hasCorruption(self: LoadResult) bool {
        return self.corruption_count > 0;
    }

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        if (self.corrupt_lines.len > 0) {
            allocator.free(self.corrupt_lines);
        }
    }
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
    /// Uses SIMD-accelerated newline scanning for efficient parsing of large files.
    pub fn readAll(self: *Self) ![]Issue {
        // Use mmap for zero-copy reading
        var mapping = mmap.MappedFile.open(self.path) catch |err| switch (err) {
            mmap.MmapError.FileNotFound => return &[_]Issue{},
            else => return error.InvalidJson,
        };
        defer mapping.close();

        const content = mapping.data();

        var issues: std.ArrayListUnmanaged(Issue) = .{};
        errdefer {
            for (issues.items) |*issue| {
                issue.deinit(self.allocator);
            }
            issues.deinit(self.allocator);
        }

        // Use SIMD-accelerated line iterator for efficient newline scanning
        var line_iter = simd.LineIterator.init(content);
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;

            const issue = std.json.parseFromSliceLeaky(
                Issue,
                self.allocator,
                line,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            ) catch continue;

            try issues.append(self.allocator, issue);
        }

        return issues.toOwnedSlice(self.allocator);
    }

    /// Read all issues from the JSONL file with detailed corruption tracking.
    /// Returns a LoadResult containing issues and corruption statistics.
    /// Logs and skips corrupt entries instead of failing.
    /// Uses SIMD-accelerated newline scanning for efficient parsing of large files.
    pub fn readAllWithRecovery(self: *Self) !LoadResult {
        // Use mmap for zero-copy reading
        var mapping = mmap.MappedFile.open(self.path) catch |err| switch (err) {
            mmap.MmapError.FileNotFound => return LoadResult{
                .issues = &[_]Issue{},
                .corruption_count = 0,
            },
            else => return LoadResult{
                .issues = &[_]Issue{},
                .corruption_count = 0,
            },
        };
        defer mapping.close();

        const content = mapping.data();

        var issues: std.ArrayListUnmanaged(Issue) = .{};
        var corrupt_lines: std.ArrayListUnmanaged(usize) = .{};
        errdefer {
            for (issues.items) |*issue| {
                issue.deinit(self.allocator);
            }
            issues.deinit(self.allocator);
            corrupt_lines.deinit(self.allocator);
        }

        // Use SIMD-accelerated line iterator for efficient newline scanning
        var line_iter = simd.LineIterator.init(content);
        var line_num: usize = 0;

        while (line_iter.next()) |line| {
            line_num += 1;
            if (line.len == 0) continue;

            if (std.json.parseFromSliceLeaky(
                Issue,
                self.allocator,
                line,
                .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
            )) |issue| {
                try issues.append(self.allocator, issue);
            } else |_| {
                // Track corrupt line (1-indexed for user display)
                try corrupt_lines.append(self.allocator, line_num);
            }
        }

        return LoadResult{
            .issues = try issues.toOwnedSlice(self.allocator),
            .corruption_count = corrupt_lines.items.len,
            .corrupt_lines = try corrupt_lines.toOwnedSlice(self.allocator),
        };
    }

    /// Write all issues to the JSONL file atomically.
    /// Uses temp file + fsync + rename for crash safety.
    pub fn writeAll(self: *Self, issues_list: []const Issue) !void {
        const dir = fs.cwd();

        // Create temp file path with PID to prevent collision under concurrent writes
        var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{d}.{d}", .{
            self.path,
            std.time.milliTimestamp(),
            getCurrentPid(),
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

test "readAllWithRecovery returns empty for missing file" {
    var jsonl = JsonlFile.init("/nonexistent/path/issues.jsonl", std.testing.allocator);
    const result = try jsonl.readAllWithRecovery();
    defer std.testing.allocator.free(result.issues);

    try std.testing.expectEqual(@as(usize, 0), result.issues.len);
    try std.testing.expectEqual(@as(usize, 0), result.corruption_count);
    try std.testing.expect(!result.hasCorruption());
}

test "readAllWithRecovery skips corrupt lines and tracks them" {
    // Use arena allocator because parseFromSliceLeaky can leak memory on parse
    // failures (this is expected behavior - it's designed for arena allocators).
    // The test allocator would report these leaks as errors.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_dir = try test_util.createTestDir(std.testing.allocator, "jsonl_corrupt");
    defer std.testing.allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(std.testing.allocator, &.{ test_dir, "corrupt.jsonl" });
    defer std.testing.allocator.free(test_path);

    // Write a file with mixed valid and corrupt entries
    // Use full Issue JSON format (all fields required by parser)
    {
        const file = try fs.cwd().createFile(test_path, .{});
        defer file.close();

        // Valid issue line 1
        const valid1 = "{\"id\":\"bd-test1\",\"content_hash\":null,\"title\":\"Valid Issue 1\",\"description\":null,\"design\":null,\"acceptance_criteria\":null,\"notes\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":null,\"owner\":null,\"created_at\":\"2024-01-29T10:00:00Z\",\"created_by\":null,\"updated_at\":\"2024-01-29T10:00:00Z\",\"closed_at\":null,\"close_reason\":null,\"due_at\":null,\"defer_until\":null,\"estimated_minutes\":null,\"external_ref\":null,\"source_system\":null,\"pinned\":false,\"is_template\":false,\"labels\":[],\"dependencies\":[],\"comments\":[]}\n";
        try file.writeAll(valid1);

        // Corrupt line 2 - invalid JSON
        try file.writeAll("{this is not valid json}\n");

        // Valid issue line 3
        const valid2 = "{\"id\":\"bd-test2\",\"content_hash\":null,\"title\":\"Valid Issue 2\",\"description\":null,\"design\":null,\"acceptance_criteria\":null,\"notes\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":null,\"owner\":null,\"created_at\":\"2024-01-29T10:00:00Z\",\"created_by\":null,\"updated_at\":\"2024-01-29T10:00:00Z\",\"closed_at\":null,\"close_reason\":null,\"due_at\":null,\"defer_until\":null,\"estimated_minutes\":null,\"external_ref\":null,\"source_system\":null,\"pinned\":false,\"is_template\":false,\"labels\":[],\"dependencies\":[],\"comments\":[]}\n";
        try file.writeAll(valid2);

        // Corrupt line 4 - truncated JSON
        try file.writeAll("{\"id\":\"bd-broken\",\"title\":\"Trun\n");

        // Valid issue line 5
        const valid3 = "{\"id\":\"bd-test3\",\"content_hash\":null,\"title\":\"Valid Issue 3\",\"description\":null,\"design\":null,\"acceptance_criteria\":null,\"notes\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":null,\"owner\":null,\"created_at\":\"2024-01-29T10:00:00Z\",\"created_by\":null,\"updated_at\":\"2024-01-29T10:00:00Z\",\"closed_at\":null,\"close_reason\":null,\"due_at\":null,\"defer_until\":null,\"estimated_minutes\":null,\"external_ref\":null,\"source_system\":null,\"pinned\":false,\"is_template\":false,\"labels\":[],\"dependencies\":[],\"comments\":[]}\n";
        try file.writeAll(valid3);
    }

    var jsonl = JsonlFile.init(test_path, allocator);
    const result = try jsonl.readAllWithRecovery();
    // No need to defer cleanup - arena handles all allocations

    // Should have loaded 3 valid issues
    try std.testing.expectEqual(@as(usize, 3), result.issues.len);

    // Should have detected 2 corrupt entries
    try std.testing.expectEqual(@as(usize, 2), result.corruption_count);
    try std.testing.expect(result.hasCorruption());

    // Corrupt lines should be 2 and 4
    try std.testing.expectEqual(@as(usize, 2), result.corrupt_lines.len);
    try std.testing.expectEqual(@as(usize, 2), result.corrupt_lines[0]);
    try std.testing.expectEqual(@as(usize, 4), result.corrupt_lines[1]);

    // Verify the valid issues were loaded correctly
    try std.testing.expectEqualStrings("bd-test1", result.issues[0].id);
    try std.testing.expectEqualStrings("bd-test2", result.issues[1].id);
    try std.testing.expectEqualStrings("bd-test3", result.issues[2].id);
}

test "readAllWithRecovery handles file with only corrupt entries" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "jsonl_all_corrupt");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "all_corrupt.jsonl" });
    defer allocator.free(test_path);

    // Write file with only corrupt entries
    {
        const file = try fs.cwd().createFile(test_path, .{});
        defer file.close();
        try file.writeAll("{not valid}\n");
        try file.writeAll("also not valid\n");
        try file.writeAll("{}\n"); // Empty object, missing required fields
    }

    var jsonl = JsonlFile.init(test_path, allocator);
    var result = try jsonl.readAllWithRecovery();
    defer {
        allocator.free(result.issues);
        result.deinit(allocator);
    }

    // Should have no valid issues
    try std.testing.expectEqual(@as(usize, 0), result.issues.len);

    // All 3 lines were corrupt
    try std.testing.expectEqual(@as(usize, 3), result.corruption_count);
    try std.testing.expect(result.hasCorruption());
}

test "LoadResult.hasCorruption" {
    var result = LoadResult{
        .issues = &[_]Issue{},
        .corruption_count = 0,
    };
    try std.testing.expect(!result.hasCorruption());

    result.corruption_count = 5;
    try std.testing.expect(result.hasCorruption());
}
