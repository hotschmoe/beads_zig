# Deep Dive: Porting beads_rust to Zig

## Executive Summary

`beads_rust` (command: `br`) is a ~20K LOC Rust port of Steve Yegge's beads - a local-first, non-invasive issue tracker designed for AI coding agents. It uses SQLite + JSONL hybrid storage with explicit sync semantics. A Zig port (`bz`?) would be an excellent fit given the project's philosophy: minimal dependencies, explicit control, fast compilation, small binaries.

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│                          CLI Layer                             │
│   Commands: init, create, list, ready, close, sync, etc.       │
│   Output: Text (default) | JSON (--json flag)                  │
└─────────────────────────────┬──────────────────────────────────┘
                              │
┌─────────────────────────────▼──────────────────────────────────┐
│                       Business Logic                           │
│   - Issue lifecycle (create, update, close, reopen)            │
│   - Dependency graph (add, remove, cycle detection)            │
│   - Labels, comments, events                                   │
│   - Ready work calculation (unblocked issues)                  │
│   - Statistics and reporting                                   │
└─────────────────────────────┬──────────────────────────────────┘
                              │
┌─────────────────────────────▼──────────────────────────────────┐
│                       Storage Layer                            │
│  ┌─────────────────────┐      ┌────────────────────────────┐   │
│  │   SqliteStorage     │◄────►│   JSONL Export/Import      │   │
│  │   - WAL mode        │ sync │   - Atomic writes          │   │
│  │   - Dirty tracking  │      │   - Content hashing        │   │
│  │   - Blocked cache   │      │   - Git merge support      │   │
│  │   - FTS5 search     │      │   - Line-based format      │   │
│  └─────────┬───────────┘      └─────────────┬──────────────┘   │
└────────────│────────────────────────────────│──────────────────┘
             ▼                                ▼
      .beads/beads.db                  .beads/issues.jsonl
```

---

## Core Data Types

### Issue (Primary Entity)

```zig
const Issue = struct {
    id: []const u8,           // e.g., "bd-7f3a2c" (prefix + hash)
    title: []const u8,
    description: ?[]const u8,
    status: Status,
    issue_type: IssueType,
    priority: u8,             // 0=critical, 1=high, 2=medium, 3=low, 4=backlog
    assignee: ?[]const u8,
    creator: []const u8,
    created_at: i64,          // Unix timestamp
    updated_at: i64,
    closed_at: ?i64,
    close_reason: ?[]const u8,
    labels: []const []const u8,
    parent_id: ?[]const u8,   // For sub-issues
    estimate: ?u32,           // Story points or hours
    due_date: ?i64,
    dirty: bool,              // Needs sync to JSONL
    deleted: bool,            // Tombstone for sync
    
    const Status = enum {
        open,
        in_progress,
        blocked,
        closed,
        deferred,
    };
    
    const IssueType = enum {
        bug,
        feature,
        task,
        epic,
        story,
        chore,
        question,
    };
};
```

### Dependency

```zig
const Dependency = struct {
    from_id: []const u8,      // Child/dependent issue
    to_id: []const u8,        // Parent/blocker issue
    dep_type: Type,
    created_at: i64,
    
    const Type = enum {
        blocks,               // to_id blocks from_id
        related,              // Soft relationship
        duplicates,           // from_id duplicates to_id
        parent,               // Hierarchical relationship
    };
};
```

### Comment

```zig
const Comment = struct {
    id: []const u8,
    issue_id: []const u8,
    author: []const u8,
    content: []const u8,
    created_at: i64,
    updated_at: ?i64,
};
```

### Event (Audit Log)

```zig
const Event = struct {
    id: []const u8,
    issue_id: []const u8,
    event_type: Type,
    actor: []const u8,
    timestamp: i64,
    old_value: ?[]const u8,   // JSON
    new_value: ?[]const u8,   // JSON
    
    const Type = enum {
        created,
        status_changed,
        priority_changed,
        assigned,
        unassigned,
        labeled,
        unlabeled,
        commented,
        closed,
        reopened,
        dependency_added,
        dependency_removed,
    };
};
```

---

## Storage Layer Design

### SQLite Schema

```sql
-- Core issues table
CREATE TABLE issues (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'open',
    issue_type TEXT NOT NULL DEFAULT 'task',
    priority INTEGER NOT NULL DEFAULT 2,
    assignee TEXT,
    creator TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    closed_at INTEGER,
    close_reason TEXT,
    parent_id TEXT REFERENCES issues(id),
    estimate INTEGER,
    due_date INTEGER,
    dirty INTEGER NOT NULL DEFAULT 1,
    deleted INTEGER NOT NULL DEFAULT 0
);

