//! Init command for beads_zig.
//!
//! Creates the .beads/ workspace directory with:
//! - issues.jsonl (empty, git-tracked)
//! - config.yaml (git-tracked)
//! - metadata.json (gitignored)
//! - .gitignore (to ignore WAL, lock, and metadata files)

const std = @import("std");
const Output = @import("../output/mod.zig").Output;
const OutputOptions = @import("../output/mod.zig").OutputOptions;
const args = @import("args.zig");
const test_util = @import("../test_util.zig");
const storage = @import("../storage/mod.zig");

pub const InitError = error{
    AlreadyInitialized,
    CreateDirectoryFailed,
    WriteFileFailed,
    OutOfMemory,
};

pub const InitResult = struct {
    success: bool,
    path: []const u8,
    prefix: []const u8,
    message: ?[]const u8 = null,
    fs_warning: ?[]const u8 = null,
};

/// Run the init command.
pub fn run(
    init_args: args.InitArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var output = Output.init(allocator, OutputOptions{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    const structured_output = global.isStructuredOutput();
    const beads_dir = global.data_path orelse ".beads";
    const issues_file = "issues.jsonl";

    const issues_path = try std.fs.path.join(allocator, &.{ beads_dir, issues_file });
    defer allocator.free(issues_path);

    // Check if already initialized by looking for issues.jsonl
    const already_exists = blk: {
        std.fs.cwd().access(issues_path, .{}) catch |err| {
            break :blk err != error.FileNotFound;
        };
        break :blk true;
    };

    if (already_exists) {
        try outputError(&output, structured_output, beads_dir, init_args.prefix, "workspace already initialized");
        return InitError.AlreadyInitialized;
    }

    // Create .beads directory
    std.fs.cwd().makeDir(beads_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            try outputError(&output, structured_output, beads_dir, init_args.prefix, "failed to create directory");
            return InitError.CreateDirectoryFailed;
        },
    };

    // Create empty issues.jsonl (reuse the path we already constructed)
    const jsonl_file = std.fs.cwd().createFile(issues_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => {
            try outputError(&output, structured_output, beads_dir, init_args.prefix, "failed to create issues.jsonl");
            return InitError.WriteFileFailed;
        },
    };
    if (jsonl_file) |f| f.close();

    // Create config.yaml
    const config_path = try std.fs.path.join(allocator, &.{ beads_dir, "config.yaml" });
    defer allocator.free(config_path);

    try writeConfigYaml(config_path, init_args.prefix);

    // Create metadata.json
    const metadata_path = try std.fs.path.join(allocator, &.{ beads_dir, "metadata.json" });
    defer allocator.free(metadata_path);

    try writeMetadataJson(metadata_path, allocator);

    // Create .gitignore
    const gitignore_path = try std.fs.path.join(allocator, &.{ beads_dir, ".gitignore" });
    defer allocator.free(gitignore_path);

    try writeGitignore(gitignore_path);

    // Check filesystem safety for concurrent access
    const fs_check = storage.checkFilesystemSafety(beads_dir);
    const fs_warning: ?[]const u8 = if (!fs_check.safe) fs_check.warning else null;

    // Success output
    if (structured_output) {
        try output.printJson(InitResult{
            .success = true,
            .path = beads_dir,
            .prefix = init_args.prefix,
            .fs_warning = fs_warning,
        });
    } else {
        try output.success("Initialized beads workspace in {s}/", .{beads_dir});
        try output.print("  Issue prefix: {s}\n", .{init_args.prefix});
        try output.print("  Issues file: {s}/issues.jsonl\n", .{beads_dir});

        // Warn user about network filesystem if detected
        if (fs_warning) |warning| {
            try output.print("\n", .{});
            try output.warn("Filesystem warning: {s}", .{warning});
        }
    }
}

fn outputError(
    output: *Output,
    json_mode: bool,
    path: []const u8,
    prefix: []const u8,
    message: []const u8,
) !void {
    if (json_mode) {
        try output.printJson(InitResult{
            .success = false,
            .path = path,
            .prefix = prefix,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
}

fn writeConfigYaml(path: []const u8, prefix: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const config_template =
        \\# beads_zig configuration
        \\id:
        \\  prefix: "{s}"
        \\  min_hash_length: 3
        \\  max_hash_length: 8
        \\
        \\defaults:
        \\  priority: 2
        \\  issue_type: "task"
        \\
        \\sync:
        \\  auto_flush: true
        \\  auto_import: true
        \\
        \\output:
        \\  color: true
        \\
    ;

    var buf: [512]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf, config_template, .{prefix});
    try file.writeAll(content);
}

fn writeMetadataJson(path: []const u8, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const now = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var ts_buf: [25]u8 = undefined;
    const timestamp_str = try std.fmt.bufPrint(&ts_buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @as(u32, month_day.month.numeric()),
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });

    const metadata_template =
        \\{{
        \\  "schema_version": 1,
        \\  "created_at": "{s}",
        \\  "issue_count": 0
        \\}}
        \\
    ;

    const content = try std.fmt.allocPrint(allocator, metadata_template, .{timestamp_str});
    defer allocator.free(content);

    try file.writeAll(content);
}

fn writeGitignore(path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const gitignore_content =
        \\# beads_zig generated files (not tracked in git)
        \\*.wal
        \\*.lock
        \\metadata.json
        \\
    ;

    try file.writeAll(gitignore_content);
}

// --- Tests ---

test "init creates workspace directory structure" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "init_structure");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    const init_args = args.InitArgs{ .prefix = "test" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    run(init_args, global, allocator) catch |err| {
        std.debug.print("Init failed: {}\n", .{err});
        return err;
    };

    // Verify files exist
    var tmp_dir = try std.fs.cwd().openDir(tmp_dir_path, .{});
    defer tmp_dir.close();

    try tmp_dir.access(".beads/issues.jsonl", .{});
    try tmp_dir.access(".beads/config.yaml", .{});
    try tmp_dir.access(".beads/metadata.json", .{});
    try tmp_dir.access(".beads/.gitignore", .{});
}

test "init fails if already initialized" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "init_already");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    const init_args = args.InitArgs{ .prefix = "bd" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    // First init should succeed
    try run(init_args, global, allocator);

    // Second init should fail
    const result = run(init_args, global, allocator);
    try std.testing.expectError(InitError.AlreadyInitialized, result);
}

