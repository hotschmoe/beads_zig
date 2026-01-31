//! Label commands for beads_zig.
//!
//! `bz label add <id> <labels...>` - Add labels to an issue
//! `bz label remove <id> <labels...>` - Remove labels from an issue
//! `bz label list <id>` - List labels on an issue
//! `bz label list-all` - List all labels in the project

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");

const CommandContext = common.CommandContext;

pub const LabelError = error{
    WorkspaceNotInitialized,
    StorageError,
    IssueNotFound,
    OutOfMemory,
};

pub const LabelResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    labels: ?[]const []const u8 = null,
    added: ?[]const []const u8 = null,
    removed: ?[]const []const u8 = null,
    message: ?[]const u8 = null,
};

pub fn run(
    label_args: args.LabelArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (label_args.subcommand) {
        .add => |add| try runAdd(add.id, add.labels, global, allocator),
        .remove => |remove| try runRemove(remove.id, remove.labels, global, allocator),
        .list => |list| try runList(list.id, global, allocator),
        .list_all => try runListAll(global, allocator),
    }
}

fn runAdd(
    id: []const u8,
    labels: []const []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return LabelError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Verify issue exists
    if (!try ctx.store.exists(id)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(LabelResult{
                .success = false,
                .id = id,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{id});
        }
        return LabelError.IssueNotFound;
    }

    var added_labels: std.ArrayListUnmanaged([]const u8) = .{};
    defer added_labels.deinit(allocator);

    for (labels) |label| {
        // Check if already has label
        const existing = try ctx.store.getLabels(id);
        defer {
            for (existing) |lbl| {
                allocator.free(lbl);
            }
            allocator.free(existing);
        }

        var has_label = false;
        for (existing) |existing_label| {
            if (std.mem.eql(u8, existing_label, label)) {
                has_label = true;
                break;
            }
        }

        if (!has_label) {
            try ctx.store.addLabel(id, label);
            try added_labels.append(allocator, label);
        }
    }

    try ctx.saveIfAutoFlush();

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(LabelResult{
            .success = true,
            .id = id,
            .added = added_labels.items,
        });
    } else if (global.quiet) {
        for (added_labels.items) |label| {
            try ctx.output.print("{s}\n", .{label});
        }
    } else {
        if (added_labels.items.len > 0) {
            try ctx.output.success("Added {d} label(s) to {s}", .{ added_labels.items.len, id });
        } else {
            try ctx.output.info("No new labels added (already present)", .{});
        }
    }
}

fn runRemove(
    id: []const u8,
    labels: []const []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return LabelError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Verify issue exists
    if (!try ctx.store.exists(id)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(LabelResult{
                .success = false,
                .id = id,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{id});
        }
        return LabelError.IssueNotFound;
    }

    var removed_labels: std.ArrayListUnmanaged([]const u8) = .{};
    defer removed_labels.deinit(allocator);

    for (labels) |label| {
        // Check if has label
        const existing = try ctx.store.getLabels(id);
        defer {
            for (existing) |lbl| {
                allocator.free(lbl);
            }
            allocator.free(existing);
        }

        var has_label = false;
        for (existing) |existing_label| {
            if (std.mem.eql(u8, existing_label, label)) {
                has_label = true;
                break;
            }
        }

        if (has_label) {
            try ctx.store.removeLabel(id, label);
            try removed_labels.append(allocator, label);
        }
    }

    try ctx.saveIfAutoFlush();

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(LabelResult{
            .success = true,
            .id = id,
            .removed = removed_labels.items,
        });
    } else if (global.quiet) {
        for (removed_labels.items) |label| {
            try ctx.output.print("{s}\n", .{label});
        }
    } else {
        if (removed_labels.items.len > 0) {
            try ctx.output.success("Removed {d} label(s) from {s}", .{ removed_labels.items.len, id });
        } else {
            try ctx.output.info("No labels removed (not present)", .{});
        }
    }
}

fn runList(
    id: []const u8,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return LabelError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Verify issue exists
    if (!try ctx.store.exists(id)) {
        if (global.isStructuredOutput()) {
            try ctx.output.printJson(LabelResult{
                .success = false,
                .id = id,
                .message = "issue not found",
            });
        } else {
            try ctx.output.err("issue not found: {s}", .{id});
        }
        return LabelError.IssueNotFound;
    }

    const label_list = try ctx.store.getLabels(id);
    defer {
        for (label_list) |lbl| {
            allocator.free(lbl);
        }
        allocator.free(label_list);
    }

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(LabelResult{
            .success = true,
            .id = id,
            .labels = label_list,
        });
    } else if (global.quiet) {
        for (label_list) |label| {
            try ctx.output.print("{s}\n", .{label});
        }
    } else {
        if (label_list.len == 0) {
            try ctx.output.info("No labels on {s}", .{id});
        } else {
            try ctx.output.println("Labels on {s} ({d}):", .{ id, label_list.len });
            for (label_list) |label| {
                try ctx.output.print("  {s}\n", .{label});
            }
        }
    }
}

fn runListAll(
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return LabelError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    // Collect all unique labels across all issues
    var all_labels: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var key_it = all_labels.keyIterator();
        while (key_it.next()) |key| {
            allocator.free(key.*);
        }
        all_labels.deinit(allocator);
    }

    for (ctx.store.issues.items) |issue| {
        if (issue.status.eql(.tombstone)) continue;

        for (issue.labels) |label| {
            if (!all_labels.contains(label)) {
                const label_copy = try allocator.dupe(u8, label);
                try all_labels.put(allocator, label_copy, {});
            }
        }
    }

    // Convert to sorted slice
    var label_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer label_list.deinit(allocator);

    var key_it = all_labels.keyIterator();
    while (key_it.next()) |key| {
        try label_list.append(allocator, key.*);
    }

    // Sort alphabetically
    std.mem.sortUnstable([]const u8, label_list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    if (global.isStructuredOutput()) {
        try ctx.output.printJson(LabelResult{
            .success = true,
            .labels = label_list.items,
        });
    } else if (global.quiet) {
        for (label_list.items) |label| {
            try ctx.output.print("{s}\n", .{label});
        }
    } else {
        if (label_list.items.len == 0) {
            try ctx.output.info("No labels in project", .{});
        } else {
            try ctx.output.println("Labels ({d}):", .{label_list.items.len});
            for (label_list.items) |label| {
                try ctx.output.print("  {s}\n", .{label});
            }
        }
    }
}

// --- Tests ---

test "LabelError enum exists" {
    const err: LabelError = LabelError.WorkspaceNotInitialized;
    try std.testing.expect(err == LabelError.WorkspaceNotInitialized);
}

test "LabelResult struct works" {
    const result = LabelResult{
        .success = true,
        .id = "bd-test",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-test", result.id.?);
}

test "runAdd detects uninitialized workspace" {
    const allocator = std.testing.allocator;
    const labels = [_][]const u8{"test"};

    const label_args = args.LabelArgs{
        .subcommand = .{ .add = .{ .id = "bd-test", .labels = &labels } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(label_args, global, allocator);
    try std.testing.expectError(LabelError.WorkspaceNotInitialized, result);
}

test "runList detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const label_args = args.LabelArgs{
        .subcommand = .{ .list = .{ .id = "bd-test" } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(label_args, global, allocator);
    try std.testing.expectError(LabelError.WorkspaceNotInitialized, result);
}

test "runListAll detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const label_args = args.LabelArgs{
        .subcommand = .{ .list_all = {} },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(label_args, global, allocator);
    try std.testing.expectError(LabelError.WorkspaceNotInitialized, result);
}