-- Labels (many-to-many)
CREATE TABLE labels (
    issue_id TEXT NOT NULL REFERENCES issues(id),
    label TEXT NOT NULL,
    PRIMARY KEY (issue_id, label)
);

-- Dependencies
CREATE TABLE dependencies (
    from_id TEXT NOT NULL REFERENCES issues(id),
    to_id TEXT NOT NULL REFERENCES issues(id),
    dep_type TEXT NOT NULL DEFAULT 'blocks',
    created_at INTEGER NOT NULL,
    PRIMARY KEY (from_id, to_id)
);

-- Comments
CREATE TABLE comments (
    id TEXT PRIMARY KEY,
    issue_id TEXT NOT NULL REFERENCES issues(id),
    author TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER
);

-- Events (audit log)
CREATE TABLE events (
    id TEXT PRIMARY KEY,
    issue_id TEXT NOT NULL REFERENCES issues(id),
    event_type TEXT NOT NULL,
    actor TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    old_value TEXT,
    new_value TEXT
);

-- FTS5 full-text search
CREATE VIRTUAL TABLE issues_fts USING fts5(
    id, title, description,
    content='issues',
    content_rowid='rowid'
);

-- Indices for common queries
CREATE INDEX idx_issues_status ON issues(status);
CREATE INDEX idx_issues_priority ON issues(priority);
CREATE INDEX idx_issues_assignee ON issues(assignee);
CREATE INDEX idx_issues_dirty ON issues(dirty);
CREATE INDEX idx_deps_to ON dependencies(to_id);
CREATE INDEX idx_events_issue ON events(issue_id);
```

### Zig SQLite Wrapper

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteStorage = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    
    // Prepared statements cache
    stmts: struct {
        insert_issue: ?*c.sqlite3_stmt = null,
        update_issue: ?*c.sqlite3_stmt = null,
        get_issue: ?*c.sqlite3_stmt = null,
        list_issues: ?*c.sqlite3_stmt = null,
        get_ready: ?*c.sqlite3_stmt = null,
        add_dep: ?*c.sqlite3_stmt = null,
        check_cycle: ?*c.sqlite3_stmt = null,
        // ... etc
    } = .{},
    
    pub fn open(path: []const u8) !SqliteStorage {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path.ptr,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null
        );
        if (rc != c.SQLITE_OK) {
            return error.SqliteOpenFailed;
        }
        
        // Enable WAL mode for concurrent reads
        _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL", null, null, null);
        _ = c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL", null, null, null);
        _ = c.sqlite3_exec(db, "PRAGMA foreign_keys=ON", null, null, null);
        
        var self = SqliteStorage{
            .db = db.?,
            .allocator = std.heap.page_allocator,
        };
        try self.initSchema();
        return self;
    }
    
    pub fn close(self: *SqliteStorage) void {
        // Finalize all prepared statements
        inline for (std.meta.fields(@TypeOf(self.stmts))) |field| {
            if (@field(self.stmts, field.name)) |stmt| {
                _ = c.sqlite3_finalize(stmt);
            }
        }
        _ = c.sqlite3_close(self.db);
    }
    
    // Transaction wrapper
    pub fn transaction(self: *SqliteStorage, comptime func: anytype, args: anytype) !@TypeOf(func).ReturnType {
        _ = c.sqlite3_exec(self.db, "BEGIN", null, null, null);
        errdefer _ = c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
        const result = try @call(.auto, func, .{self} ++ args);
        _ = c.sqlite3_exec(self.db, "COMMIT", null, null, null);
        return result;
    }
    
    // Get ready work (unblocked, open issues)
    pub fn getReadyWork(self: *SqliteStorage, allocator: std.mem.Allocator) ![]Issue {
        const sql =
            \\SELECT i.* FROM issues i
            \\WHERE i.status = 'open'
            \\  AND i.deleted = 0
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM dependencies d
            \\    JOIN issues blocker ON d.to_id = blocker.id
            \\    WHERE d.from_id = i.id
            \\      AND d.dep_type = 'blocks'
            \\      AND blocker.status != 'closed'
            \\  )
            \\ORDER BY i.priority ASC, i.created_at ASC
        ;
        // ... execute and collect results
    }
    
    // Cycle detection using recursive CTE
    pub fn wouldCreateCycle(self: *SqliteStorage, from: []const u8, to: []const u8) !bool {
        const sql =
            \\WITH RECURSIVE ancestors(id) AS (
            \\  SELECT ?2
            \\  UNION
            \\  SELECT d.to_id FROM dependencies d
            \\  JOIN ancestors a ON d.from_id = a.id
            \\  WHERE d.dep_type = 'blocks'
            \\)
            \\SELECT 1 FROM ancestors WHERE id = ?1 LIMIT 1
        ;
        // ... execute and check result
    }
};
```

