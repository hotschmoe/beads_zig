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
    success: bool,
    beads_dir: ?[]const u8 = null,
    jsonl_path: ?[]const u8 = null,
    issue_count: ?usize = null,
    jsonl_size: ?u64 = null,
    wal_size: ?u64 = null,
    message: ?[]const u8 = null,
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
    const jsonl_size = getFileSize(ctx.issues_path);

    const wal_path = try std.fs.path.join(allocator, &.{ beads_dir, "beads.wal" });
    defer allocator.free(wal_path);
    const wal_size = getFileSize(wal_path);

    const issue_count = ctx.store.countTotal();

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(InfoResult{
            .success = true,
            .beads_dir = beads_dir,
            .jsonl_path = ctx.issues_path,
            .issue_count = issue_count,
            .jsonl_size = jsonl_size,
            .wal_size = wal_size,
        });
    } else if (!global.quiet) {
        try ctx.output.println("beads_zig workspace", .{});
        try ctx.output.print("\n", .{});
        try ctx.output.print("Directory:     {s}\n", .{beads_dir});
        try ctx.output.print("JSONL:         {s} ({s})\n", .{ ctx.issues_path, formatBytes(jsonl_size) });
        try ctx.output.print("WAL:           {s} ({s})\n", .{ wal_path, formatBytes(wal_size) });
        try ctx.output.print("Total issues:  {d}\n", .{issue_count});
    }
}

fn getFileSize(path: []const u8) u64 {
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.size;
}

fn formatBytes(bytes: u64) []const u8 {
    if (bytes == 0) return "0 B";
    if (bytes < 1024) return "<1 KB";
    if (bytes < 1024 * 1024) return "<1 MB";
    return ">1 MB";
}

// --- Tests ---

test "InfoError enum exists" {
    const err: InfoError = InfoError.WorkspaceNotInitialized;
    try std.testing.expect(err == InfoError.WorkspaceNotInitialized);
}

test "InfoResult struct works" {
    const result = InfoResult{
        .success = true,
        .beads_dir = ".beads",
        .issue_count = 5,
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(".beads", result.beads_dir.?);
    try std.testing.expectEqual(@as(usize, 5), result.issue_count.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(global, allocator);
    try std.testing.expectError(InfoError.WorkspaceNotInitialized, result);
}

test "formatBytes handles zero" {
    try std.testing.expectEqualStrings("0 B", formatBytes(0));
}

test "formatBytes handles small values" {
    try std.testing.expectEqualStrings("<1 KB", formatBytes(500));
}

test "getFileSize returns 0 for missing file" {
    const size = getFileSize("/nonexistent/file.txt");
    try std.testing.expectEqual(@as(u64, 0), size);
}
