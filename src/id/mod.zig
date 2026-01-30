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
pub const hash = @import("hash.zig");
pub const generator = @import("generator.zig");

pub const contentHash = hash.contentHash;
pub const contentHashAlloc = hash.contentHashAlloc;

pub const IdGenerator = generator.IdGenerator;
pub const ParsedId = generator.ParsedId;
pub const parseId = generator.parseId;
pub const validateId = generator.validateId;

test {
    std.testing.refAllDecls(@This());
}
