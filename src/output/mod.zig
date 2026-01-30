//! Output formatting for beads_zig.
//!
//! Handles:
//! - Human-readable terminal output
//! - JSON output (--json flag)
//! - ANSI color support (respects NO_COLOR)
//! - Table formatting for list views
//! - Progress indicators

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
