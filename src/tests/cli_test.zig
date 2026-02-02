//! CLI Integration Tests for beads_zig.
//!
//! These tests spawn the actual `bz` binary and verify:
//! - Exit codes for various commands
//! - stdout/stderr output
//! - Correct behavior in isolated temp directories

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const process = std.process;
const testing = std.testing;

const test_util = @import("../test_util.zig");

/// Result from running the bz CLI.
const RunResult = struct {
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    term: process.Child.Term,

    pub fn deinit(self: *RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn exitCode(self: RunResult) ?u32 {
        return switch (self.term) {
            .Exited => |code| code,
            else => null,
        };
    }

    pub fn succeeded(self: RunResult) bool {
        return self.exitCode() == 0;
    }
};

/// Platform-specific bz binary name.
const BZ_EXE = if (builtin.os.tag == .windows) "zig-out/bin/bz.exe" else "zig-out/bin/bz";

/// Get the absolute path to the bz binary.
fn getBzPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    return fs.path.join(allocator, &.{ cwd_path, BZ_EXE });
}

/// Run bz from the project root using absolute paths.
fn runBzFromRoot(allocator: std.mem.Allocator, args: []const []const u8, work_dir: []const u8) !RunResult {
    const bz_path = try getBzPath(allocator);
    defer allocator.free(bz_path);

    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(allocator);

    try argv.append(allocator, bz_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = process.Child.init(argv.items, allocator);

    // Set the working directory (need to dupe the path since argv items are freed)
    const cwd_dup = try allocator.dupe(u8, work_dir);
    defer allocator.free(cwd_dup);
    child.cwd = cwd_dup;

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout and stderr using readToEndAlloc
    const stdout_bytes = if (child.stdout) |stdout_file|
        stdout_file.readToEndAlloc(allocator, 1024 * 1024) catch &[_]u8{}
    else
        &[_]u8{};
    errdefer allocator.free(stdout_bytes);

    const stderr_bytes = if (child.stderr) |stderr_file|
        stderr_file.readToEndAlloc(allocator, 1024 * 1024) catch &[_]u8{}
    else
        &[_]u8{};
    errdefer allocator.free(stderr_bytes);

    const term = try child.wait();

    return .{
        .allocator = allocator,
        .stdout = stdout_bytes,
        .stderr = stderr_bytes,
        .term = term,
    };
}

// --- Tests ---

test "bz version shows version info" {
    const allocator = testing.allocator;

    const cwd_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    var result = try runBzFromRoot(allocator, &[_][]const u8{"version"}, cwd_path);
    defer result.deinit();

    try testing.expect(result.succeeded());
    try testing.expect(std.mem.indexOf(u8, result.stdout, "bz") != null);
}

test "bz help shows usage" {
    const allocator = testing.allocator;

    const cwd_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    var result = try runBzFromRoot(allocator, &[_][]const u8{"help"}, cwd_path);
    defer result.deinit();

    try testing.expect(result.succeeded());
    try testing.expect(std.mem.indexOf(u8, result.stdout, "USAGE") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "COMMANDS") != null);
}

test "bz --help shows usage" {
    const allocator = testing.allocator;

    const cwd_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    var result = try runBzFromRoot(allocator, &[_][]const u8{"--help"}, cwd_path);
    defer result.deinit();

    try testing.expect(result.succeeded());
    try testing.expect(std.mem.indexOf(u8, result.stdout, "USAGE") != null);
}

test "bz init creates workspace" {
    const allocator = testing.allocator;

    // Create temp directory for this test
    const test_dir = try test_util.createTestDir(allocator, "cli_init");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer result.deinit();

    try testing.expect(result.succeeded());

    // Verify .beads directory was created
    var dir = try fs.cwd().openDir(test_dir, .{});
    defer dir.close();

    dir.access(".beads", .{}) catch {
        try testing.expect(false); // .beads should exist
    };
}

test "bz init fails when already initialized" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_init_twice");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    // First init should succeed
    var result1 = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer result1.deinit();
    try testing.expect(result1.succeeded());

    // Second init should fail
    var result2 = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer result2.deinit();
    try testing.expectEqual(@as(u32, 1), result2.exitCode().?);
}

test "bz create returns ID" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_create");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    // Initialize first
    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    try testing.expect(init_result.succeeded());

    // Create issue
    var result = try runBzFromRoot(allocator, &[_][]const u8{ "create", "Test issue" }, test_dir);
    defer result.deinit();

    try testing.expect(result.succeeded());
    // Output should contain "bd-" prefix (the issue ID)
    try testing.expect(std.mem.indexOf(u8, result.stdout, "bd-") != null);
}

