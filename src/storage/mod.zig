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

pub const sqlite = @import("sqlite.zig");

pub const Database = sqlite.Database;
pub const Statement = sqlite.Statement;
pub const SqliteError = sqlite.SqliteError;
pub const transaction = sqlite.transaction;
pub const transactionSimple = sqlite.transactionSimple;

test {
    std.testing.refAllDecls(@This());
}
