//! Epic management commands for beads_zig.
//!
//! `bz epic create <title>` - Create a new epic (issue with type=epic)
//! `bz epic add <epic_id> <issue_id>` - Add an issue to an epic
//! `bz epic remove <epic_id> <issue_id>` - Remove an issue from an epic
//! `bz epic list <epic_id>` - List issues in an epic
//!
//! Epics are high-level issues that contain other issues. The relationship
//! is modeled using the parent_child dependency type.

const std = @import("std");
const models = @import("../models/mod.zig");
const storage = @import("../storage/mod.zig");
const common = @import("common.zig");
const args = @import("args.zig");
const test_util = @import("../test_util.zig");

const Issue = models.Issue;
const Priority = models.Priority;
const Dependency = models.Dependency;
const CommandContext = common.CommandContext;
const DependencyStore = common.DependencyStore;
const DependencyStoreError = storage.DependencyStoreError;

pub const EpicError = error{
    WorkspaceNotInitialized,
    EpicNotFound,
    IssueNotFound,
    NotAnEpic,
    StorageError,
    OutOfMemory,
    EmptyTitle,
    TitleTooLong,
    InvalidPriority,
};

pub const EpicResult = struct {
    success: bool,
    id: ?[]const u8 = null,
    epic_id: ?[]const u8 = null,
    issue_id: ?[]const u8 = null,
    action: ?[]const u8 = null,
    issues: ?[]const IssueInfo = null,
    message: ?[]const u8 = null,
    epics: ?[]const EpicStatusInfo = null,
    closed_count: ?usize = null,
};

const EpicStatusInfo = struct {
    id: []const u8,
    title: []const u8,
    total: usize,
    closed: usize,
    percent_complete: u8,
    eligible_for_close: bool,
};

const IssueInfo = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    priority: u8,
};

const ChildCounts = struct {
    total: usize,
    closed: usize,
};

fn countEpicChildren(
    ctx: *CommandContext,
    epic_id: []const u8,
    allocator: std.mem.Allocator,
) !ChildCounts {
    const children = try ctx.dep_store.getDependents(epic_id);
    defer ctx.dep_store.freeDependencies(children);

    var total: usize = 0;
    var closed: usize = 0;

    for (children) |dep| {
        if (dep.dep_type == .parent_child) {
            total += 1;
            const child = try ctx.issue_store.get(dep.issue_id);
            if (child) |c| {
                var child_issue = c;
                defer child_issue.deinit(allocator);
                if (child_issue.status == .closed or child_issue.status == .tombstone) {
                    closed += 1;
                }
            }
        }
    }

    return .{ .total = total, .closed = closed };
}

pub fn run(
    epic_args: args.EpicArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    switch (epic_args.subcommand) {
        .create => |create| try runCreate(create, global, allocator),
        .add => |add| try runAdd(add, global, allocator),
        .remove => |remove| try runRemove(remove, global, allocator),
        .list => |list| try runList(list, global, allocator),
        .status => try runStatus(global, allocator),
        .close_eligible => |ce| try runCloseEligible(ce, global, allocator),
    }
}

