//! Manage agent workflow instructions in AGENTS.md or CLAUDE.md.
//!
//! `bz agents`           - Check if blurb is present (default)
//! `bz agents --add`     - Add bz workflow blurb to agent file
//! `bz agents --remove`  - Remove bz blurb from agent file
//! `bz agents --update`  - Replace existing blurb with current version
//! `bz agents --add --force`    - Overwrite existing blurb
//! `bz agents --add --dry-run`  - Show what would happen
//!
//! Compatible with beads_rust `br agents` command.

const std = @import("std");
const args = @import("args.zig");
const output = @import("../output/mod.zig");

const AgentsArgs = args.AgentsArgs;
const GlobalOptions = args.GlobalOptions;

pub const AgentsError = error{
    WorkspaceNotInitialized,
    StorageError,
    AgentNotFound,
    AgentAlreadyExists,
    WriteError,
};

pub const AgentsResult = struct {
    success: bool,
    file: ?[]const u8 = null,
    has_blurb: bool = false,
    message: ?[]const u8 = null,
};

const START_MARKER = "<!-- bz-agent-instructions-v1 -->";
const END_MARKER = "<!-- end-bz-agent-instructions -->";
const LEGACY_BR_START = "<!-- br-agent-instructions-v";
const LEGACY_BR_END = "<!-- end-br-agent-instructions -->";

const SUPPORTED_FILES = [_][]const u8{ "AGENTS.md", "CLAUDE.md", "agents.md", "claude.md" };

