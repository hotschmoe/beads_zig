//! Common CLI utilities shared across commands.
//!
//! Provides workspace loading, error handling, and shared result types
//! to reduce duplication across command implementations.

const std = @import("std");
const storage = @import("../storage/mod.zig");
const output_mod = @import("../output/mod.zig");
const args = @import("args.zig");

pub const Output = output_mod.Output;
pub const OutputOptions = output_mod.OutputOptions;
pub const Database = storage.SqlDatabase;
pub const IssueStore = storage.IssueStore;
pub const IssueStoreError = storage.IssueStoreError;
pub const DependencyStore = storage.DependencyStore;
pub const EventStore = storage.EventStore;

/// Full issue representation for agent consumption in JSON output.
pub const IssueFull = struct {
    id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    status: []const u8,
    priority: u3,
    issue_type: []const u8,
    assignee: ?[]const u8 = null,
    labels: []const []const u8,
    created_at: i64,
    updated_at: i64,
    blocks: []const []const u8,
};

/// Collect IDs of issues that depend on the given issue (issues it blocks).
/// Caller owns returned slice and must free each ID and the slice itself.
pub fn collectBlocksIds(
    allocator: std.mem.Allocator,
    dep_store: *DependencyStore,
    issue_id: []const u8,
) ![][]const u8 {
    const dependents = try dep_store.getDependents(issue_id);
    defer {
        for (dependents) |dep| {
            allocator.free(dep.issue_id);
            allocator.free(dep.depends_on_id);
            switch (dep.dep_type) {
                .custom => |s| allocator.free(s),
                else => {},
            }
            if (dep.created_by) |c| allocator.free(c);
            if (dep.metadata) |m| allocator.free(m);
            if (dep.thread_id) |t| allocator.free(t);
        }
        allocator.free(dependents);
    }

    var blocks_ids = try allocator.alloc([]const u8, dependents.len);
    errdefer {
        for (blocks_ids) |bid| allocator.free(bid);
        allocator.free(blocks_ids);
    }
    for (dependents, 0..) |dep, j| {
        blocks_ids[j] = try allocator.dupe(u8, dep.issue_id);
    }
    return blocks_ids;
}

/// Free a blocks IDs slice allocated by collectBlocksIds.
pub fn freeBlocksIds(allocator: std.mem.Allocator, blocks_ids: []const []const u8) void {
    for (blocks_ids) |block_id| {
        allocator.free(block_id);
    }
    allocator.free(blocks_ids);
}

/// Common errors shared across CLI commands.
pub const CommandError = error{
    WorkspaceNotInitialized,
    StorageError,
    OutOfMemory,
};

/// Context for executing a CLI command with an initialized workspace.
pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    output: Output,
    db: Database,
    issue_store: IssueStore,
    dep_store: DependencyStore,
    event_store: EventStore,
    beads_dir: []const u8,
    db_path: []const u8,
    global: args.GlobalOptions,

    /// Initialize a command context by opening the SQLite database.
    /// Returns null and outputs an error if workspace is not initialized.
    pub fn init(
        allocator: std.mem.Allocator,
        global: args.GlobalOptions,
    ) CommandError!?CommandContext {
        var output = Output.init(allocator, .{
            .json = global.json,
            .toon = global.toon,
            .robot = global.robot,
            .quiet = global.quiet,
            .silent = global.silent,
            .no_color = global.no_color,
            .wrap = global.wrap,
            .stats = global.stats,
        });

        const beads_dir_str = global.data_path orelse ".beads";
        const beads_dir = allocator.dupe(u8, beads_dir_str) catch {
            return CommandError.OutOfMemory;
        };

        const db_path = std.fs.path.join(allocator, &.{ beads_dir, "beads.db" }) catch {
            allocator.free(beads_dir);
            return CommandError.OutOfMemory;
        };

        // Check if workspace is initialized by looking for the database
        std.fs.cwd().access(db_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Also check for legacy issues.jsonl (user might need to run init)
                outputErrorGeneric(&output, global.isStructuredOutput(), "workspace not initialized. Run 'bz init' first.") catch {};
                allocator.free(db_path);
                allocator.free(beads_dir);
                return null;
            }
            outputErrorGeneric(&output, global.isStructuredOutput(), "cannot access workspace database") catch {};
            allocator.free(db_path);
            allocator.free(beads_dir);
            return CommandError.StorageError;
        };

        var db = Database.open(allocator, db_path) catch {
            outputErrorGeneric(&output, global.isStructuredOutput(), "failed to open database") catch {};
            allocator.free(db_path);
            allocator.free(beads_dir);
            return CommandError.StorageError;
        };

        // Ensure schema is up to date (idempotent)
        storage.createSchema(&db) catch {
            outputErrorGeneric(&output, global.isStructuredOutput(), "failed to initialize database schema") catch {};
            db.close();
            allocator.free(db_path);
            allocator.free(beads_dir);
            return CommandError.StorageError;
        };

        const issue_store = IssueStore.init(&db, allocator);
        const dep_store = DependencyStore.init(&db, allocator);
        const event_store = EventStore.init(&db, allocator);

        return CommandContext{
            .allocator = allocator,
            .output = output,
            .db = db,
            .issue_store = issue_store,
            .dep_store = dep_store,
            .event_store = event_store,
            .beads_dir = beads_dir,
            .db_path = db_path,
            .global = global,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *CommandContext) void {
        self.db.close();
        self.allocator.free(self.db_path);
        self.allocator.free(self.beads_dir);
    }

    /// Record an audit event. Silently ignores errors (audit is best-effort).
    pub fn recordEvent(self: *CommandContext, event: @import("../models/event.zig").Event) void {
        self.event_store.insert(event) catch {};
    }
};

