//! Info command for beads_zig.
//!
//! `bz info` - Show workspace information

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");

const CommandContext = common.CommandContext;

pub const InfoError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

pub const InfoResult = struct {
    database_path: []const u8,
    beads_dir: []const u8,
    mode: []const u8 = "direct",
    daemon_connected: bool = false,
    daemon_fallback_reason: []const u8 = "no-daemon",
    daemon_detail: []const u8 = "bz runs in direct mode only",
    issue_count: usize,
    db_size: u64,
    jsonl_path: ?[]const u8 = null,
    jsonl_size: ?u64 = null,
};

pub fn run(
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return InfoError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";
    const db_size = getFileSize(ctx.db_path);

    const issue_count = try ctx.issue_store.countTotal();

    // Resolve paths to absolute for display (matching br behavior)
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_db_path = std.fs.cwd().realpath(ctx.db_path, &real_path_buf) catch ctx.db_path;

    var real_beads_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_beads_dir = std.fs.cwd().realpath(beads_dir, &real_beads_buf) catch beads_dir;

    // Check for JSONL file
    const jsonl_path = try std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" });
    defer allocator.free(jsonl_path);
    var real_jsonl_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_jsonl_path = std.fs.cwd().realpath(jsonl_path, &real_jsonl_buf) catch null;
    const jsonl_size: ?u64 = if (abs_jsonl_path != null) getFileSize(jsonl_path) else null;

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(InfoResult{
            .database_path = abs_db_path,
            .beads_dir = abs_beads_dir,
            .issue_count = issue_count,
            .db_size = db_size,
            .jsonl_path = abs_jsonl_path,
            .jsonl_size = jsonl_size,
        });
    } else if (!global.quiet) {
        try ctx.output.println("Beads Database Information", .{});
        try ctx.output.print("Database: {s}\n", .{abs_db_path});
        try ctx.output.print("Mode: direct\n", .{});
        try ctx.output.print("Daemon: not connected (no-daemon)\n", .{});
        try ctx.output.print("  bz runs in direct mode only\n", .{});
        try ctx.output.print("Issue count: {d}\n", .{issue_count});
    }
}

fn getFileSize(path: []const u8) u64 {
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.size;
}

// --- Tests ---

test "InfoError enum exists" {
    const err: InfoError = InfoError.WorkspaceNotInitialized;
    try std.testing.expect(err == InfoError.WorkspaceNotInitialized);
}

test "InfoResult struct works" {
    const result = InfoResult{
        .database_path = "/tmp/.beads/beads.db",
        .beads_dir = "/tmp/.beads",
        .issue_count = 5,
        .db_size = 4096,
    };
    try std.testing.expectEqualStrings("/tmp/.beads", result.beads_dir);
    try std.testing.expectEqual(@as(usize, 5), result.issue_count);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(global, allocator);
    try std.testing.expectError(InfoError.WorkspaceNotInitialized, result);
}

test "getFileSize returns 0 for missing file" {
    const size = getFileSize("/nonexistent/file.txt");
    try std.testing.expectEqual(@as(u64, 0), size);
}
