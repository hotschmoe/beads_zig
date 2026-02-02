//! Migration engine for beads_zig JSONL database upgrades.
//!
//! Handles schema version detection and sequential migrations between versions.
//! Each migration is atomic: backup -> migrate -> update metadata (or rollback on failure).
//!
//! Usage:
//!   const migrations = @import("migrations.zig");
//!   const result = try migrations.migrateIfNeeded(allocator, ".beads");

const std = @import("std");

/// Current bz version - should match cli/version.zig VERSION constant.
pub const BZ_VERSION: []const u8 = "0.1.5";

/// Current schema version expected by this build.
pub const CURRENT_SCHEMA_VERSION: u32 = 1;

/// Minimum schema version that can be migrated from.
pub const MIN_SUPPORTED_VERSION: u32 = 1;

/// Default number of backup files to keep during cleanup.
pub const DEFAULT_BACKUP_KEEP_COUNT: usize = 3;

pub const MigrationError = error{
    /// metadata.json not found or unreadable
    MetadataNotFound,
    /// metadata.json contains invalid JSON
    MetadataParseError,
    /// Schema version in metadata is newer than this build supports
    SchemaVersionTooNew,
    /// Schema version in metadata is older than minimum supported
    SchemaVersionTooOld,
    /// Failed to create backup before migration
    BackupFailed,
    /// Migration function failed
    MigrationFailed,
    /// Failed to restore from backup after migration failure
    RollbackFailed,
    /// Failed to update metadata.json after migration
    MetadataUpdateFailed,
    /// issues.jsonl not found
    IssuesNotFound,
    /// Out of memory
    OutOfMemory,
    /// I/O error
    IoError,
};

/// Result of a migration attempt.
pub const MigrationResult = struct {
    /// Whether any migrations were applied.
    migrated: bool = false,
    /// Starting schema version.
    from_version: u32,
    /// Ending schema version.
    to_version: u32,
    /// Number of migrations applied.
    migrations_applied: u32 = 0,
    /// Path to backup file (if created).
    backup_path: ?[]const u8 = null,

    pub fn deinit(self: *MigrationResult, allocator: std.mem.Allocator) void {
        if (self.backup_path) |path| {
            allocator.free(path);
            self.backup_path = null;
        }
    }
};

/// Metadata structure read from metadata.json.
pub const Metadata = struct {
    schema_version: u32 = 1,
    created_at: ?[]const u8 = null,
    bz_version: ?[]const u8 = null,
    prefix: ?[]const u8 = null,

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        if (self.created_at) |s| {
            allocator.free(s);
            self.created_at = null;
        }
        if (self.bz_version) |s| {
            allocator.free(s);
            self.bz_version = null;
        }
        if (self.prefix) |s| {
            allocator.free(s);
            self.prefix = null;
        }
    }
};

/// A single migration step.
const Migration = struct {
    from_version: u32,
    to_version: u32,
    /// Migration function that transforms issues.jsonl content.
    /// Returns new content or null if no changes needed.
    migrate_fn: *const fn (allocator: std.mem.Allocator, content: []const u8) MigrationError!?[]const u8,
    description: []const u8,
};

/// Registry of all migrations in order.
/// Each migration transforms from one version to the next.
const migrations: []const Migration = &.{
    // Future migrations go here:
    // .{
    //     .from_version = 1,
    //     .to_version = 2,
    //     .migrate_fn = migrateV1toV2,
    //     .description = "Rename 'assignee' to 'assigned_to'",
    // },
};