fn runCreate(
    create_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return EpicError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    if (create_args.title.len == 0) {
        try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, "title cannot be empty");
        return EpicError.EmptyTitle;
    }
    if (create_args.title.len > 500) {
        try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, "title exceeds 500 character limit");
        return EpicError.TitleTooLong;
    }

    const priority = if (create_args.priority) |p|
        Priority.fromString(p) catch {
            try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, "invalid priority value");
            return EpicError.InvalidPriority;
        }
    else
        Priority.MEDIUM;

    const actor = global.actor orelse common.getDefaultActor();
    const beads_dir = global.data_path orelse ".beads";
    const prefix = try common.getConfigPrefix(allocator, beads_dir);
    defer allocator.free(prefix);

    var generator = common.IdGenerator.init(prefix);
    const issue_id = try common.generateUniqueId(allocator, &generator, &ctx.issue_store);
    defer allocator.free(issue_id);

    const now = std.time.timestamp();
    var issue = Issue.init(issue_id, create_args.title, now);
    issue.description = create_args.description;
    issue.priority = priority;
    issue.issue_type = .epic;
    issue.created_by = actor;

    ctx.issue_store.insert(issue) catch {
        try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, "failed to create epic");
        return EpicError.StorageError;
    };

    if (structured_output) {
        try ctx.output.printJson(EpicResult{
            .success = true,
            .id = issue_id,
            .action = "created",
        });
    } else if (global.quiet) {
        try ctx.output.raw(issue_id);
        try ctx.output.raw("\n");
    } else {
        try ctx.output.success("Created epic {s}", .{issue_id});
    }
}

fn runAdd(
    add_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return EpicError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    const epic = try ctx.issue_store.get(add_args.epic_id);
    if (epic == null) {
        try common.outputNotFoundError(EpicResult, &ctx.output, structured_output, add_args.epic_id, allocator);
        return EpicError.EpicNotFound;
    }
    var e = epic.?;
    defer e.deinit(allocator);

    if (e.issue_type != .epic) {
        try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, "issue is not an epic");
        return EpicError.NotAnEpic;
    }

    if (!try ctx.issue_store.exists(add_args.issue_id)) {
        try common.outputNotFoundError(EpicResult, &ctx.output, structured_output, add_args.issue_id, allocator);
        return EpicError.IssueNotFound;
    }

    const now = std.time.timestamp();

    ctx.dep_store.add(add_args.issue_id, add_args.epic_id, .parent_child, global.actor, now) catch |err| {
        const msg = switch (err) {
            DependencyStoreError.SelfDependency => "cannot add epic to itself",
            DependencyStoreError.CycleDetected => "adding to epic would create a cycle",
            else => "failed to add issue to epic",
        };
        try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, msg);
        return EpicError.StorageError;
    };

    if (structured_output) {
        try ctx.output.printJson(EpicResult{
            .success = true,
            .epic_id = add_args.epic_id,
            .issue_id = add_args.issue_id,
            .action = "added",
        });
    } else if (!global.quiet) {
        try ctx.output.success("Added {s} to epic {s}", .{ add_args.issue_id, add_args.epic_id });
    }
}

fn runRemove(
    remove_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return EpicError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    ctx.dep_store.remove(remove_args.issue_id, remove_args.epic_id) catch {
        try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, "failed to remove issue from epic");
        return EpicError.StorageError;
    };

    if (structured_output) {
        try ctx.output.printJson(EpicResult{
            .success = true,
            .epic_id = remove_args.epic_id,
            .issue_id = remove_args.issue_id,
            .action = "removed",
        });
    } else if (!global.quiet) {
        try ctx.output.success("Removed {s} from epic {s}", .{ remove_args.issue_id, remove_args.epic_id });
    }
}

