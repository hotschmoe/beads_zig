//! Database schema creation for beads_zig.
//!
//! Creates all tables, indexes, and FTS virtual tables matching beads_rust
//! schema exactly. Schema is idempotent - can be run multiple times.

const std = @import("std");
const sqlite = @import("zqlite");
const Database = sqlite.Database;

pub const SCHEMA_VERSION: u32 = 1;

pub fn createSchema(db: *Database) !void {
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
        \\    closed_by_session TEXT,
        \\    due_at INTEGER,
        \\    defer_until INTEGER,
        \\    external_ref TEXT UNIQUE,
        \\    source_system TEXT,
        \\    source_repo TEXT DEFAULT '.',
        \\    pinned INTEGER NOT NULL DEFAULT 0,
        \\    is_template INTEGER NOT NULL DEFAULT 0,
        \\    ephemeral INTEGER NOT NULL DEFAULT 0,
        \\    deleted_at TEXT,
        \\    deleted_by TEXT,
        \\    delete_reason TEXT,
        \\    original_type TEXT,
        \\    compaction_level INTEGER NOT NULL DEFAULT 0,
        \\    compacted_at TEXT,
        \\    compacted_at_commit TEXT,
        \\    original_size INTEGER DEFAULT 0,
        \\    sender TEXT
        \\)
    );

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

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS labels (
        \\    issue_id TEXT NOT NULL,
        \\    label TEXT NOT NULL,
        \\    PRIMARY KEY (issue_id, label),
        \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS comments (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    issue_id TEXT NOT NULL,
        \\    author TEXT NOT NULL,
        \\    text TEXT NOT NULL,
        \\    created_at INTEGER NOT NULL,
        \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS events (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    issue_id TEXT NOT NULL,
        \\    event_type TEXT NOT NULL,
        \\    actor TEXT NOT NULL,
        \\    old_value TEXT,
        \\    new_value TEXT,
        \\    comment TEXT,
        \\    created_at INTEGER NOT NULL,
        \\    FOREIGN KEY (issue_id) REFERENCES issues(id) ON DELETE CASCADE
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS dirty_issues (
        \\    issue_id TEXT PRIMARY KEY,
        \\    marked_at INTEGER NOT NULL
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS blocked_issues_cache (
        \\    issue_id TEXT PRIMARY KEY,
        \\    blocked_by TEXT NOT NULL,
        \\    blocked_at INTEGER NOT NULL
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS config (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS metadata (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS export_hashes (
        \\    issue_id TEXT PRIMARY KEY,
        \\    content_hash TEXT NOT NULL,
        \\    exported_at TEXT NOT NULL
        \\)
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS child_counters (
        \\    parent_id TEXT PRIMARY KEY,
        \\    last_child INTEGER NOT NULL DEFAULT 0
        \\)
    );

    try createIndexes(db);
    try createFts(db);

    try db.exec("INSERT OR REPLACE INTO metadata (key, value) VALUES ('schema_version', '" ++
        std.fmt.comptimePrint("{d}", .{SCHEMA_VERSION}) ++ "')");
}

const index_definitions = [_][]const u8{
    // Issues indexes
    "CREATE INDEX IF NOT EXISTS idx_issues_status ON issues(status)",
    "CREATE INDEX IF NOT EXISTS idx_issues_priority ON issues(priority)",
    "CREATE INDEX IF NOT EXISTS idx_issues_issue_type ON issues(issue_type)",
    "CREATE INDEX IF NOT EXISTS idx_issues_assignee ON issues(assignee)",
    "CREATE INDEX IF NOT EXISTS idx_issues_created_at ON issues(created_at)",
    "CREATE INDEX IF NOT EXISTS idx_issues_updated_at ON issues(updated_at)",
    "CREATE INDEX IF NOT EXISTS idx_issues_content_hash ON issues(content_hash)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_issues_external_ref ON issues(external_ref) WHERE external_ref IS NOT NULL",
    "CREATE INDEX IF NOT EXISTS idx_issues_ephemeral ON issues(ephemeral)",
    "CREATE INDEX IF NOT EXISTS idx_issues_pinned ON issues(pinned)",
    "CREATE INDEX IF NOT EXISTS idx_issues_tombstone ON issues(status) WHERE status = 'tombstone'",
    "CREATE INDEX IF NOT EXISTS idx_issues_due_at ON issues(due_at) WHERE due_at IS NOT NULL",
    "CREATE INDEX IF NOT EXISTS idx_issues_defer_until ON issues(defer_until) WHERE defer_until IS NOT NULL",
    // Dependencies indexes
    "CREATE INDEX IF NOT EXISTS idx_dependencies_issue ON dependencies(issue_id)",
    "CREATE INDEX IF NOT EXISTS idx_dependencies_depends_on ON dependencies(depends_on_id)",
    "CREATE INDEX IF NOT EXISTS idx_dependencies_type ON dependencies(dep_type)",
    "CREATE INDEX IF NOT EXISTS idx_dependencies_depends_on_type ON dependencies(depends_on_id, dep_type)",
    "CREATE INDEX IF NOT EXISTS idx_dependencies_blocking ON dependencies(depends_on_id) WHERE dep_type IN ('blocks', 'conditional_blocks', 'waits_for')",
    "CREATE INDEX IF NOT EXISTS idx_dependencies_thread ON dependencies(thread_id) WHERE thread_id IS NOT NULL",
    // Labels indexes
    "CREATE INDEX IF NOT EXISTS idx_labels_label ON labels(label)",
    "CREATE INDEX IF NOT EXISTS idx_labels_issue ON labels(issue_id)",
    // Comments indexes
    "CREATE INDEX IF NOT EXISTS idx_comments_issue ON comments(issue_id)",
    "CREATE INDEX IF NOT EXISTS idx_comments_created_at ON comments(created_at)",
    // Events indexes
    "CREATE INDEX IF NOT EXISTS idx_events_issue ON events(issue_id)",
    "CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type)",
    "CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at)",
    "CREATE INDEX IF NOT EXISTS idx_events_actor ON events(actor)",
    // Cache indexes
    "CREATE INDEX IF NOT EXISTS idx_blocked_cache_blocked_at ON blocked_issues_cache(blocked_at)",
};

// Composite index for ready query (critical for performance).
// Created separately because partial indexes with IN clauses need careful handling.
const ready_index_sql =
    \\CREATE INDEX IF NOT EXISTS idx_issues_ready ON issues(status, priority, created_at)
    \\WHERE status IN ('open', 'in_progress') AND ephemeral = 0 AND pinned = 0 AND is_template = 0
;

fn createIndexes(db: *Database) !void {
    for (index_definitions) |sql| {
        try db.exec(sql);
    }
    try db.exec(ready_index_sql);
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

pub fn getSchemaVersion(db: *Database) !?u32 {
    var stmt = db.prepare("SELECT value FROM metadata WHERE key = 'schema_version'") catch {
        // metadata table might not exist yet
        return null;
    };
    defer stmt.deinit();
    if (try stmt.step()) {
        const val = stmt.columnText(0) orelse return null;
        return std.fmt.parseInt(u32, val, 10) catch null;
    }
    return null;
}

// --- Tests ---

test "createSchema on fresh database" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    const version = try getSchemaVersion(&db);
    try std.testing.expectEqual(@as(?u32, 1), version);
}

test "issues table has correct columns" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    try db.exec(
        \\INSERT INTO issues (id, title, status, priority, issue_type, created_at, updated_at, pinned, is_template, ephemeral)
        \\VALUES ('bd-test1', 'Test Issue', 'open', 2, 'task', 1706540000, 1706540000, 0, 0, 0)
    );

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

    const long_title = "x" ** 501;

    var stmt = try db.prepare(
        "INSERT INTO issues (id, title, created_at, updated_at) VALUES ('bd-test', ?1, 0, 0)",
    );
    defer stmt.deinit();
    try stmt.bindText(1, long_title);

    const result = stmt.step();
    try std.testing.expectError(sqlite.SqliteError.StepFailed, result);
}

test "issues table enforces priority range constraint" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

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

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'");
    defer stmt.deinit();

    var count: u32 = 0;
    while (try stmt.step()) {
        count += 1;
    }

    // index_definitions (28) + ready_index (1) = 29
    try std.testing.expectEqual(@as(u32, 29), count);
}

test "FTS table exists" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='issues_fts'");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
}

test "metadata table stores schema version" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    var stmt = try db.prepare("SELECT value FROM metadata WHERE key = 'schema_version'");
    defer stmt.deinit();

    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("1", stmt.columnText(0).?);
}

test "createSchema is idempotent" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);
    try createSchema(&db);

    const version = try getSchemaVersion(&db);
    try std.testing.expectEqual(@as(?u32, 1), version);
}

