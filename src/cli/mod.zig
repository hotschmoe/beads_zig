//! CLI command implementations for beads_zig.
//!
//! This module handles argument parsing and dispatches to the appropriate
//! command handlers (create, list, show, update, close, sync, etc.).
//!
//! All commands support --json output for machine-readable responses.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
