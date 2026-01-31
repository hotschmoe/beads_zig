//! Config command for beads_zig.
//!
//! `bz config list` - List all configuration values
//! `bz config get <key>` - Get a configuration value
//! `bz config set <key> <value>` - Set a configuration value

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const CommandContext = common.CommandContext;
const ConfigArgs = args.ConfigArgs;
const ConfigSubcommand = args.ConfigSubcommand;

pub const ConfigError = error{
    WorkspaceNotInitialized,
    ConfigNotFound,
    InvalidKey,
    StorageError,
    OutOfMemory,
};

pub const ConfigResult = struct {
    success: bool,
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    entries: ?[]const ConfigEntry = null,
    message: ?[]const u8 = null,

    pub const ConfigEntry = struct {
        key: []const u8,
        value: []const u8,
        source: []const u8, // "default", "project", "user", "env", "cli"
    };
};

/// Known configuration keys and their defaults.
const ConfigKey = struct {
    key: []const u8,
    default: []const u8,
    description: []const u8,
};

const known_keys = [_]ConfigKey{
    .{ .key = "id.prefix", .default = "bd", .description = "Issue ID prefix" },
    .{ .key = "id.length", .default = "4", .description = "Minimum ID length (adaptive)" },
    .{ .key = "output.color", .default = "auto", .description = "Color output (auto, always, never)" },
    .{ .key = "output.format", .default = "plain", .description = "Default output format (plain, json, toon)" },
    .{ .key = "sync.auto_flush", .default = "true", .description = "Auto-flush WAL on write" },
    .{ .key = "sync.auto_import", .default = "true", .description = "Auto-import on read" },
    .{ .key = "lock.timeout_ms", .default = "5000", .description = "Lock acquisition timeout" },
};

pub fn run(
    config_args: ConfigArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (config_args.subcommand) {
        .list => try runList(global, allocator),
        .get => |get| try runGet(get.key, global, allocator),
        .set => |set| try runSet(set.key, set.value, global, allocator),
    }
}

fn runList(
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ConfigError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";

    // Build list of config entries with their current values
    var entries: std.ArrayListUnmanaged(ConfigResult.ConfigEntry) = .{};
    defer entries.deinit(allocator);

    for (known_keys) |key_info| {
        const value = try getConfigValue(allocator, beads_dir, key_info.key) orelse key_info.default;
        const source = if (value.ptr == key_info.default.ptr) "default" else "project";

        try entries.append(allocator, .{
            .key = key_info.key,
            .value = value,
            .source = source,
        });
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(ConfigResult{
            .success = true,
            .entries = entries.items,
        });
    } else if (!global.quiet) {
        try ctx.output.println("Configuration", .{});
        try ctx.output.print("\n", .{});

        for (known_keys) |key_info| {
            const value = try getConfigValue(allocator, beads_dir, key_info.key) orelse key_info.default;
            try ctx.output.print("{s} = {s}\n", .{ key_info.key, value });
        }
    }
}

fn runGet(
    key: []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ConfigError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";

    // Find default for this key
    var default_value: ?[]const u8 = null;
    for (known_keys) |key_info| {
        if (std.mem.eql(u8, key_info.key, key)) {
            default_value = key_info.default;
            break;
        }
    }

    const value = try getConfigValue(allocator, beads_dir, key) orelse
        default_value orelse {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(ConfigResult{
                .success = false,
                .key = key,
                .message = "Unknown configuration key",
            });
        } else {
            try ctx.output.err("Unknown configuration key: {s}", .{key});
        }
        return;
    };

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(ConfigResult{
            .success = true,
            .key = key,
            .value = value,
        });
    } else if (!global.quiet) {
        try ctx.output.print("{s}\n", .{value});
    }
}

fn runSet(
    key: []const u8,
    value: []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return ConfigError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const beads_dir = global.data_path orelse ".beads";

    // Validate that key is known
    var is_known = false;
    for (known_keys) |key_info| {
        if (std.mem.eql(u8, key_info.key, key)) {
            is_known = true;
            break;
        }
    }

    if (!is_known) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(ConfigResult{
                .success = false,
                .key = key,
                .message = "Unknown configuration key",
            });
        } else {
            try ctx.output.err("Unknown configuration key: {s}", .{key});
        }
        return;
    }

    // Write to project config
    try setConfigValue(allocator, beads_dir, key, value);

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(ConfigResult{
            .success = true,
            .key = key,
            .value = value,
            .message = "Configuration updated",
        });
    } else if (!global.quiet) {
        try ctx.output.print("Set {s} = {s}\n", .{ key, value });
    }
}

