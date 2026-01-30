//! Configuration management for beads_zig.
//!
//! Precedence (highest to lowest):
//! 1. CLI flags
//! 2. Environment variables (BEADS_*)
//! 3. Project config (.beads/config.yaml)
//! 4. User config (~/.config/beads/config.yaml)
//! 5. Database config table
//! 6. Built-in defaults

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
