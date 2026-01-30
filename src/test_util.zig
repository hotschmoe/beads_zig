//! Test utilities for beads_zig.
//!
//! Provides cross-platform temporary directory support for tests.

const std = @import("std");

/// Create a unique test directory under .test_tmp/ in the repo root.
/// Returns an owned path that must be freed by the caller.
/// The directory is created and ready for use.
pub fn createTestDir(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const timestamp = std.time.milliTimestamp();
    const path = try std.fmt.allocPrint(allocator, ".test_tmp/{s}_{d}", .{ prefix, timestamp });

    // Ensure .test_tmp exists
    std.fs.cwd().makeDir(".test_tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create the test-specific subdirectory
    std.fs.cwd().makeDir(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    return path;
}

/// Clean up a test directory created by createTestDir.
pub fn cleanupTestDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

test "createTestDir creates directory" {
    const allocator = std.testing.allocator;
    const path = try createTestDir(allocator, "test_util_test");
    defer allocator.free(path);
    defer cleanupTestDir(path);

    // Verify directory exists
    var dir = try std.fs.cwd().openDir(path, .{});
    dir.close();
}