/// Read a config value from project config file.
/// Returns null if not set.
fn getConfigValue(
    allocator: std.mem.Allocator,
    beads_dir: []const u8,
    key: []const u8,
) !?[]const u8 {
    const config_path = try std.fs.path.join(allocator, &.{ beads_dir, "config" });
    defer allocator.free(config_path);

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Simple key=value format, one per line
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const line_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            if (std.mem.eql(u8, line_key, key)) {
                const line_value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
                return try allocator.dupe(u8, line_value);
            }
        }
    }

    return null;
}

/// Write a config value to project config file.
fn setConfigValue(
    allocator: std.mem.Allocator,
    beads_dir: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const config_path = try std.fs.path.join(allocator, &.{ beads_dir, "config" });
    defer allocator.free(config_path);

    // Read existing content
    var existing_content: []const u8 = "";
    const existing_file = std.fs.cwd().openFile(config_path, .{}) catch |err| blk: {
        if (err == error.FileNotFound) break :blk null;
        return err;
    };
    if (existing_file) |file| {
        defer file.close();
        existing_content = try file.readToEndAlloc(allocator, 1024 * 1024);
    }
    defer if (existing_content.len > 0) allocator.free(existing_content);

    // Build new content
    var new_content: std.ArrayListUnmanaged(u8) = .{};
    defer new_content.deinit(allocator);

    var found = false;
    var lines = std.mem.splitScalar(u8, existing_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len > 0 and trimmed[0] != '#') {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const line_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.mem.eql(u8, line_key, key)) {
                    try new_content.appendSlice(allocator, key);
                    try new_content.append(allocator, '=');
                    try new_content.appendSlice(allocator, value);
                    try new_content.append(allocator, '\n');
                    found = true;
                    continue;
                }
            }
        }

        if (line.len > 0 or lines.rest().len > 0) {
            try new_content.appendSlice(allocator, line);
            try new_content.append(allocator, '\n');
        }
    }

    // Add new key if not found
    if (!found) {
        try new_content.appendSlice(allocator, key);
        try new_content.append(allocator, '=');
        try new_content.appendSlice(allocator, value);
        try new_content.append(allocator, '\n');
    }

    // Write atomically
    const tmp_path = try std.fs.path.join(allocator, &.{ beads_dir, "config.tmp" });
    defer allocator.free(tmp_path);

    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    try tmp_file.writeAll(new_content.items);
    try tmp_file.sync();
    tmp_file.close();

    try std.fs.cwd().rename(tmp_path, config_path);
}

// --- Tests ---

test "ConfigError enum exists" {
    const err: ConfigError = ConfigError.WorkspaceNotInitialized;
    try std.testing.expect(err == ConfigError.WorkspaceNotInitialized);
}

test "ConfigResult struct works" {
    const result = ConfigResult{
        .success = true,
        .key = "id.prefix",
        .value = "bd",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("id.prefix", result.key.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };
    const config_args = ConfigArgs{ .subcommand = .list };

    const result = run(config_args, global, allocator);
    try std.testing.expectError(ConfigError.WorkspaceNotInitialized, result);
}

test "getConfigValue returns null for missing file" {
    const allocator = std.testing.allocator;
    const value = try getConfigValue(allocator, "/nonexistent/path", "id.prefix");
    try std.testing.expect(value == null);
}

test "setConfigValue and getConfigValue roundtrip" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "config_roundtrip");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    try setConfigValue(allocator, test_dir, "id.prefix", "test");

    const value = try getConfigValue(allocator, test_dir, "id.prefix");
    try std.testing.expect(value != null);
    defer allocator.free(value.?);
    try std.testing.expectEqualStrings("test", value.?);
}

test "setConfigValue updates existing key" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "config_update");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    try setConfigValue(allocator, test_dir, "id.prefix", "first");
    try setConfigValue(allocator, test_dir, "id.prefix", "second");

    const value = try getConfigValue(allocator, test_dir, "id.prefix");
    try std.testing.expect(value != null);
    defer allocator.free(value.?);
    try std.testing.expectEqualStrings("second", value.?);
}

test "known_keys has expected entries" {
    var found_prefix = false;
    var found_color = false;
    for (known_keys) |key_info| {
        if (std.mem.eql(u8, key_info.key, "id.prefix")) found_prefix = true;
        if (std.mem.eql(u8, key_info.key, "output.color")) found_color = true;
    }
    try std.testing.expect(found_prefix);
    try std.testing.expect(found_color);
}
