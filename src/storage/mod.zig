//! Storage layer for beads_zig.
//!
//! Handles all persistence operations including:
//! - SQLite database (primary storage)
//! - JSONL file I/O (sync export/import)
//! - Event audit trail
//! - Issue and dependency CRUD
//! - Schema migrations

const std = @import("std");

// SQLite storage
pub const sqlite = @import("sqlite.zig");
pub const sql_schema = @import("schema.zig");

// JSONL storage (kept for sync export/import)
pub const jsonl = @import("jsonl.zig");

// Domain stores (SQLite-backed)
pub const issues = @import("issues.zig");
pub const dependencies = @import("dependencies.zig");
pub const events = @import("events.zig");

// Migrations
pub const migrations = @import("migrations.zig");

// SQLite types
pub const SqlDatabase = sqlite.Database;
pub const SqlStatement = sqlite.Statement;
pub const SqliteError = sqlite.SqliteError;
pub const createSchema = sql_schema.createSchema;
pub const getSchemaVersion = sql_schema.getSchemaVersion;
pub const SQL_SCHEMA_VERSION = sql_schema.SCHEMA_VERSION;

// JSONL types
pub const JsonlFile = jsonl.JsonlFile;
pub const JsonlError = jsonl.JsonlError;
pub const LoadResult = jsonl.LoadResult;

// Issue types
pub const IssueStore = issues.IssueStore;
pub const IssueStoreError = issues.IssueStoreError;
pub const IssueUpdate = IssueStore.IssueUpdate;
pub const ListFilters = IssueStore.ListFilters;
pub const GroupBy = IssueStore.GroupBy;
pub const CountResult = IssueStore.CountResult;

// Dependency types
pub const DependencyStore = dependencies.DependencyStore;
pub const DependencyStoreError = dependencies.DependencyStoreError;
pub const BlockedInfo = dependencies.BlockedInfo;

// Event types
pub const EventStore = events.EventStore;
pub const EventStoreError = events.EventStoreError;

// Migration types
pub const MigrationError = migrations.MigrationError;
pub const MigrationResult = migrations.MigrationResult;
pub const Metadata = migrations.Metadata;
pub const migrateIfNeeded = migrations.migrateIfNeeded;
pub const checkSchemaVersion = migrations.checkSchemaVersion;
pub const CURRENT_SCHEMA_VERSION = migrations.CURRENT_SCHEMA_VERSION;
pub const BZ_VERSION = migrations.BZ_VERSION;

test {
    std.testing.refAllDecls(@This());
}