fn runList(
    list_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return EpicError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    const epic = try ctx.issue_store.get(list_args.epic_id);
    if (epic == null) {
        try common.outputNotFoundError(EpicResult, &ctx.output, structured_output, list_args.epic_id, allocator);
        return EpicError.EpicNotFound;
    }
    var e = epic.?;
    defer e.deinit(allocator);

    if (e.issue_type != .epic) {
        try common.outputErrorTyped(EpicResult, &ctx.output, structured_output, "issue is not an epic");
        return EpicError.NotAnEpic;
    }

    const dependents = try ctx.dep_store.getDependents(list_args.epic_id);
    defer ctx.dep_store.freeDependencies(dependents);

    var issue_infos: std.ArrayListUnmanaged(IssueInfo) = .{};
    defer {
        for (issue_infos.items) |info| {
            allocator.free(info.id);
            allocator.free(info.title);
            allocator.free(info.status);
        }
        issue_infos.deinit(allocator);
    }

    for (dependents) |dep| {
        if (dep.dep_type == .parent_child) {
            const child = try ctx.issue_store.get(dep.issue_id);
            if (child) |c| {
                var issue = c;
                defer issue.deinit(allocator);
                try issue_infos.append(allocator, .{
                    .id = try allocator.dupe(u8, issue.id),
                    .title = try allocator.dupe(u8, issue.title),
                    .status = try allocator.dupe(u8, issue.status.toString()),
                    .priority = issue.priority.value,
                });
            }
        }
    }

    if (structured_output) {
        try ctx.output.printJson(EpicResult{
            .success = true,
            .epic_id = list_args.epic_id,
            .issues = issue_infos.items,
        });
    } else {
        if (issue_infos.items.len == 0) {
            try ctx.output.println("Epic {s} has no issues", .{list_args.epic_id});
        } else {
            try ctx.output.println("Epic {s} ({s}):", .{ list_args.epic_id, e.title });
            try ctx.output.println("", .{});
            for (issue_infos.items) |info| {
                try ctx.output.print("  {s}  [{s}] P{d}  {s}\n", .{
                    info.id,
                    info.status,
                    info.priority,
                    info.title,
                });
            }
            try ctx.output.println("", .{});
            try ctx.output.println("Total: {d} issue(s)", .{issue_infos.items.len});
        }
    }
}

fn runStatus(
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return EpicError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();

    // Find all epics
    var epic_statuses: std.ArrayListUnmanaged(EpicStatusInfo) = .{};
    defer {
        for (epic_statuses.items) |info| {
            allocator.free(info.id);
            allocator.free(info.title);
        }
        epic_statuses.deinit(allocator);
    }

    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |issue| {
        if (issue.issue_type == .epic and issue.status != .tombstone) {
            const counts = try countEpicChildren(&ctx, issue.id, allocator);
            const percent: u8 = if (counts.total > 0) @intCast((counts.closed * 100) / counts.total) else 0;
            const eligible = counts.total > 0 and counts.closed == counts.total;

            try epic_statuses.append(allocator, .{
                .id = try allocator.dupe(u8, issue.id),
                .title = try allocator.dupe(u8, issue.title),
                .total = counts.total,
                .closed = counts.closed,
                .percent_complete = percent,
                .eligible_for_close = eligible,
            });
        }
    }

    if (structured_output) {
        try ctx.output.printJson(EpicResult{
            .success = true,
            .epics = epic_statuses.items,
        });
    } else {
        if (epic_statuses.items.len == 0) {
            try ctx.output.println("No epics found", .{});
        } else {
            for (epic_statuses.items) |info| {
                const suffix: []const u8 = if (info.eligible_for_close) " [eligible for close]" else "";
                try ctx.output.print("{s}: {d}/{d} complete ({d}%){s}\n", .{
                    info.id,
                    info.closed,
                    info.total,
                    info.percent_complete,
                    suffix,
                });
            }
        }
    }
}