/// Check if migrations are needed and apply them if so.
/// This is the main entry point for the migration system.
pub fn migrateIfNeeded(
    allocator: std.mem.Allocator,
    beads_dir: []const u8,
) MigrationError!MigrationResult {
    // Read current schema version from metadata
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{beads_dir});
    defer allocator.free(metadata_path);

    var metadata = readMetadata(allocator, metadata_path) catch |err| {
        // If metadata doesn't exist, assume version 1 (legacy)
        if (err == error.FileNotFound or err == error.MetadataNotFound) {
            return MigrationResult{
                .from_version = 1,
                .to_version = CURRENT_SCHEMA_VERSION,
            };
        }
        return err;
    };
    defer metadata.deinit(allocator);

    const current_version = metadata.schema_version;

    // Already at current version?
    if (current_version == CURRENT_SCHEMA_VERSION) {
        return MigrationResult{
            .from_version = current_version,
            .to_version = current_version,
        };
    }

    // Version too new?
    if (current_version > CURRENT_SCHEMA_VERSION) {
        return MigrationError.SchemaVersionTooNew;
    }

    // Version too old?
    if (current_version < MIN_SUPPORTED_VERSION) {
        return MigrationError.SchemaVersionTooOld;
    }

    // Find applicable migrations
    const applicable = getApplicableMigrations(current_version, CURRENT_SCHEMA_VERSION);
    if (applicable.len == 0) {
        return MigrationResult{
            .from_version = current_version,
            .to_version = CURRENT_SCHEMA_VERSION,
        };
    }

    // Create backup before migration
    const issues_path = try std.fmt.allocPrint(allocator, "{s}/issues.jsonl", .{beads_dir});
    defer allocator.free(issues_path);

    const backup_path = try createBackup(allocator, issues_path, current_version);
    errdefer {
        // Clean up backup on error
        if (backup_path) |path| {
            std.fs.cwd().deleteFile(path) catch {};
            allocator.free(path);
        }
    }

    // Apply migrations sequentially
    var version = current_version;
    var migrations_applied: u32 = 0;

    for (applicable) |migration| {
        applyMigration(allocator, issues_path, migration) catch {
            // Rollback on failure
            if (backup_path) |path| {
                rollback(path, issues_path) catch {
                    return MigrationError.RollbackFailed;
                };
            }
            return MigrationError.MigrationFailed;
        };
        version = migration.to_version;
        migrations_applied += 1;
    }

    // Update metadata with new version
    updateMetadataVersion(allocator, metadata_path, version) catch {
        // Rollback on metadata update failure
        if (backup_path) |path| {
            rollback(path, issues_path) catch {
                return MigrationError.RollbackFailed;
            };
        }
        return MigrationError.MetadataUpdateFailed;
    };

    return MigrationResult{
        .migrated = migrations_applied > 0,
        .from_version = current_version,
        .to_version = version,
        .migrations_applied = migrations_applied,
        .backup_path = backup_path,
    };
}

/// Read and parse metadata.json.
pub fn readMetadata(allocator: std.mem.Allocator, path: []const u8) MigrationError!Metadata {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return MigrationError.MetadataNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return MigrationError.IoError;
    };
    defer allocator.free(content);

    return parseMetadata(allocator, content) catch {
        return MigrationError.MetadataParseError;
    };
}

/// Parse metadata JSON content.
fn parseMetadata(allocator: std.mem.Allocator, content: []const u8) !Metadata {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return error.MetadataParseError;
    };
    defer parsed.deinit();

    var metadata = Metadata{};
    errdefer metadata.deinit(allocator);

    if (parsed.value.object.get("schema_version")) |v| {
        metadata.schema_version = @intCast(v.integer);
    }

    if (parsed.value.object.get("created_at")) |v| {
        if (v == .string) {
            metadata.created_at = try allocator.dupe(u8, v.string);
        }
    }

    if (parsed.value.object.get("bz_version")) |v| {
        if (v == .string) {
            metadata.bz_version = try allocator.dupe(u8, v.string);
        }
    }

    if (parsed.value.object.get("prefix")) |v| {
        if (v == .string) {
            metadata.prefix = try allocator.dupe(u8, v.string);
        }
    }

    return metadata;
}

/// Get migrations that need to be applied to go from current to target version.
fn getApplicableMigrations(current: u32, target: u32) []const Migration {
    var start: usize = 0;
    var end: usize = 0;

    for (migrations, 0..) |m, i| {
        if (m.from_version >= current and m.to_version <= target) {
            if (start == 0 and m.from_version == current) {
                start = i;
            }
            end = i + 1;
        }
    }

    if (end <= start) {
        return &.{};
    }

    return migrations[start..end];
}