/// Output a generic error message in the appropriate format.
pub fn outputErrorGeneric(output: *Output, json_mode: bool, message: []const u8) !void {
    if (json_mode) {
        try output.printJson(.{
            .success = false,
            .message = message,
        });
    } else {
        try output.err("{s}", .{message});
    }
}

/// Output an error with a specific result type for JSON mode.
pub fn outputErrorTyped(
    comptime T: type,
    output: *Output,
    json_mode: bool,
    message: []const u8,
) !void {
    if (json_mode) {
        const result = T{ .success = false, .message = message };
        try output.printJson(result);
    } else {
        try output.err("{s}", .{message});
    }
}

/// Output a "not found" error for an issue.
pub fn outputNotFoundError(
    comptime T: type,
    output: *Output,
    json_mode: bool,
    id: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const msg = try std.fmt.allocPrint(allocator, "issue not found: {s}", .{id});
    defer allocator.free(msg);
    try outputErrorTyped(T, output, json_mode, msg);
}

/// Initialize just the output without loading workspace.
/// Useful for commands that do their own workspace handling.
pub fn initOutput(allocator: std.mem.Allocator, global: args.GlobalOptions) Output {
    return Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .robot = global.robot,
        .quiet = global.quiet,
        .silent = global.silent,
        .no_color = global.no_color,
        .wrap = global.wrap,
        .stats = global.stats,
    });
}

/// Get the default actor name from environment.
pub fn getDefaultActor() ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return null;
    return std.posix.getenv("USER") orelse std.posix.getenv("USERNAME");
}

/// Read the ID prefix from config.yaml, defaulting to "bd".
pub fn getConfigPrefix(allocator: std.mem.Allocator, beads_dir: []const u8) ![]u8 {
    const config_path = try std.fs.path.join(allocator, &.{ beads_dir, "config.yaml" });
    defer allocator.free(config_path);

    const file = std.fs.cwd().openFile(config_path, .{}) catch {
        return try allocator.dupe(u8, "bd");
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 4096) catch {
        return try allocator.dupe(u8, "bd");
    };
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, "prefix:")) |prefix_pos| {
        const after_prefix = content[prefix_pos + 7 ..];
        var i: usize = 0;
        while (i < after_prefix.len and (after_prefix[i] == ' ' or after_prefix[i] == '\t')) {
            i += 1;
        }

        if (i < after_prefix.len) {
            if (after_prefix[i] == '"') {
                i += 1;
                const start = i;
                while (i < after_prefix.len and after_prefix[i] != '"' and after_prefix[i] != '\n') {
                    i += 1;
                }
                if (i > start) {
                    return try allocator.dupe(u8, after_prefix[start..i]);
                }
            } else {
                const start = i;
                while (i < after_prefix.len and after_prefix[i] != '\n' and after_prefix[i] != ' ' and after_prefix[i] != '\t') {
                    i += 1;
                }
                if (i > start) {
                    return try allocator.dupe(u8, after_prefix[start..i]);
                }
            }
        }
    }

    return try allocator.dupe(u8, "bd");
}

// --- Tests ---

test "CommandContext returns null for uninitialized workspace" {
    const allocator = std.testing.allocator;
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const ctx = try CommandContext.init(allocator, global);
    try std.testing.expect(ctx == null);
}