### JSONL Format

Each line is a complete JSON object representing an issue:

```json
{"id":"bd-7f3a2c","title":"Fix login timeout","status":"open","priority":1,...}
{"id":"bd-e9b1d4","title":"Set up database","status":"closed","priority":1,...}
```

Zig JSONL parser:

```zig
pub const JsonlStorage = struct {
    allocator: std.mem.Allocator,
    
    pub fn exportToJsonl(
        self: *JsonlStorage,
        storage: *SqliteStorage,
        path: []const u8,
    ) !void {
        // Atomic write: write to temp file, then rename
        const tmp_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}.tmp.{d}",
            .{ path, std.time.milliTimestamp() }
        );
        defer self.allocator.free(tmp_path);
        
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        
        var writer = file.writer();
        
        // Export all non-deleted issues
        var iter = try storage.iterateIssues(.{ .include_deleted = false });
        defer iter.deinit();
        
        while (try iter.next()) |issue| {
            try std.json.stringify(issue, .{}, writer);
            try writer.writeByte('\n');
        }
        
        // Atomic rename
        try std.fs.cwd().rename(tmp_path, path);
        
        // Clear dirty flags
        try storage.clearDirtyFlags();
    }
    
    pub fn importFromJsonl(
        self: *JsonlStorage,
        storage: *SqliteStorage,
        path: []const u8,
    ) !ImportResult {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        var reader = std.io.bufferedReader(file.reader());
        var line_buf: [64 * 1024]u8 = undefined; // 64KB max line
        
        var imported: usize = 0;
        var updated: usize = 0;
        var skipped: usize = 0;
        
        while (reader.reader().readUntilDelimiter(&line_buf, '\n')) |line| {
            if (line.len == 0) continue;
            
            const issue = std.json.parseFromSlice(
                Issue,
                self.allocator,
                line,
                .{}
            ) catch {
                skipped += 1;
                continue;
            };
            defer issue.deinit();
            
            // Merge logic: compare timestamps, newer wins
            if (try storage.getIssue(issue.value.id)) |existing| {
                if (issue.value.updated_at > existing.updated_at) {
                    try storage.updateIssue(issue.value);
                    updated += 1;
                } else {
                    skipped += 1;
                }
            } else {
                try storage.createIssue(issue.value);
                imported += 1;
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        
        return .{
            .imported = imported,
            .updated = updated,
            .skipped = skipped,
        };
    }
};
```

---

## CLI Design

### Command Structure

