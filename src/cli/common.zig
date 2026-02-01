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
pub const IssueStore = storage.IssueStore;
pub const IssueStoreError = storage.IssueStoreError;
pub const DependencyGraph = storage.DependencyGraph;
pub const EventStore = storage.EventStore;
pub const StoreLoadResult = storage.StoreLoadResult;

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
    store: IssueStore,
    event_store: EventStore,
    issues_path: []const u8,
    events_path: []const u8,
    global: args.GlobalOptions,
    /// Number of corrupt entries skipped during load.
    corruption_count: usize = 0,
    /// Line numbers of corrupt JSONL entries (owned memory).
    corrupt_lines: []const usize = &.{},

    /// Initialize a command context by loading the workspace.
    /// Returns null and outputs an error if workspace is not initialized.
    /// Uses graceful corruption recovery: logs and skips corrupt entries.
    pub fn init(
        allocator: std.mem.Allocator,
        global: args.GlobalOptions,
    ) CommandError!?CommandContext {
        var output = Output.init(allocator, .{
            .json = global.json,
            .toon = global.toon,
            .quiet = global.quiet,
            .silent = global.silent,
            .no_color = global.no_color,
        });

        const beads_dir = global.data_path orelse ".beads";
        const issues_path = std.fs.path.join(allocator, &.{ beads_dir, "issues.jsonl" }) catch {
            return CommandError.OutOfMemory;
        };
        const events_path = std.fs.path.join(allocator, &.{ beads_dir, "events.jsonl" }) catch {
            allocator.free(issues_path);
            return CommandError.OutOfMemory;
        };

        std.fs.cwd().access(issues_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                outputErrorGeneric(&output, global.isStructuredOutput(), "workspace not initialized. Run 'bz init' first.") catch {};
                allocator.free(issues_path);
                allocator.free(events_path);
                return null;
            }
            outputErrorGeneric(&output, global.isStructuredOutput(), "cannot access workspace") catch {};
            allocator.free(issues_path);
            allocator.free(events_path);
            return CommandError.StorageError;
        };

        var store = IssueStore.init(allocator, issues_path);
        var corruption_count: usize = 0;
        var corrupt_lines: []const usize = &.{};

        // Use recovery mode: log and skip corrupt entries instead of failing
        const load_result = store.loadFromFileWithRecovery() catch |err| {
            if (err != error.FileNotFound) {
                outputErrorGeneric(&output, global.isStructuredOutput(), "failed to load issues") catch {};
                store.deinit();
                allocator.free(issues_path);
                allocator.free(events_path);
                return CommandError.StorageError;
            }
            // File not found is OK - empty workspace
            return CommandContext{
                .allocator = allocator,
                .output = output,
                .store = store,
                .event_store = EventStore.init(allocator, events_path),
                .issues_path = issues_path,
                .events_path = events_path,
                .global = global,
                .corruption_count = 0,
                .corrupt_lines = &.{},
            };
        };

        corruption_count = load_result.jsonl_corruption_count;
        corrupt_lines = load_result.jsonl_corrupt_lines;

        // Warn user about corruption (unless quiet/silent mode)
        if (corruption_count > 0 and !global.quiet and !global.silent and !global.isStructuredOutput()) {
            output.print("warning: {d} corrupt entries skipped during load\n", .{corruption_count}) catch {};
            output.print("         Run 'bz doctor' for details, 'bz compact' to rebuild.\n", .{}) catch {};
        }

        // Initialize event store and load next ID
        var event_store = EventStore.init(allocator, events_path);
        event_store.loadNextId() catch {}; // OK if events file doesn't exist

        return CommandContext{
            .allocator = allocator,
            .output = output,
            .store = store,
            .event_store = event_store,
            .issues_path = issues_path,
            .events_path = events_path,
            .global = global,
            .corruption_count = corruption_count,
            .corrupt_lines = corrupt_lines,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *CommandContext) void {
        self.store.deinit();
        self.allocator.free(self.issues_path);
        self.allocator.free(self.events_path);
        if (self.corrupt_lines.len > 0) {
            self.allocator.free(self.corrupt_lines);
        }
    }

    /// Check if corruption was detected during load.
    pub fn hasCorruption(self: *const CommandContext) bool {
        return self.corruption_count > 0;
    }

    /// Save the store to file if auto-flush is enabled.
    pub fn saveIfAutoFlush(self: *CommandContext) CommandError!void {
        if (!self.global.no_auto_flush) {
            self.store.saveToFile() catch {
                outputErrorGeneric(&self.output, self.global.isStructuredOutput(), "failed to save issues") catch {};
                return CommandError.StorageError;
            };
        }
    }

    /// Create a dependency graph from the store.
    pub fn createGraph(self: *CommandContext) DependencyGraph {
        return DependencyGraph.init(&self.store, self.allocator);
    }

    /// Record an audit event. Silently ignores errors (audit is best-effort).
    pub fn recordEvent(self: *CommandContext, event: @import("../models/event.zig").Event) void {
        _ = self.event_store.append(event) catch {};
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
        .quiet = global.quiet,
        .silent = global.silent,
        .no_color = global.no_color,
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
