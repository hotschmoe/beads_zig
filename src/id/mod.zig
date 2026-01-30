//! ID generation for beads_zig.
//!
//! Generates unique issue IDs in the format: <prefix>-<hash>
//! - prefix: Configurable, default "bd"
//! - hash: Base36 encoded, adaptive length (3-8 chars)
//!
//! Features:
//! - Collision-resistant random generation
//! - Hierarchical IDs for parent/child (bd-abc.1.2)
//! - Content hashing for deduplication

const std = @import("std");

pub const base36 = @import("base36.zig");

test {
    std.testing.refAllDecls(@This());
}
