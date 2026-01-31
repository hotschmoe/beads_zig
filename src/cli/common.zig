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
pub const DependencyGraph = storage.DependencyGraph;

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
    issues_path: []const u8,
    global: args.GlobalOptions,

    /// Initialize a command context by loading the workspace.
    /// Returns null and outputs an error if workspace is not initialized.
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

        std.fs.cwd().access(issues_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                outputErrorGeneric(&output, global.isStructuredOutput(), "workspace not initialized. Run 'bz init' first.") catch {};
                allocator.free(issues_path);
                return null;
            }
            outputErrorGeneric(&output, global.isStructuredOutput(), "cannot access workspace") catch {};
            allocator.free(issues_path);
            return CommandError.StorageError;
        };

        var store = IssueStore.init(allocator, issues_path);

        store.loadFromFile() catch |err| {
            if (err != error.FileNotFound) {
                outputErrorGeneric(&output, global.isStructuredOutput(), "failed to load issues") catch {};
                store.deinit();
                allocator.free(issues_path);
                return CommandError.StorageError;
            }
        };

        return CommandContext{
            .allocator = allocator,
            .output = output,
            .store = store,
            .issues_path = issues_path,
            .global = global,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *CommandContext) void {
        self.store.deinit();
        self.allocator.free(self.issues_path);
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

// --- Tests ---

test "CommandContext returns null for uninitialized workspace" {
    const allocator = std.testing.allocator;
    const global = args.GlobalOptions{ .silent = true, .data_path = "/nonexistent/path" };

    const ctx = try CommandContext.init(allocator, global);
    try std.testing.expect(ctx == null);
}