```zig
const Command = union(enum) {
    init: InitCmd,
    create: CreateCmd,
    q: QuickCmd,          // Quick capture
    show: ShowCmd,
    update: UpdateCmd,
    close: CloseCmd,
    reopen: ReopenCmd,
    delete: DeleteCmd,
    list: ListCmd,
    ready: ReadyCmd,
    blocked: BlockedCmd,
    search: SearchCmd,
    stale: StaleCmd,
    count: CountCmd,
    dep: DepCmd,
    label: LabelCmd,
    comments: CommentsCmd,
    sync: SyncCmd,
    doctor: DoctorCmd,
    stats: StatsCmd,
    config: ConfigCmd,
    upgrade: UpgradeCmd,
    version: VersionCmd,
};

const GlobalFlags = struct {
    json: bool = false,
    quiet: bool = false,
    verbose: u2 = 0,       // 0, 1, 2 (-v, -vv)
    no_color: bool = false,
    db: ?[]const u8 = null,
};
```

### Argument Parsing

Using a hand-rolled parser (no external deps):

```zig
pub const ArgParser = struct {
    args: []const [:0]const u8,
    index: usize = 0,
    
    pub fn parse(comptime T: type, args: []const [:0]const u8) !T {
        var parser = ArgParser{ .args = args };
        return parser.parseCommand(T);
    }
    
    fn parseCommand(self: *ArgParser, comptime T: type) !T {
        const cmd_str = self.next() orelse return error.MissingCommand;
        
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, cmd_str, field.name)) {
                return @unionInit(T, field.name, try self.parseStruct(field.type));
            }
        }
        return error.UnknownCommand;
    }
    
    fn parseStruct(self: *ArgParser, comptime T: type) !T {
        var result: T = .{};
        
        while (self.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) {
                const flag = arg[2..];
                inline for (std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, flag, field.name)) {
                        @field(result, field.name) = try self.parseValue(field.type);
                    }
                }
            } else if (std.mem.startsWith(u8, arg, "-")) {
                // Short flags
                for (arg[1..]) |ch| {
                    inline for (std.meta.fields(T)) |field| {
                        if (field.name[0] == ch) {
                            @field(result, field.name) = true;
                        }
                    }
                }
            } else {
                // Positional argument
                // ...
            }
        }
        return result;
    }
};
```

### Output Formatting

```zig
const OutputFormat = struct {
    json: bool,
    no_color: bool,
    writer: std.fs.File.Writer,
    
    pub fn issue(self: *OutputFormat, issue: Issue) !void {
        if (self.json) {
            try std.json.stringify(issue, .{}, self.writer);
            try self.writer.writeByte('\n');
        } else {
            try self.formatIssueText(issue);
        }
    }
    
    fn formatIssueText(self: *OutputFormat, i: Issue) !void {
        // Priority color
        const priority_color: []const u8 = if (self.no_color) "" else switch (i.priority) {
            0 => "\x1b[91m",  // Bright red
            1 => "\x1b[93m",  // Yellow
            2 => "\x1b[97m",  // White
            3 => "\x1b[90m",  // Gray
            else => "\x1b[90m",
        };
        const reset = if (self.no_color) "" else "\x1b[0m";
        
        try self.writer.print("{s}{s}  P{d}  {s: <8}  {s}{s}\n", .{
            priority_color,
            i.id,
            i.priority,
            @tagName(i.issue_type),
            i.title,
            reset,
        });
    }
};
```

---

## ID Generation

Hash-based IDs ensure uniqueness without coordination:

```zig
const IdGen = struct {
    prefix: []const u8,
    
    pub fn generate(self: IdGen, allocator: std.mem.Allocator) ![]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        
        // Mix entropy sources
        const timestamp = std.time.nanoTimestamp();
        hasher.update(std.mem.asBytes(&timestamp));
        
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        hasher.update(&random_bytes);
        
        const hash = hasher.finalResult();
        
        // Take first 6 hex characters
        const id = try std.fmt.allocPrint(
            allocator,
            "{s}-{s}",
            .{ self.prefix, std.fmt.fmtSliceHexLower(hash[0..3]) }
        );
        return id;
    }
};
```

---

## Dependency Graph

### Cycle Detection (DFS)