/// Create a backup of issues.jsonl before migration.
fn createBackup(
    allocator: std.mem.Allocator,
    issues_path: []const u8,
    version: u32,
) MigrationError!?[]const u8 {
    // Check if source file exists
    std.fs.cwd().access(issues_path, .{}) catch {
        // No issues file to backup
        return null;
    };

    // Generate backup filename with timestamp
    const now = std.time.timestamp();
    const backup_path = std.fmt.allocPrint(allocator, "{s}.backup-v{d}-{d}", .{
        issues_path,
        version,
        now,
    }) catch {
        return MigrationError.OutOfMemory;
    };
    errdefer allocator.free(backup_path);

    // Copy file
    std.fs.cwd().copyFile(issues_path, std.fs.cwd(), backup_path, .{}) catch {
        return MigrationError.BackupFailed;
    };

    return backup_path;
}

/// Apply a single migration to the issues file.
fn applyMigration(
    allocator: std.mem.Allocator,
    issues_path: []const u8,
    migration: Migration,
) MigrationError!void {
    // Read current content
    const file = std.fs.cwd().openFile(issues_path, .{}) catch {
        return MigrationError.IssuesNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        return MigrationError.IoError;
    };
    defer allocator.free(content);

    // Apply migration function
    const new_content = migration.migrate_fn(allocator, content) catch {
        return MigrationError.MigrationFailed;
    };

    // If migration returned new content, write it
    if (new_content) |transformed| {
        defer allocator.free(transformed);
        writeAtomically(issues_path, transformed) catch {
            return MigrationError.IoError;
        };
    }
}

/// Write content atomically using temp file + rename.
fn writeAtomically(path: []const u8, content: []const u8) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}", .{
        path,
        std.time.timestamp(),
    });

    // Write to temp file
    const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    try tmp_file.writeAll(content);
    try tmp_file.sync();
    tmp_file.close();

    // Atomic rename
    try std.fs.cwd().rename(tmp_path, path);
}

/// Rollback by restoring from backup.
fn rollback(backup_path: []const u8, issues_path: []const u8) !void {
    try std.fs.cwd().copyFile(backup_path, std.fs.cwd(), issues_path, .{});
}

/// Update schema_version in metadata.json.
fn updateMetadataVersion(
    allocator: std.mem.Allocator,
    metadata_path: []const u8,
    new_version: u32,
) !void {
    // Read existing metadata
    const file = std.fs.cwd().openFile(metadata_path, .{}) catch {
        return MigrationError.MetadataNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return MigrationError.IoError;
    };
    defer allocator.free(content);

    // Parse and update
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return MigrationError.MetadataParseError;
    };
    defer parsed.deinit();

    // Get existing values
    var created_at: []const u8 = "";
    var prefix: []const u8 = "bd";

    if (parsed.value.object.get("created_at")) |v| {
        if (v == .string) created_at = v.string;
    }
    if (parsed.value.object.get("prefix")) |v| {
        if (v == .string) prefix = v.string;
    }

    // Write updated metadata with new schema version and current bz version
    const new_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schema_version": {d},
        \\  "created_at": "{s}",
        \\  "bz_version": "{s}",
        \\  "prefix": "{s}"
        \\}}
        \\
    , .{ new_version, created_at, BZ_VERSION, prefix });
    defer allocator.free(new_content);

    writeAtomically(metadata_path, new_content) catch {
        return MigrationError.IoError;
    };
}

/// Check schema version without migrating.
pub fn checkSchemaVersion(
    allocator: std.mem.Allocator,
    beads_dir: []const u8,
) MigrationError!u32 {
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{beads_dir});
    defer allocator.free(metadata_path);

    var metadata = readMetadata(allocator, metadata_path) catch |err| {
        if (err == error.FileNotFound or err == error.MetadataNotFound) {
            return 1; // Assume version 1 for legacy
        }
        return err;
    };
    defer metadata.deinit(allocator);

    return metadata.schema_version;
}