test "br-parity tables exist" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    const expected_tables = [_][]const u8{
        "issues",
        "dependencies",
        "labels",
        "comments",
        "events",
        "dirty_issues",
        "blocked_issues_cache",
        "config",
        "metadata",
        "export_hashes",
        "child_counters",
    };

    for (expected_tables) |table_name| {
        var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?1");
        defer stmt.deinit();
        try stmt.bindText(1, table_name);
        const found = try stmt.step();
        try std.testing.expect(found);
    }
}

test "issues table has br-parity columns" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    // Insert with all br-parity columns
    try db.exec(
        \\INSERT INTO issues (
        \\    id, title, created_at, updated_at,
        \\    source_repo, ephemeral, deleted_at, deleted_by, delete_reason,
        \\    original_type, compaction_level, compacted_at, compacted_at_commit,
        \\    original_size, sender, closed_by_session
        \\) VALUES (
        \\    'bd-test', 'Test', 0, 0,
        \\    '.', 0, NULL, NULL, NULL,
        \\    NULL, 0, NULL, NULL,
        \\    0, NULL, NULL
        \\)
    );

    var stmt = try db.prepare("SELECT source_repo, ephemeral, compaction_level, original_size FROM issues WHERE id = 'bd-test'");
    defer stmt.deinit();
    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings(".", stmt.columnText(0).?);
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(1));
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(2));
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(3));
}

