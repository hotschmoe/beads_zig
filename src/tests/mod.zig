//! Test module for beads_zig.
//!
//! Contains integration and end-to-end tests.

const std = @import("std");

pub const cli_test = @import("cli_test.zig");

test {
    std.testing.refAllDecls(@This());
}