```zig
pub fn detectCycles(storage: *SqliteStorage, allocator: std.mem.Allocator) !?[][]const u8 {
    var visited = std.StringHashMap(VisitState).init(allocator);
    defer visited.deinit();
    
    var path = std.ArrayList([]const u8).init(allocator);
    defer path.deinit();
    
    // Get all issues
    var iter = try storage.iterateIssues(.{});
    defer iter.deinit();
    
    while (try iter.next()) |issue| {
        if (visited.get(issue.id) == null) {
            if (try dfs(storage, issue.id, &visited, &path, allocator)) |cycle| {
                return cycle;
            }
        }
    }
    return null;
}

const VisitState = enum { visiting, visited };

fn dfs(
    storage: *SqliteStorage,
    node: []const u8,
    visited: *std.StringHashMap(VisitState),
    path: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !?[][]const u8 {
    try visited.put(node, .visiting);
    try path.append(node);
    
    // Get blocking dependencies
    var deps = try storage.getDependencies(node, .blocks);
    defer deps.deinit();
    
    for (deps.items) |dep| {
        const neighbor = dep.to_id;
        
        if (visited.get(neighbor)) |state| {
            if (state == .visiting) {
                // Found cycle - extract it
                var cycle_start: usize = 0;
                for (path.items, 0..) |p, i| {
                    if (std.mem.eql(u8, p, neighbor)) {
                        cycle_start = i;
                        break;
                    }
                }
                return try allocator.dupe([]const u8, path.items[cycle_start..]);
            }
        } else {
            if (try dfs(storage, neighbor, visited, path, allocator)) |cycle| {
                return cycle;
            }
        }
    }
    
    try visited.put(node, .visited);
    _ = path.pop();
    return null;
}
```

### Dependency Tree Visualization

```zig
pub fn printDependencyTree(
    storage: *SqliteStorage,
    root_id: []const u8,
    writer: anytype,
) !void {
    var visited = std.StringHashMap(void).init(storage.allocator);
    defer visited.deinit();
    
    try printNode(storage, root_id, writer, &visited, 0, true);
}

fn printNode(
    storage: *SqliteStorage,
    id: []const u8,
    writer: anytype,
    visited: *std.StringHashMap(void),
    depth: usize,
    is_last: bool,
) !void {
    if (visited.contains(id)) {
        try writer.print("{s}↻ {s} (circular)\n", .{ indent(depth), id });
        return;
    }
    try visited.put(id, {});
    
    const issue = try storage.getIssue(id) orelse return;
    const prefix = if (is_last) "└── " else "├── ";
    
    try writer.print("{s}{s}{s} [{s}] {s}\n", .{
        indent(depth),
        prefix,
        id,
        @tagName(issue.status),
        issue.title,
    });
    
    var deps = try storage.getBlockers(id);
    defer deps.deinit();
    
    for (deps.items, 0..) |dep, i| {
        const last = i == deps.items.len - 1;
        try printNode(storage, dep.to_id, writer, visited, depth + 1, last);
    }
}
```

---

## Configuration System

Layered config with YAML parsing:

```zig
const Config = struct {
    id: struct {
        prefix: []const u8 = "bd",
    } = .{},
    
    defaults: struct {
        priority: u8 = 2,
        issue_type: Issue.IssueType = .task,
        assignee: ?[]const u8 = null,
    } = .{},
    
    output: struct {
        color: bool = true,
        date_format: []const u8 = "%Y-%m-%d",
    } = .{},
    
    sync: struct {
        auto_import: bool = false,
        auto_flush: bool = false,
    } = .{},
    
    pub fn load(allocator: std.mem.Allocator) !Config {
        var config = Config{};
        
        // Layer 1: User config (~/.config/beads/config.yaml)
        if (getUserConfigPath()) |user_path| {
            if (loadYaml(allocator, user_path)) |user_config| {
                config = mergeConfig(config, user_config);
            }
        }
        
        // Layer 2: Project config (.beads/config.yaml)
        if (loadYaml(allocator, ".beads/config.yaml")) |project_config| {
            config = mergeConfig(config, project_config);
        }
        
        // Layer 3: Environment variables
        if (std.posix.getenv("BEADS_PREFIX")) |prefix| {
            config.id.prefix = prefix;
        }
        
        return config;
    }
};
```

