//! beads_zig - A local-first, offline-capable issue tracker.
//!
//! This is the library root that exports all public modules.
//! See VISION.md for project goals and SPEC.md for technical details.

const std = @import("std");

// Module exports
pub const cli = @import("cli/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const models = @import("models/mod.zig");
pub const sync = @import("sync/mod.zig");
pub const id = @import("id/mod.zig");
pub const config = @import("config/mod.zig");
pub const output = @import("output/mod.zig");

test {
    // Run tests from all submodules
    std.testing.refAllDecls(@This());
}