/// Clean up old migration backups, keeping only the most recent.
pub fn cleanupBackups(
    allocator: std.mem.Allocator,
    beads_dir: []const u8,
    keep_count: usize,
) !void {
    const issues_path = try std.fmt.allocPrint(allocator, "{s}/issues.jsonl", .{beads_dir});
    defer allocator.free(issues_path);

    const backup_prefix = try std.fmt.allocPrint(allocator, "{s}.backup-v", .{issues_path});
    defer allocator.free(backup_prefix);

    var dir = std.fs.cwd().openDir(beads_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var backups = std.ArrayList([]const u8).init(allocator);
    defer {
        for (backups.items) |item| allocator.free(item);
        backups.deinit();
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ beads_dir, entry.name });
            if (std.mem.startsWith(u8, full_path, backup_prefix)) {
                try backups.append(full_path);
            } else {
                allocator.free(full_path);
            }
        }
    }

    // Sort by name (which includes timestamp) and remove oldest
    std.mem.sort([]const u8, backups.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.cmp);

    // Delete oldest backups beyond keep_count
    if (backups.items.len > keep_count) {
        const to_delete = backups.items.len - keep_count;
        for (backups.items[0..to_delete]) |path| {
            std.fs.cwd().deleteFile(path) catch {};
        }
    }
}

// --- Tests ---

test "MigrationResult struct initialization" {
    var result = MigrationResult{
        .from_version = 1,
        .to_version = 2,
        .migrated = true,
    };
    try std.testing.expect(result.migrated);
    try std.testing.expectEqual(@as(u32, 1), result.from_version);
    try std.testing.expectEqual(@as(u32, 2), result.to_version);
    result.deinit(std.testing.allocator);
}

test "Metadata struct initialization" {
    var metadata = Metadata{
        .schema_version = 2,
    };
    try std.testing.expectEqual(@as(u32, 2), metadata.schema_version);
    try std.testing.expect(metadata.bz_version == null);
    try std.testing.expect(metadata.prefix == null);
    metadata.deinit(std.testing.allocator);
}

test "parseMetadata parses valid JSON" {
    const content =
        \\{
        \\  "schema_version": 1,
        \\  "created_at": "2026-02-02T10:00:00Z",
        \\  "bz_version": "0.1.5",
        \\  "prefix": "bd"
        \\}
    ;
    var metadata = try parseMetadata(std.testing.allocator, content);
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), metadata.schema_version);
    try std.testing.expectEqualStrings("2026-02-02T10:00:00Z", metadata.created_at.?);
    try std.testing.expectEqualStrings("0.1.5", metadata.bz_version.?);
    try std.testing.expectEqualStrings("bd", metadata.prefix.?);
}

test "parseMetadata handles legacy metadata without bz_version" {
    const content =
        \\{
        \\  "schema_version": 1,
        \\  "created_at": "2026-02-02T10:00:00Z",
        \\  "issue_count": 5
        \\}
    ;
    var metadata = try parseMetadata(std.testing.allocator, content);
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), metadata.schema_version);
    try std.testing.expect(metadata.bz_version == null);
    try std.testing.expect(metadata.prefix == null);
}

test "getApplicableMigrations returns empty for no migrations needed" {
    // With empty migrations registry, should return empty
    const applicable = getApplicableMigrations(1, 1);
    try std.testing.expectEqual(@as(usize, 0), applicable.len);
}

test "CURRENT_SCHEMA_VERSION is valid" {
    try std.testing.expect(CURRENT_SCHEMA_VERSION >= MIN_SUPPORTED_VERSION);
}

test "MigrationError enum exists" {
    const err: MigrationError = MigrationError.MetadataNotFound;
    try std.testing.expect(err == MigrationError.MetadataNotFound);
}

test "writeAtomically writes content correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_content = "test content\n";
    const test_path = "test_file.txt";

    // Create file in temp dir
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = tmp.dir.realpath(test_path, &path_buf) catch {
        // File doesn't exist yet, create path manually
        const dir_path = tmp.dir.realpathAlloc(std.testing.allocator, ".") catch return;
        defer std.testing.allocator.free(dir_path);
        const combined = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, test_path }) catch return;
        try writeAtomically(combined, test_content);
        const read_content = try tmp.dir.readFileAlloc(std.testing.allocator, test_path, 1024);
        defer std.testing.allocator.free(read_content);
        try std.testing.expectEqualStrings(test_content, read_content);
        return;
    };

    try writeAtomically(full_path, test_content);

    const read_content = try tmp.dir.readFileAlloc(std.testing.allocator, test_path, 1024);
    defer std.testing.allocator.free(read_content);
    try std.testing.expectEqualStrings(test_content, read_content);
}