const BLURB =
    \\<!-- bz-agent-instructions-v1 -->
    \\
    \\---
    \\
    \\## Beads Workflow Integration
    \\
    \\This project uses [beads_zig](https://github.com/hotschmoe/beads_zig) (`bz`) for issue tracking. Issues are stored in `.beads/` and tracked in git.
    \\
    \\### Essential Commands
    \\
    \\```bash
    \\# View ready issues (unblocked, not deferred)
    \\bz ready
    \\
    \\# List and search
    \\bz list --status open    # All open issues
    \\bz show <id>             # Full issue details with dependencies
    \\bz search "keyword"      # Search issues
    \\
    \\# Create and update
    \\bz create "Title" --type task --priority 2
    \\bz update <id> --status in_progress
    \\bz close <id> --reason "Completed"
    \\
    \\# Sync with git
    \\bz sync --flush-only     # Export DB to JSONL
    \\```
    \\
    \\### Workflow Pattern
    \\
    \\1. **Start**: Run `bz ready` to find actionable work
    \\2. **Claim**: Use `bz update <id> --status in_progress`
    \\3. **Work**: Implement the task
    \\4. **Complete**: Use `bz close <id> --reason "..."`
    \\5. **Sync**: Run `bz sync --flush-only` at session end
    \\
    \\### Key Concepts
    \\
    \\- **Dependencies**: Issues can block other issues. `bz ready` shows only unblocked work.
    \\- **Priority**: 0=critical, 1=high, 2=medium, 3=low, 4=backlog (use numbers, not words)
    \\- **Types**: task, bug, feature, epic, chore, docs, question
    \\- **Blocking**: `bz dep add <issue> <depends-on>` to add dependencies
    \\
    \\### Session Protocol
    \\
    \\Before ending any session, run this checklist:
    \\
    \\```bash
    \\git status              # Check what changed
    \\git add <files>         # Stage code changes
    \\bz sync --flush-only    # Export beads changes to JSONL
    \\git commit -m "..."     # Commit everything
    \\git push                # Push to remote
    \\```
    \\
    \\### Best Practices
    \\
    \\- Check `bz ready` at session start to find available work
    \\- Update status as you work (in_progress -> closed)
    \\- Create new issues with `bz create` when you discover tasks
    \\- Use descriptive titles and set appropriate priority/type
    \\- Always sync before ending session
    \\
    \\<!-- end-bz-agent-instructions -->
;

pub fn run(agents_args: AgentsArgs, global: GlobalOptions, allocator: std.mem.Allocator) AgentsError!void {
    var out = output.Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    switch (agents_args.action) {
        .check => runCheck(&out, global.isStructuredOutput(), allocator),
        .add => runAdd(&out, global.isStructuredOutput(), agents_args.dry_run, agents_args.force, allocator),
        .remove => runRemove(&out, global.isStructuredOutput(), agents_args.dry_run, allocator),
        .update => runAdd(&out, global.isStructuredOutput(), agents_args.dry_run, true, allocator),
    }
}

// ============================================================================
// Actions
// ============================================================================

fn runCheck(out: *output.Output, structured: bool, allocator: std.mem.Allocator) void {
    const detect = detectAgentFile(allocator);

    if (detect.path) |path| {
        defer allocator.free(path);
        const content = readFile(allocator, path) catch {
            emitResult(out, structured, .{ .success = false, .message = "Failed to read file" });
            return;
        };
        defer allocator.free(content);

        const has_bz = std.mem.indexOf(u8, content, START_MARKER) != null;
        const has_br = std.mem.indexOf(u8, content, LEGACY_BR_START) != null;

        if (has_bz) {
            emitResult(out, structured, .{ .success = true, .file = path, .has_blurb = true, .message = "bz workflow instructions present" });
        } else if (has_br) {
            emitResult(out, structured, .{ .success = true, .file = path, .has_blurb = false, .message = "br instructions found (run --update to convert to bz)" });
        } else {
            emitResult(out, structured, .{ .success = true, .file = path, .has_blurb = false, .message = "File exists but no bz instructions. Run 'bz agents --add' to add them." });
        }
    } else {
        emitResult(out, structured, .{ .success = true, .has_blurb = false, .message = "No agent file found. Run 'bz agents --add' to create AGENTS.md." });
    }
}

fn runAdd(out: *output.Output, structured: bool, dry_run: bool, force: bool, allocator: std.mem.Allocator) void {
    const detect = detectAgentFile(allocator);

    // Determine target file
    const target_path: []const u8 = if (detect.path) |p| p else allocator.dupe(u8, "AGENTS.md") catch {
        emitResult(out, structured, .{ .success = false, .message = "Out of memory" });
        return;
    };
    defer allocator.free(target_path);

    // Read existing content (may not exist yet)
    const existing = readFile(allocator, target_path) catch null;
    defer if (existing) |e| allocator.free(e);

    if (existing) |content| {
        const has_bz = std.mem.indexOf(u8, content, START_MARKER) != null;
        const has_br = std.mem.indexOf(u8, content, LEGACY_BR_START) != null;

        if (has_bz and !force) {
            emitResult(out, structured, .{ .success = true, .file = target_path, .has_blurb = true, .message = "bz instructions already present. Use --force to overwrite." });
            return;
        }

        // Build new content: remove old blurb(s), append new one
        const cleaned = blk: {
            var result = removeBlurbFromContent(allocator, content, START_MARKER, END_MARKER) catch {
                emitResult(out, structured, .{ .success = false, .message = "Failed to process file" });
                return;
            };
            if (has_br) {
                const cleaned2 = removeBlurbFromContent(allocator, result, LEGACY_BR_START, LEGACY_BR_END) catch {
                    allocator.free(result);
                    emitResult(out, structured, .{ .success = false, .message = "Failed to process file" });
                    return;
                };
                allocator.free(result);
                result = cleaned2;
            }
            break :blk result;
        };
        defer allocator.free(cleaned);

        // Append blurb
        const new_content = std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ trimTrailingWhitespace(cleaned), BLURB }) catch {
            emitResult(out, structured, .{ .success = false, .message = "Out of memory" });
            return;
        };
        defer allocator.free(new_content);

        if (dry_run) {
            const msg = std.fmt.allocPrint(allocator, "[dry-run] Would write bz instructions to {s}", .{target_path}) catch {
                emitResult(out, structured, .{ .success = true, .file = target_path, .message = "[dry-run] Would write bz instructions" });
                return;
            };
            defer allocator.free(msg);
            emitResult(out, structured, .{ .success = true, .file = target_path, .message = msg });
            return;
        }

        // Backup existing file
        backupFile(allocator, target_path);

        writeFile(target_path, new_content) catch {
            emitResult(out, structured, .{ .success = false, .message = "Failed to write file" });
            return;
        };
    } else {
        // Creating new file
        const new_content = std.fmt.allocPrint(allocator, "# Agent Instructions\n\n{s}\n", .{BLURB}) catch {
            emitResult(out, structured, .{ .success = false, .message = "Out of memory" });
            return;
        };
        defer allocator.free(new_content);

        if (dry_run) {
            const msg = std.fmt.allocPrint(allocator, "[dry-run] Would create {s} with bz instructions", .{target_path}) catch {
                emitResult(out, structured, .{ .success = true, .file = target_path, .message = "[dry-run] Would create file with bz instructions" });
                return;
            };
            defer allocator.free(msg);
            emitResult(out, structured, .{ .success = true, .file = target_path, .message = msg });
            return;
        }

        writeFile(target_path, new_content) catch {
            emitResult(out, structured, .{ .success = false, .message = "Failed to create file" });
            return;
        };
    }

    const msg = std.fmt.allocPrint(allocator, "Added bz workflow instructions to {s}", .{target_path}) catch {
        emitResult(out, structured, .{ .success = true, .file = target_path, .has_blurb = true, .message = "Added bz workflow instructions" });
        return;
    };
    defer allocator.free(msg);
    emitResult(out, structured, .{ .success = true, .file = target_path, .has_blurb = true, .message = msg });
}