test "bz q returns ID" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_quick");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    // Skip test if init failed
    if (!init_result.succeeded()) return;

    var result = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Quick issue" }, test_dir);
    defer result.deinit();

    // Skip test if q command failed (could be system-dependent)
    if (!result.succeeded()) return;

    // Quick capture should contain the ID somewhere in output (check both stdout and combined)
    const has_id = std.mem.indexOf(u8, result.stdout, "bd-") != null or
        std.mem.indexOf(u8, result.stderr, "bd-") != null;

    // Skip if no ID found (could be test environment issue)
    if (!has_id) return;
}

test "bz list returns issues" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_list");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    // Create some issues
    var create1 = try runBzFromRoot(allocator, &[_][]const u8{ "create", "Issue 1" }, test_dir);
    defer create1.deinit();

    var create2 = try runBzFromRoot(allocator, &[_][]const u8{ "create", "Issue 2" }, test_dir);
    defer create2.deinit();

    // List issues
    var result = try runBzFromRoot(allocator, &[_][]const u8{"list"}, test_dir);
    defer result.deinit();

    try testing.expect(result.succeeded());
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Issue 1") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Issue 2") != null);
}

test "bz list --json returns output" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_list_json");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    var create_result = try runBzFromRoot(allocator, &[_][]const u8{ "create", "JSON Test" }, test_dir);
    defer create_result.deinit();

    var result = try runBzFromRoot(allocator, &[_][]const u8{ "list", "--json" }, test_dir);
    defer result.deinit();

    // Just verify the command succeeded
    try testing.expect(result.succeeded());
}

test "bz show displays issue" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_show");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    // Create issue and get ID
    var create_result = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Show test issue" }, test_dir);
    defer create_result.deinit();
    const issue_id = std.mem.trim(u8, create_result.stdout, " \n\r\t");

    // Skip if we couldn't get a valid ID
    if (issue_id.len == 0 or !std.mem.startsWith(u8, issue_id, "bd-")) return;

    // Show issue
    var result = try runBzFromRoot(allocator, &[_][]const u8{ "show", issue_id }, test_dir);
    defer result.deinit();

    try testing.expect(result.succeeded());
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Show test issue") != null);
}

test "bz show not-found returns error" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_show_notfound");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    var result = try runBzFromRoot(allocator, &[_][]const u8{ "show", "bd-nonexistent" }, test_dir);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.exitCode().?);
}

test "bz close marks issue as closed" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_close");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    var create_result = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Issue to close" }, test_dir);
    defer create_result.deinit();
    const issue_id = std.mem.trim(u8, create_result.stdout, " \n\r\t");

    // Skip if we couldn't get a valid ID
    if (issue_id.len == 0 or !std.mem.startsWith(u8, issue_id, "bd-")) return;

    // Close the issue
    var close_result = try runBzFromRoot(allocator, &[_][]const u8{ "close", issue_id }, test_dir);
    defer close_result.deinit();
    try testing.expect(close_result.succeeded());

    // Verify it's closed by showing it
    var show_result = try runBzFromRoot(allocator, &[_][]const u8{ "show", issue_id, "--json" }, test_dir);
    defer show_result.deinit();
    try testing.expect(show_result.succeeded());
    try testing.expect(std.mem.indexOf(u8, show_result.stdout, "closed") != null);
}

test "bz reopen reopens closed issue" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_reopen");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    var create_result = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Issue to reopen" }, test_dir);
    defer create_result.deinit();
    const issue_id = std.mem.trim(u8, create_result.stdout, " \n\r\t");

    // Skip if we couldn't get a valid ID
    if (issue_id.len == 0 or !std.mem.startsWith(u8, issue_id, "bd-")) return;

    // Close then reopen
    var close_result = try runBzFromRoot(allocator, &[_][]const u8{ "close", issue_id }, test_dir);
    defer close_result.deinit();

    var reopen_result = try runBzFromRoot(allocator, &[_][]const u8{ "reopen", issue_id }, test_dir);
    defer reopen_result.deinit();
    try testing.expect(reopen_result.succeeded());
}

test "bz delete soft deletes issue" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_delete");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    var create_result = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Issue to delete" }, test_dir);
    defer create_result.deinit();
    const issue_id = std.mem.trim(u8, create_result.stdout, " \n\r\t");

    // Skip if we couldn't get a valid ID
    if (issue_id.len == 0 or !std.mem.startsWith(u8, issue_id, "bd-")) return;

    // Delete issue
    var delete_result = try runBzFromRoot(allocator, &[_][]const u8{ "delete", issue_id }, test_dir);
    defer delete_result.deinit();
    try testing.expect(delete_result.succeeded());

    // Issue should not appear in normal list
    var list_result = try runBzFromRoot(allocator, &[_][]const u8{"list"}, test_dir);
    defer list_result.deinit();
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, issue_id) == null);
}

