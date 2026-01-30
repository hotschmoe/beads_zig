//! Database schema creation for beads_zig.
//!
//! Creates all tables, indexes, and FTS virtual tables as defined in SPEC.md.
//! Schema is idempotent - can be run multiple times without error.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const Database = sqlite.Database;

/// Schema version for migrations
pub const SCHEMA_VERSION: u32 = 1;

/// Create all tables and indexes
pub fn createSchema(db: *Database) !void {
    // Issues table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS issues (
        \\    id TEXT PRIMARY KEY,
        \\    content_hash TEXT,
        \\    title TEXT NOT NULL CHECK(length(title) <= 500),
        \\    description TEXT,
        \\    design TEXT,
        \\    acceptance_criteria TEXT,
        \\    notes TEXT,
        \\    status TEXT NOT NULL DEFAULT 'open',
        \\    priority INTEGER NOT NULL DEFAULT 2 CHECK(priority >= 0 AND priority <= 4),
        \\    issue_type TEXT NOT NULL DEFAULT 'task',
        \\    assignee TEXT,
        \\    owner TEXT,
        \\    estimated_minutes INTEGER,
        \\    created_at INTEGER NOT NULL,
        \\    created_by TEXT,
        \\    updated_at INTEGER NOT NULL,
        \\    closed_at INTEGER,
        \\    close_reason TEXT,
        \\    due_at INTEGER,
        \\    defer_until INTEGER,
        \\    external_ref TEXT UNIQUE,
        \\    source_system TEXT,
        \\    pinned INTEGER NOT NULL DEFAULT 0,
        \\    is_template INTEGER NOT NULL DEFAULT 0
        \\)
    );

    // Dependencies table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS dependencies (
        \\    issue_id TEXT NOT NULL,
        \\    depends_on_id TEXT NOT NULL,
        \\    dep_type TEXT NOT NULL DEFAULT 'blocks',
        \\    created_at INTEGER NOT NULL,
        \\    created_by TEXT,
        \\    metadata TEXT,
        \\    thread_id TEXT,
        \\    PRIMARY KEY (issue_id, depends_on_id),
        \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
        \\)
    );

    // Labels table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS labels (
        \\    issue_id TEXT NOT NULL,
        \\    label TEXT NOT NULL,
        \\    PRIMARY KEY (issue_id, label),
        \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
        \\)
    );

    // Comments table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS comments (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    issue_id TEXT NOT NULL,
        \\    author TEXT NOT NULL,
        \\    body TEXT NOT NULL,
        \\    created_at INTEGER NOT NULL,
        \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
        \\)
    );

    // Events table (audit log)
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS events (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    issue_id TEXT NOT NULL,
        \\    event_type TEXT NOT NULL,
        \\    actor TEXT NOT NULL,
        \\    old_value TEXT,
        \\    new_value TEXT,
        \\    created_at INTEGER NOT NULL,
        \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
        \\)
    );

    // Dirty tracking for sync
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS dirty_issues (
        \\    issue_id TEXT PRIMARY KEY,
        \\    marked_at INTEGER NOT NULL
        \\)
    );

    // Blocked cache for query optimization
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS blocked_cache (
        \\    issue_id TEXT PRIMARY KEY,
        \\    blocked_by TEXT NOT NULL,
        \\    cached_at INTEGER NOT NULL
        \\)
    );

    // Config storage
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS config (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\)
    );

    // Create indexes
    try createIndexes(db);

    // Create FTS table
    try createFts(db);

    // Store schema version
    try db.exec("INSERT OR REPLACE INTO config (key, value) VALUES ('schema_version', '1')");
}

fn createIndexes(db: *Database) !void {
    try db.exec("CREATE INDEX IF NOT EXISTS idx_issues_status ON issues(status)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_issues_priority ON issues(priority)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_issues_assignee ON issues(assignee)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_issues_created_at ON issues(created_at)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_issues_updated_at ON issues(updated_at)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_issues_content_hash ON issues(content_hash)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_deps_depends_on ON dependencies(depends_on_id)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_labels_label ON labels(label)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_comments_issue ON comments(issue_id)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_events_issue ON events(issue_id)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at)");
}

fn createFts(db: *Database) !void {
    try db.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS issues_fts USING fts5(
        \\    id,
        \\    title,
        \\    description,
        \\    notes,
        \\    content='issues',
        \\    content_rowid='rowid'
        \\)
    );
}

/// Get current schema version from database
pub fn getSchemaVersion(db: *Database) !?u32 {
    var stmt = try db.prepare("SELECT value FROM config WHERE key = 'schema_version'");
    defer stmt.deinit();
    if (try stmt.step()) {
        const val = stmt.columnText(0) orelse return null;
        return std.fmt.parseInt(u32, val, 10) catch null;
    }
    return null;
}

// Tests

test "createSchema on fresh database" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Verify schema version was stored
    const version = try getSchemaVersion(&db);
    try std.testing.expectEqual(@as(?u32, 1), version);
}

test "issues table has correct columns" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Insert a valid issue
    try db.exec(
        \\INSERT INTO issues (id, title, status, priority, issue_type, created_at, updated_at, pinned, is_template)
        \\VALUES ('bd-test1', 'Test Issue', 'open', 2, 'task', 1706540000, 1706540000, 0, 0)
    );

    // Verify we can read it back
    var stmt = try db.prepare("SELECT id, title, status, priority FROM issues WHERE id = 'bd-test1'");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("bd-test1", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("Test Issue", stmt.columnText(1).?);
    try std.testing.expectEqualStrings("open", stmt.columnText(2).?);
    try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(3));
}