fn runRemove(out: *output.Output, structured: bool, dry_run: bool, allocator: std.mem.Allocator) void {
    const detect = detectAgentFile(allocator);
    const path = detect.path orelse {
        emitResult(out, structured, .{ .success = false, .message = "No agent file found" });
        return;
    };
    defer allocator.free(path);

    const content = readFile(allocator, path) catch {
        emitResult(out, structured, .{ .success = false, .message = "Failed to read file" });
        return;
    };
    defer allocator.free(content);

    const has_bz = std.mem.indexOf(u8, content, START_MARKER) != null;
    if (!has_bz) {
        emitResult(out, structured, .{ .success = true, .file = path, .has_blurb = false, .message = "No bz instructions found to remove" });
        return;
    }

    if (dry_run) {
        const msg = std.fmt.allocPrint(allocator, "[dry-run] Would remove bz instructions from {s}", .{path}) catch {
            emitResult(out, structured, .{ .success = true, .file = path, .message = "[dry-run] Would remove bz instructions" });
            return;
        };
        defer allocator.free(msg);
        emitResult(out, structured, .{ .success = true, .file = path, .message = msg });
        return;
    }

    const cleaned = removeBlurbFromContent(allocator, content, START_MARKER, END_MARKER) catch {
        emitResult(out, structured, .{ .success = false, .message = "Failed to process file" });
        return;
    };
    defer allocator.free(cleaned);

    backupFile(allocator, path);

    writeFile(path, cleaned) catch {
        emitResult(out, structured, .{ .success = false, .message = "Failed to write file" });
        return;
    };

    const msg = std.fmt.allocPrint(allocator, "Removed bz instructions from {s}", .{path}) catch {
        emitResult(out, structured, .{ .success = true, .file = path, .has_blurb = false, .message = "Removed bz instructions" });
        return;
    };
    defer allocator.free(msg);
    emitResult(out, structured, .{ .success = true, .file = path, .has_blurb = false, .message = msg });
}

// ============================================================================
// Helpers
// ============================================================================

const DetectResult = struct {
    path: ?[]const u8,
};

fn detectAgentFile(allocator: std.mem.Allocator) DetectResult {
    // Uppercase files first (AGENTS.md, CLAUDE.md), then lowercase
    for (&SUPPORTED_FILES) |filename| {
        if (filename[0] >= 'A' and filename[0] <= 'Z') {
            if (std.fs.cwd().access(filename, .{})) |_| {
                return .{ .path = allocator.dupe(u8, filename) catch null };
            } else |_| {}
        }
    }
    for (&SUPPORTED_FILES) |filename| {
        if (filename[0] >= 'a' and filename[0] <= 'z') {
            if (std.fs.cwd().access(filename, .{})) |_| {
                return .{ .path = allocator.dupe(u8, filename) catch null };
            } else |_| {}
        }
    }
    return .{ .path = null };
}