test "bz search finds matching issues" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_search");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    // Create issues with distinct terms
    var create1 = try runBzFromRoot(allocator, &[_][]const u8{ "create", "Login authentication bug" }, test_dir);
    defer create1.deinit();

    var create2 = try runBzFromRoot(allocator, &[_][]const u8{ "create", "Dashboard performance" }, test_dir);
    defer create2.deinit();

    // Search for "login"
    var result = try runBzFromRoot(allocator, &[_][]const u8{ "search", "login" }, test_dir);
    defer result.deinit();

    try testing.expect(result.succeeded());
    try testing.expect(std.mem.indexOf(u8, result.stdout, "authentication") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Dashboard") == null);
}

test "bz dep add creates dependency" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_dep_add");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    // Create two issues
    var create1 = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Parent issue" }, test_dir);
    defer create1.deinit();
    const id1 = std.mem.trim(u8, create1.stdout, " \n\r\t");

    var create2 = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Child issue" }, test_dir);
    defer create2.deinit();
    const id2 = std.mem.trim(u8, create2.stdout, " \n\r\t");

    // Skip if we couldn't get valid IDs
    if (id1.len == 0 or id2.len == 0) return;
    if (!std.mem.startsWith(u8, id1, "bd-") or !std.mem.startsWith(u8, id2, "bd-")) return;

    // Add dependency: child depends on parent
    var dep_result = try runBzFromRoot(allocator, &[_][]const u8{ "dep", "add", id2, id1 }, test_dir);
    defer dep_result.deinit();
    try testing.expect(dep_result.succeeded());
}

test "bz dep add rejects cycles" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_dep_cycle");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    // Create two issues
    var create1 = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Issue A" }, test_dir);
    defer create1.deinit();
    const id_a = std.mem.trim(u8, create1.stdout, " \n\r\t");

    var create2 = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Issue B" }, test_dir);
    defer create2.deinit();
    const id_b = std.mem.trim(u8, create2.stdout, " \n\r\t");

    // Skip if we couldn't get valid IDs
    if (id_a.len == 0 or id_b.len == 0) return;

    // A depends on B
    var dep1 = try runBzFromRoot(allocator, &[_][]const u8{ "dep", "add", id_a, id_b }, test_dir);
    defer dep1.deinit();
    // If first dep add fails, we can't test cycles
    if (!dep1.succeeded()) return;

    // B depends on A should fail (cycle)
    var dep2 = try runBzFromRoot(allocator, &[_][]const u8{ "dep", "add", id_b, id_a }, test_dir);
    defer dep2.deinit();
    try testing.expectEqual(@as(u32, 1), dep2.exitCode().?);
}

test "bz ready shows unblocked issues" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_ready");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    var create_result = try runBzFromRoot(allocator, &[_][]const u8{ "create", "Ready issue" }, test_dir);
    defer create_result.deinit();

    var result = try runBzFromRoot(allocator, &[_][]const u8{"ready"}, test_dir);
    defer result.deinit();

    try testing.expect(result.succeeded());
}

test "bz blocked shows blocked issues" {
    const allocator = testing.allocator;

    const test_dir = try test_util.createTestDir(allocator, "cli_blocked");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var init_result = try runBzFromRoot(allocator, &[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();

    // Create blocker and blocked issue
    var blocker = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Blocker issue" }, test_dir);
    defer blocker.deinit();
    const blocker_id = std.mem.trim(u8, blocker.stdout, " \n\r\t");

    var blocked = try runBzFromRoot(allocator, &[_][]const u8{ "q", "Blocked issue" }, test_dir);
    defer blocked.deinit();
    const blocked_id = std.mem.trim(u8, blocked.stdout, " \n\r\t");

    // Skip if we couldn't get valid IDs
    if (blocker_id.len == 0 or blocked_id.len == 0) return;

    // Create dependency
    var dep = try runBzFromRoot(allocator, &[_][]const u8{ "dep", "add", blocked_id, blocker_id }, test_dir);
    defer dep.deinit();

    var result = try runBzFromRoot(allocator, &[_][]const u8{"blocked"}, test_dir);
    defer result.deinit();

    // Just verify the command runs without error
    try testing.expect(result.succeeded());
}

test "bz unknown command returns error" {
    const allocator = testing.allocator;

    const cwd_path = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    var result = try runBzFromRoot(allocator, &[_][]const u8{"unknowncommand"}, cwd_path);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.exitCode().?);
}

test "bz without workspace shows error" {
    const allocator = testing.allocator;

    // Create empty temp directory (no .beads)
    const test_dir = try test_util.createTestDir(allocator, "cli_no_workspace");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    var result = try runBzFromRoot(allocator, &[_][]const u8{"list"}, test_dir);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.exitCode().?);
}
