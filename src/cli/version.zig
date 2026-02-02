//! Version command for beads_zig.
//!
//! Displays version information about the bz binary.

const std = @import("std");
const builtin = @import("builtin");
const output = @import("../output/mod.zig");

pub const VERSION = "0.1.5";

pub const VersionError = error{
    WriteError,
};

pub const VersionResult = struct {
    version: []const u8,
    zig_version: []const u8,
    target: []const u8,
};

pub fn run(global: anytype, allocator: std.mem.Allocator) VersionError!VersionResult {
    var out = output.Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    const zig_version = builtin.zig_version_string;
    const target = @tagName(builtin.target.os.tag) ++ "-" ++ @tagName(builtin.target.cpu.arch);

    if (global.json) {
        const version_info = .{
            .version = VERSION,
            .zig_version = zig_version,
            .target = target,
        };
        out.printJson(version_info) catch return VersionError.WriteError;
    } else {
        out.print("bz {s}\n", .{VERSION}) catch return VersionError.WriteError;
        out.print("zig {s}\n", .{zig_version}) catch return VersionError.WriteError;
        out.print("{s}\n", .{target}) catch return VersionError.WriteError;
    }

    return .{
        .version = VERSION,
        .zig_version = zig_version,
        .target = target,
    };
}

// --- Tests ---

test "VERSION is valid semver" {
    try std.testing.expect(VERSION.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, VERSION, ".") != null);
}

test "run returns version info" {
    const allocator = std.testing.allocator;

    const result = try run(.{
        .json = false,
        .toon = false,
        .quiet = true,
        .no_color = true,
    }, allocator);

    try std.testing.expectEqualStrings(VERSION, result.version);
    try std.testing.expect(result.zig_version.len > 0);
    try std.testing.expect(result.target.len > 0);
}