fn runCloseEligible(
    ce_args: anytype,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var ctx = (try CommandContext.init(allocator, global)) orelse {
        return EpicError.WorkspaceNotInitialized;
    };
    defer ctx.deinit();

    const structured_output = global.isStructuredOutput();
    const dry_run = ce_args.dry_run;

    // Find all epics eligible for closing
    var eligible_epics: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (eligible_epics.items) |id| {
            allocator.free(id);
        }
        eligible_epics.deinit(allocator);
    }

    const all_issues = try ctx.issue_store.list(.{});
    defer {
        for (all_issues) |*issue| {
            var i = issue.*;
            i.deinit(allocator);
        }
        allocator.free(all_issues);
    }

    for (all_issues) |issue| {
        if (issue.issue_type == .epic and issue.status != .tombstone and issue.status != .closed) {
            const counts = try countEpicChildren(&ctx, issue.id, allocator);
            if (counts.total > 0 and counts.closed == counts.total) {
                try eligible_epics.append(allocator, try allocator.dupe(u8, issue.id));
            }
        }
    }

    if (dry_run) {
        if (structured_output) {
            try ctx.output.printJson(EpicResult{
                .success = true,
                .action = "dry-run",
                .closed_count = eligible_epics.items.len,
                .message = "epics eligible for close (dry-run)",
            });
        } else {
            if (eligible_epics.items.len == 0) {
                try ctx.output.println("No epics eligible for auto-close", .{});
            } else {
                try ctx.output.println("Would close {d} epic(s):", .{eligible_epics.items.len});
                for (eligible_epics.items) |id| {
                    try ctx.output.print("  {s}\n", .{id});
                }
            }
        }
    } else {
        // Actually close the epics
        var closed_count: usize = 0;
        const now = std.time.timestamp();

        for (eligible_epics.items) |id| {
            const updates = storage.IssueUpdate{
                .status = .closed,
                .closed_at = now,
                .close_reason = "all children closed",
            };
            ctx.issue_store.update(id, updates, now) catch continue;
            closed_count += 1;
        }

        if (structured_output) {
            try ctx.output.printJson(EpicResult{
                .success = true,
                .action = "close-eligible",
                .closed_count = closed_count,
            });
        } else if (!global.quiet) {
            if (closed_count == 0) {
                try ctx.output.println("No epics eligible for auto-close", .{});
            } else {
                try ctx.output.success("Closed {d} epic(s)", .{closed_count});
            }
        }
    }
}

// --- Tests ---

test "EpicError enum exists" {
    const err: EpicError = EpicError.NotAnEpic;
    try std.testing.expect(err == EpicError.NotAnEpic);
}

test "EpicResult struct works" {
    const result = EpicResult{
        .success = true,
        .id = "bd-epic1",
        .action = "created",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("bd-epic1", result.id.?);
}

test "run detects uninitialized workspace" {
    const allocator = std.testing.allocator;

    const epic_args = args.EpicArgs{
        .subcommand = .{ .list = .{ .epic_id = "bd-test" } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const result = run(epic_args, global, allocator);
    try std.testing.expectError(EpicError.WorkspaceNotInitialized, result);
}

test "runCreate validates empty title" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "epic_empty");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const db_path = try std.fs.path.join(allocator, &.{ data_path, "beads.db" });
    defer allocator.free(db_path);

    var db = try storage.SqlDatabase.open(allocator, db_path);
    defer db.close();
    try storage.createSchema(&db);

    const epic_args = args.EpicArgs{
        .subcommand = .{ .create = .{ .title = "" } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    const result = run(epic_args, global, allocator);
    try std.testing.expectError(EpicError.EmptyTitle, result);
}

test "runCreate creates epic successfully" {
    const allocator = std.testing.allocator;

    const tmp_dir_path = try test_util.createTestDir(allocator, "epic_create");
    defer allocator.free(tmp_dir_path);
    defer test_util.cleanupTestDir(tmp_dir_path);

    const data_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, ".beads" });
    defer allocator.free(data_path);

    try std.fs.cwd().makeDir(data_path);

    const db_path = try std.fs.path.join(allocator, &.{ data_path, "beads.db" });
    defer allocator.free(db_path);

    var db = try storage.SqlDatabase.open(allocator, db_path);
    defer db.close();
    try storage.createSchema(&db);

    const epic_args = args.EpicArgs{
        .subcommand = .{ .create = .{
            .title = "Test Epic",
            .description = "Epic description",
        } },
    };
    const global = args.GlobalOptions{ .silent = true, .data_path = data_path };

    try run(epic_args, global, allocator);

    var issue_store = storage.IssueStore.init(&db, allocator);
    const count = try issue_store.countTotal();
    try std.testing.expectEqual(@as(usize, 1), count);
}