test "issues table enforces title length constraint" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Create a title longer than 500 characters
    const long_title = "x" ** 501;

    var stmt = try db.prepare(
        "INSERT INTO issues (id, title, created_at, updated_at) VALUES ('bd-test', ?1, 0, 0)",
    );
    defer stmt.deinit();
    try stmt.bindText(1, long_title);

    // Should fail due to CHECK constraint
    const result = stmt.step();
    try std.testing.expectError(sqlite.SqliteError.StepFailed, result);
}

test "issues table enforces priority range constraint" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Try to insert priority 5 (out of range 0-4)
    const result = db.exec(
        "INSERT INTO issues (id, title, priority, created_at, updated_at) VALUES ('bd-test', 'Test', 5, 0, 0)",
    );
    try std.testing.expectError(sqlite.SqliteError.ExecuteFailed, result);
}

test "indexes exist" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Query sqlite_master for our indexes
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'");
    defer stmt.deinit();

    var count: u32 = 0;
    while (try stmt.step()) {
        count += 1;
    }

    // We create 11 indexes
    try std.testing.expectEqual(@as(u32, 11), count);
}

test "FTS table exists" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Check for FTS table in sqlite_master
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='issues_fts'");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
}

test "schema version is stored" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    var stmt = try db.prepare("SELECT value FROM config WHERE key = 'schema_version'");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("1", stmt.columnText(0).?);
}

test "createSchema is idempotent" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    // Run twice - should not error
    try createSchema(&db);
    try createSchema(&db);

    // Verify schema still works
    const version = try getSchemaVersion(&db);
    try std.testing.expectEqual(@as(?u32, 1), version);
}

test "dependencies table with foreign key" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Create parent issue
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-parent', 'Parent', 0, 0)
    );

    // Create child issue
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-child', 'Child', 0, 0)
    );

    // Create dependency
    try db.exec(
        \\INSERT INTO dependencies (issue_id, depends_on_id, dep_type, created_at)
        \\VALUES ('bd-child', 'bd-parent', 'blocks', 0)
    );

    // Delete parent - should cascade delete the dependency
    try db.exec("DELETE FROM issues WHERE id = 'bd-child'");

    // Verify dependency was deleted
    var stmt = try db.prepare("SELECT COUNT(*) FROM dependencies");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "labels table with foreign key" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Create issue
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-test', 'Test', 0, 0)
    );

    // Add labels
    try db.exec("INSERT INTO labels (issue_id, label) VALUES ('bd-test', 'bug')");
    try db.exec("INSERT INTO labels (issue_id, label) VALUES ('bd-test', 'urgent')");

    // Delete issue - should cascade delete labels
    try db.exec("DELETE FROM issues WHERE id = 'bd-test'");

    var stmt = try db.prepare("SELECT COUNT(*) FROM labels");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "comments table with autoincrement" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Create issue
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-test', 'Test', 0, 0)
    );

    // Add comments
    try db.exec(
        \\INSERT INTO comments (issue_id, author, body, created_at)
        \\VALUES ('bd-test', 'alice', 'First comment', 0)
    );
    try db.exec(
        \\INSERT INTO comments (issue_id, author, body, created_at)
        \\VALUES ('bd-test', 'bob', 'Second comment', 0)
    );

    // Verify autoincrement IDs
    var stmt = try db.prepare("SELECT id FROM comments ORDER BY id");
    defer stmt.deinit();

    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
}

test "events table with autoincrement" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Create issue
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-test', 'Test', 0, 0)
    );

    // Add events
    try db.exec(
        \\INSERT INTO events (issue_id, event_type, actor, created_at)
        \\VALUES ('bd-test', 'created', 'alice', 0)
    );
    try db.exec(
        \\INSERT INTO events (issue_id, event_type, actor, old_value, new_value, created_at)
        \\VALUES ('bd-test', 'status_changed', 'alice', 'open', 'closed', 1)
    );

    // Verify events recorded
    var stmt = try db.prepare("SELECT COUNT(*) FROM events WHERE issue_id = 'bd-test'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
}

test "dirty_issues table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Mark issue as dirty
    try db.exec("INSERT INTO dirty_issues (issue_id, marked_at) VALUES ('bd-test', 1706540000)");

    // Verify
    var stmt = try db.prepare("SELECT issue_id, marked_at FROM dirty_issues");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("bd-test", stmt.columnText(0).?);
    try std.testing.expectEqual(@as(i64, 1706540000), stmt.columnInt(1));
}

test "blocked_cache table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Add blocked cache entry (blocked_by is JSON array of blocker IDs)
    try db.exec(
        \\INSERT INTO blocked_cache (issue_id, blocked_by, cached_at)
        \\VALUES ('bd-child', '["bd-parent1", "bd-parent2"]', 1706540000)
    );

    // Verify
    var stmt = try db.prepare("SELECT blocked_by FROM blocked_cache WHERE issue_id = 'bd-child'");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("[\"bd-parent1\", \"bd-parent2\"]", stmt.columnText(0).?);
}

test "config table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Add custom config
    try db.exec("INSERT OR REPLACE INTO config (key, value) VALUES ('custom_key', 'custom_value')");

    // Verify
    var stmt = try db.prepare("SELECT value FROM config WHERE key = 'custom_key'");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("custom_value", stmt.columnText(0).?);
}

test "getSchemaVersion returns null for empty config" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    // Create only config table, no schema version
    try db.exec("CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL)");

    const version = try getSchemaVersion(&db);
    try std.testing.expect(version == null);
}