---

## Sync Safety Model

The key guarantee: **br sync never executes git commands or modifies files outside .beads/**

```zig
pub const SyncCommand = struct {
    flush_only: bool = false,
    import_only: bool = false,
    force: bool = false,
    allow_external_jsonl: bool = false,
    
    pub fn execute(self: SyncCommand, storage: *SqliteStorage) !SyncResult {
        // Safety check: validate paths
        const jsonl_path = getJsonlPath() orelse return error.NoJsonlConfigured;
        
        if (!self.allow_external_jsonl) {
            if (!isInsideBeadsDir(jsonl_path)) {
                return error.ExternalJsonlNotAllowed;
            }
        }
        
        // Check for git merge conflicts
        if (hasConflictMarkers(jsonl_path)) {
            return error.UnresolvedMergeConflict;
        }
        
        if (self.flush_only) {
            return self.doFlush(storage, jsonl_path);
        } else if (self.import_only) {
            return self.doImport(storage, jsonl_path);
        } else {
            // Bidirectional sync
            const import_result = try self.doImport(storage, jsonl_path);
            const flush_result = try self.doFlush(storage, jsonl_path);
            return mergeResults(import_result, flush_result);
        }
    }
    
    fn doFlush(self: SyncCommand, storage: *SqliteStorage, path: []const u8) !SyncResult {
        // Safety: Don't overwrite non-empty JSONL with empty DB
        const db_count = try storage.countIssues();
        const jsonl_count = try countJsonlLines(path);
        
        if (db_count == 0 and jsonl_count > 0 and !self.force) {
            return error.WouldDeleteIssues;
        }
        
        // Create backup before overwriting
        try createBackup(path);
        
        // Atomic write
        try storage.exportToJsonl(path);
        
        return .{ .flushed = db_count };
    }
};

fn isInsideBeadsDir(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".beads/") or
           std.mem.indexOf(u8, path, "/.beads/") != null;
}

fn hasConflictMarkers(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    
    var buf: [4096]u8 = undefined;
    while (file.reader().readUntilDelimiter(&buf, '\n')) |line| {
        if (std.mem.startsWith(u8, line, "<<<<<<<") or
            std.mem.startsWith(u8, line, "=======") or
            std.mem.startsWith(u8, line, ">>>>>>>"))
        {
            return true;
        }
    } else |_| {}
    return false;
}
```

---

## Zig-Specific Advantages

### 1. Comptime JSON Schema Generation

```zig
fn generateJsonSchema(comptime T: type) []const u8 {
    comptime {
        var schema: []const u8 = "{\n  \"type\": \"object\",\n  \"properties\": {\n";
        
        inline for (std.meta.fields(T)) |field| {
            schema = schema ++ "    \"" ++ field.name ++ "\": " ++
                     typeToJsonSchema(field.type) ++ ",\n";
        }
        
        return schema ++ "  }\n}";
    }
}

// Usage: const IssueSchema = comptime generateJsonSchema(Issue);
```

### 2. Zero-Allocation Iterators

```zig
pub const IssueIterator = struct {
    stmt: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,
    
    pub fn next(self: *IssueIterator) !?Issue {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
        
        return Issue{
            .id = self.getText(0),
            .title = self.getText(1),
            // ... etc
        };
    }
    
    fn getText(self: *IssueIterator, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, col);
        const len = c.sqlite3_column_bytes(self.stmt, col);
        return ptr[0..@intCast(len)];
    }
};
```

### 3. Small Binary Size

Expected: ~500KB-1MB static binary vs 5-8MB for Rust version

```zig
// build.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const exe = b.addExecutable(.{
        .name = "bz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
    });
    
    // Link SQLite
    exe.linkSystemLibrary("sqlite3");
    // Or bundle it:
    // exe.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c") });
    
    b.installArtifact(exe);
}
```

### 4. Error Handling with Context

```zig
const BeadsError = error{
    DatabaseNotFound,
    NotInitialized,
    IssueNotFound,
    DuplicateId,
    CycleDetected,
    InvalidStatus,
    SyncConflict,
    MergeConflict,
    // ...
};

fn createIssue(storage: *SqliteStorage, issue: Issue) BeadsError!void {
    storage.insertIssue(issue) catch |err| switch (err) {
        error.ConstraintViolation => return error.DuplicateId,
        error.SqliteError => {
            std.log.err("SQLite error creating issue {s}: {s}", .{
                issue.id,
                storage.getLastError(),
            });
            return error.DatabaseError;
        },
        else => return err,
    };
}
```

---

## Module Structure

```
bz/
├── build.zig
├── src/
│   ├── main.zig              # Entry point, CLI dispatch
│   ├── cli/
│   │   ├── parser.zig        # Argument parsing
│   │   ├── commands.zig      # Command definitions
│   │   └── output.zig        # Text/JSON formatting
│   ├── storage/
│   │   ├── sqlite.zig        # SQLite backend
│   │   ├── jsonl.zig         # JSONL export/import
│   │   └── schema.zig        # DDL and migrations
│   ├── types/
│   │   ├── issue.zig         # Issue struct
│   │   ├── dependency.zig    # Dependency struct
│   │   └── event.zig         # Event/Comment structs
│   ├── graph/
│   │   ├── cycles.zig        # Cycle detection
│   │   └── ready.zig         # Ready work calculation
│   ├── sync/
│   │   ├── safety.zig        # Safety guards
│   │   └── merge.zig         # Merge logic
│   ├── config.zig            # Configuration loading
│   └── idgen.zig             # ID generation
├── vendor/
│   └── sqlite3.c             # Bundled SQLite (optional)
└── tests/
    ├── storage_test.zig
    ├── sync_test.zig
    └── graph_test.zig
```

---

## Migration Path

### Phase 1: Core Storage (1-2 weeks)
- SQLite wrapper with prepared statement caching
- JSONL parser/writer with atomic writes
- Basic CRUD operations

### Phase 2: CLI Framework (1 week)
- Argument parser
- Command dispatch
- Text/JSON output formatting

### Phase 3: Business Logic (1-2 weeks)
- Issue lifecycle commands
- Dependency graph operations
- Ready work calculation
- Full-text search (FTS5)

### Phase 4: Sync & Safety (1 week)
- Sync command with guards
- Backup creation
- Merge conflict detection

### Phase 5: Polish (1 week)
- Configuration system
- Self-update mechanism
- Doctor/diagnostics command
- Test coverage

---

## Key Differences from Rust Version

| Aspect | Rust (br) | Zig (bz) |
|--------|-----------|----------|
| Error handling | `Result<T, E>` + `?` operator | `!T` + `catch` |
| Serialization | Serde derive macros | Manual or comptime codegen |
| SQLite bindings | rusqlite crate | Direct C FFI |
| CLI parsing | clap derive | Hand-rolled (zero deps) |
| String handling | `String` vs `&str` | `[]const u8` everywhere |
| Memory | GC-like Rc/Arc | Explicit allocators |
| Build | Cargo | build.zig |
| Binary size | ~5-8MB | ~500KB-1MB |
| Compile time | ~30-60s debug | ~2-5s debug |

---

## Open Questions

1. **Name**: `bz` (beads-zig)? `zb` (zig-beads)? `bd` (original command)?

2. **SQLite bundling**: Link system SQLite or bundle? Bundling adds ~1MB but ensures consistency.

3. **YAML config**: Keep YAML (requires parser) or switch to TOML/JSON (stdlib)?

4. **Color library**: ANSI codes directly or use a small color library?

5. **Async**: Worth adding async I/O for large repos, or keep it simple/synchronous?

6. **WebAssembly**: Build for WASM to embed in beads_viewer web UI?

---

## Conclusion

A Zig port of beads_rust is highly feasible and aligns well with both projects' philosophies of minimalism and explicitness. The main work is in the SQLite wrapper and JSON serialization since Zig doesn't have Serde equivalents. The payoff is a smaller, faster-compiling binary with explicit memory management.

Estimated total effort: 6-8 weeks for a single developer to reach feature parity.
