//! beads_zig CLI entry point.
//!
//! Binary name: bz (beads-zig)

const std = @import("std");
const beads_zig = @import("beads_zig");

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("bz: beads_zig issue tracker\n");
    try stdout.writeAll("Run `bz --help` for usage.\n");
}

test "library imports compile" {
    // Verify all modules are accessible
    _ = beads_zig.cli;
    _ = beads_zig.storage;
    _ = beads_zig.models;
    _ = beads_zig.sync;
    _ = beads_zig.id;
    _ = beads_zig.config;
    _ = beads_zig.output;
}