fn removeBlurbFromContent(allocator: std.mem.Allocator, content: []const u8, start_marker: []const u8, end_marker: []const u8) ![]u8 {
    const start_pos = std.mem.indexOf(u8, content, start_marker) orelse {
        return try allocator.dupe(u8, content);
    };
    const end_pos = std.mem.indexOf(u8, content, end_marker) orelse {
        return try allocator.dupe(u8, content);
    };
    const end = end_pos + end_marker.len;

    // Also consume the --- separator line before the blurb if present
    var actual_start = start_pos;
    if (actual_start >= 4) {
        const before = content[0..actual_start];
        const trimmed = std.mem.trimRight(u8, before, " \t\n\r");
        if (trimmed.len >= 3 and std.mem.endsWith(u8, trimmed, "---")) {
            actual_start = trimmed.len - 3;
        }
    }

    const before = content[0..actual_start];
    const after = if (end < content.len) content[end..] else "";

    return try std.fmt.allocPrint(allocator, "{s}{s}", .{
        trimTrailingWhitespace(before),
        after,
    });
}

fn trimTrailingWhitespace(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, " \t\n\r");
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn backupFile(allocator: std.mem.Allocator, path: []const u8) void {
    const backup_path = std.fmt.allocPrint(allocator, ".{s}.bak", .{path}) catch return;
    defer allocator.free(backup_path);
    std.fs.cwd().copyFile(path, std.fs.cwd(), backup_path, .{}) catch {};
}

fn emitResult(out: *output.Output, structured: bool, result: AgentsResult) void {
    if (structured) {
        out.printJson(result) catch {};
    } else {
        if (result.message) |msg| {
            if (result.success) {
                out.print("{s}\n", .{msg}) catch {};
            } else {
                out.err("{s}", .{msg}) catch {};
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "BLURB has correct markers" {
    try std.testing.expect(std.mem.startsWith(u8, BLURB, START_MARKER));
    try std.testing.expect(std.mem.endsWith(u8, BLURB, END_MARKER));
}

test "BLURB contains bz commands" {
    try std.testing.expect(std.mem.indexOf(u8, BLURB, "bz ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, BLURB, "bz create") != null);
    try std.testing.expect(std.mem.indexOf(u8, BLURB, "bz close") != null);
    try std.testing.expect(std.mem.indexOf(u8, BLURB, "bz sync") != null);
}

test "removeBlurbFromContent removes blurb" {
    const allocator = std.testing.allocator;
    const content = "# Header\n\nSome text\n\n<!-- bz-agent-instructions-v1 -->\nblurb content\n<!-- end-bz-agent-instructions -->\n\nAfter";
    const result = try removeBlurbFromContent(allocator, content, START_MARKER, END_MARKER);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, START_MARKER) == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Header") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "After") != null);
}

test "removeBlurbFromContent returns content unchanged when no marker" {
    const allocator = std.testing.allocator;
    const content = "# Just a normal file\n\nNo blurb here.";
    const result = try removeBlurbFromContent(allocator, content, START_MARKER, END_MARKER);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("# Just a normal file\n\nNo blurb here.", result);
}

test "detectAgentFile returns null when no files exist" {
    // Uses cwd which likely doesn't have AGENTS.md in test env
    // Just verify it doesn't crash
    const allocator = std.testing.allocator;
    const detect = detectAgentFile(allocator);
    if (detect.path) |p| allocator.free(p);
}

test "SUPPORTED_FILES order" {
    try std.testing.expectEqualStrings("AGENTS.md", SUPPORTED_FILES[0]);
    try std.testing.expectEqualStrings("CLAUDE.md", SUPPORTED_FILES[1]);
    try std.testing.expectEqualStrings("agents.md", SUPPORTED_FILES[2]);
    try std.testing.expectEqualStrings("claude.md", SUPPORTED_FILES[3]);
}