test "init respects custom prefix" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "init_prefix");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    const init_args = args.InitArgs{ .prefix = "proj" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(init_args, global, allocator);

    // Read config.yaml and verify prefix
    const config_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads", "config.yaml" });
    defer allocator.free(config_path);

    const config_file = try std.fs.cwd().openFile(config_path, .{});
    defer config_file.close();

    const content = try config_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "prefix: \"proj\"") != null);
}

test "init creates valid metadata.json" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "init_metadata");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    const init_args = args.InitArgs{ .prefix = "bd" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(init_args, global, allocator);

    // Read and parse metadata.json
    const metadata_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads", "metadata.json" });
    defer allocator.free(metadata_path);

    const metadata_file = try std.fs.cwd().openFile(metadata_path, .{});
    defer metadata_file.close();

    const content = try metadata_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    // Verify it's valid JSON with expected fields
    const parsed = try std.json.parseFromSlice(struct {
        schema_version: i32,
        created_at: []const u8,
        issue_count: i32,
    }, allocator, content, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i32, 1), parsed.value.schema_version);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.issue_count);
}

test "init creates .gitignore with correct entries" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "init_gitignore");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    const init_args = args.InitArgs{ .prefix = "bd" };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(init_args, global, allocator);

    // Read .gitignore
    const gitignore_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads", ".gitignore" });
    defer allocator.free(gitignore_path);

    const gitignore_file = try std.fs.cwd().openFile(gitignore_path, .{});
    defer gitignore_file.close();

    const content = try gitignore_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    // Verify expected patterns
    try std.testing.expect(std.mem.indexOf(u8, content, "*.wal") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "*.lock") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "metadata.json") != null);
}