test "comments table uses text column" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-test', 'Test', 0, 0)
    );

    try db.exec(
        \\INSERT INTO comments (issue_id, author, text, created_at)
        \\VALUES ('bd-test', 'alice', 'First comment', 0)
    );

    var stmt = try db.prepare("SELECT text FROM comments WHERE issue_id = 'bd-test'");
    defer stmt.deinit();
    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("First comment", stmt.columnText(0).?);
}

test "events table has comment column" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-test', 'Test', 0, 0)
    );

    try db.exec(
        \\INSERT INTO events (issue_id, event_type, actor, comment, created_at)
        \\VALUES ('bd-test', 'commented', 'alice', 'A comment', 0)
    );

    var stmt = try db.prepare("SELECT comment FROM events WHERE issue_id = 'bd-test'");
    defer stmt.deinit();
    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("A comment", stmt.columnText(0).?);
}

test "dependencies table with foreign key cascade" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-parent', 'Parent', 0, 0)
    );
    try db.exec(
        \\INSERT INTO issues (id, title, created_at, updated_at)
        \\VALUES ('bd-child', 'Child', 0, 0)
    );
    try db.exec(
        \\INSERT INTO dependencies (issue_id, depends_on_id, dep_type, created_at)
        \\VALUES ('bd-child', 'bd-parent', 'blocks', 0)
    );

    try db.exec("DELETE FROM issues WHERE id = 'bd-child'");

    var stmt = try db.prepare("SELECT COUNT(*) FROM dependencies");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "export_hashes table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    try db.exec(
        \\INSERT INTO export_hashes (issue_id, content_hash, exported_at)
        \\VALUES ('bd-test', 'abc123', '2024-01-29T00:00:00Z')
    );

    var stmt = try db.prepare("SELECT content_hash, exported_at FROM export_hashes WHERE issue_id = 'bd-test'");
    defer stmt.deinit();
    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("abc123", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("2024-01-29T00:00:00Z", stmt.columnText(1).?);
}

test "child_counters table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(allocator, ":memory:");
    defer db.close();

    try createSchema(&db);

    try db.exec(
        \\INSERT INTO child_counters (parent_id, last_child) VALUES ('bd-parent', 3)
    );

    var stmt = try db.prepare("SELECT last_child FROM child_counters WHERE parent_id = 'bd-parent'");
    defer stmt.deinit();
    const found = try stmt.step();
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(i64, 3), stmt.columnInt(0));
}
