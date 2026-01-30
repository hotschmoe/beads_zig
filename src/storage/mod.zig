//! Database storage layer for beads_zig.
//!
//! Handles all SQLite operations including:
//! - Schema initialization and migrations
//! - Issue CRUD operations
//! - Dependency management
//! - Label and comment storage
//! - Event/audit logging
//! - Full-text search via FTS5
//! - Dirty tracking for sync

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
