//! Where command for beads_zig.
//!
//! `bz where` - Show the resolved .beads directory path
//!
//! Useful when .beads redirects are in play or to verify which workspace is active.

const std = @import("std");
const output_mod = @import("../output/mod.zig");
const args = @import("args.zig");

pub const WhereError = error{
    WriteError,
    WorkspaceNotFound,
};

pub const WhereResult = struct {
    success: bool,
    path: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// Run the where command.
pub fn run(global: args.GlobalOptions, allocator: std.mem.Allocator) WhereError!WhereResult {
    var out = output_mod.Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .silent = global.silent,
        .no_color = global.no_color,
    });

    // Determine the beads directory path
    const beads_dir = global.data_path orelse ".beads";

    // Try to get absolute path
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(beads_dir, &abs_path_buf) catch |err| {
        if (err == error.FileNotFound) {
            if (global.json) {
                out.printJson(WhereResult{
                    .success = false,
                    .message = "workspace not initialized",
                }) catch return WhereError.WriteError;
            } else if (!global.quiet) {
                out.err("workspace not initialized. Run 'bz init' first.", .{}) catch return WhereError.WriteError;
            }
            return WhereResult{
                .success = false,
                .message = "workspace not initialized",
            };
        }
        // Fall back to relative path if realpath fails for other reasons
        if (global.json) {
            out.printJson(WhereResult{
                .success = true,
                .path = beads_dir,
            }) catch return WhereError.WriteError;
        } else if (!global.quiet) {
            out.print("{s}\n", .{beads_dir}) catch return WhereError.WriteError;
        }
        return WhereResult{
            .success = true,
            .path = beads_dir,
        };
    };

    if (global.json) {
        out.printJson(WhereResult{
            .success = true,
            .path = abs_path,
        }) catch return WhereError.WriteError;
    } else if (!global.quiet) {
        out.print("{s}\n", .{abs_path}) catch return WhereError.WriteError;
    }

    return WhereResult{
        .success = true,
        .path = abs_path,
    };
}

// --- Tests ---

test "WhereError enum exists" {
    const err: WhereError = WhereError.WriteError;
    try std.testing.expect(err == WhereError.WriteError);
}

test "WhereResult struct works" {
    const result = WhereResult{
        .success = true,
        .path = "/home/user/project/.beads",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("/home/user/project/.beads", result.path.?);
}

test "run returns path for nonexistent workspace" {
    const allocator = std.testing.allocator;

    const result = try run(.{
        .silent = true,
        .data_path = "/nonexistent/path",
    }, allocator);

    try std.testing.expect(!result.success);
}
