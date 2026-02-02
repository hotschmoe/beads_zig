//! Help command for beads_zig.
//!
//! Provides detailed per-command help with usage examples and flag references.

const std = @import("std");

pub const HelpError = error{
    WriteError,
    OutOfMemory,
};

pub const HelpResult = struct {
    success: bool,
    topic: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// Command metadata for generating help text.
const CommandHelp = struct {
    name: []const u8,
    aliases: []const []const u8 = &[_][]const u8{},
    summary: []const u8,
    usage: []const u8,
    description: []const u8 = "",
    arguments: []const ArgHelp = &[_]ArgHelp{},
    flags: []const FlagHelp = &[_]FlagHelp{},
    examples: []const ExampleHelp = &[_]ExampleHelp{},
    see_also: []const []const u8 = &[_][]const u8{},
};

const ArgHelp = struct {
    name: []const u8,
    description: []const u8,
    required: bool = true,
};

const FlagHelp = struct {
    short: ?[]const u8,
    long: []const u8,
    arg: ?[]const u8 = null,
    description: []const u8,
};

const ExampleHelp = struct {
    command: []const u8,
    description: []const u8,
};

/// All command help definitions.
const commands = [_]CommandHelp{
    // Workspace commands
    .{
        .name = "init",
        .summary = "Initialize a .beads/ workspace",
        .usage = "bz init [--prefix PREFIX]",
        .description = "Creates the .beads/ directory structure for issue tracking. " ++
            "This command must be run before using any other beads commands.",
        .flags = &[_]FlagHelp{
            .{ .short = "-p", .long = "--prefix", .arg = "PREFIX", .description = "Issue ID prefix (default: bd)" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz init", .description = "Initialize with default prefix 'bd'" },
            .{ .command = "bz init --prefix proj", .description = "Use 'proj' as ID prefix (e.g., proj-abc123)" },
        },
    },
    .{
        .name = "info",
        .summary = "Show workspace information",
        .usage = "bz info",
        .description = "Displays current workspace configuration, file locations, and basic status.",
        .examples = &[_]ExampleHelp{
            .{ .command = "bz info", .description = "Show workspace details" },
            .{ .command = "bz info --json", .description = "Output as JSON for scripting" },
        },
    },
    .{
        .name = "stats",
        .summary = "Show project statistics",
        .usage = "bz stats",
        .description = "Shows aggregate statistics about issues: counts by status, priority, type, etc.",
        .examples = &[_]ExampleHelp{
            .{ .command = "bz stats", .description = "Show issue statistics" },
            .{ .command = "bz stats --json", .description = "Output as JSON for dashboards" },
        },
    },
    .{
        .name = "doctor",
        .summary = "Run diagnostic checks",
        .usage = "bz doctor",
        .description = "Checks workspace integrity: validates JSONL format, detects orphaned references, " ++
            "and reports any data consistency issues.",
        .examples = &[_]ExampleHelp{
            .{ .command = "bz doctor", .description = "Run all diagnostic checks" },
        },
    },
    .{
        .name = "config",
        .summary = "Manage configuration",
        .usage = "bz config [get|set|list] [KEY] [VALUE]",
        .description = "View or modify project configuration settings.",
        .arguments = &[_]ArgHelp{
            .{ .name = "subcommand", .description = "get, set, or list (default: list)", .required = false },
            .{ .name = "key", .description = "Configuration key (e.g., id.prefix)", .required = false },
            .{ .name = "value", .description = "New value (for set)", .required = false },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz config", .description = "List all configuration" },
            .{ .command = "bz config list", .description = "Same as above" },
            .{ .command = "bz config get id.prefix", .description = "Get the ID prefix setting" },
            .{ .command = "bz config set defaults.priority 1", .description = "Set default priority to high" },
        },
    },
    .{
        .name = "sync",
        .summary = "Sync with JSONL file",
        .usage = "bz sync [--flush-only] [--import-only] [--status] [--manifest]",
        .description = "Synchronizes in-memory state with the JSONL file. By default, performs " ++
            "bidirectional sync. Use flags to limit to export or import only.",
        .flags = &[_]FlagHelp{
            .{ .short = null, .long = "--flush-only", .description = "Only export (write to JSONL)" },
            .{ .short = null, .long = "--import-only", .description = "Only import (read from JSONL)" },
            .{ .short = "-s", .long = "--status", .description = "Show sync status without changes" },
            .{ .short = null, .long = "--manifest", .description = "Write manifest.json with export metadata" },
            .{ .short = "-m", .long = "--merge", .description = "3-way merge with remote JSONL" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz sync", .description = "Full bidirectional sync" },
            .{ .command = "bz sync --flush-only", .description = "Export changes to JSONL" },
            .{ .command = "bz sync --import-only", .description = "Import changes from JSONL" },
            .{ .command = "bz sync --status", .description = "Show DB/JSONL issue counts" },
            .{ .command = "bz sync --flush-only --manifest", .description = "Export with manifest file" },
        },
        .see_also = &[_][]const u8{ "import", "add-batch" },
    },
    .{
        .name = "orphans",
        .summary = "Find issues with missing parent references",
        .usage = "bz orphans [--limit N] [--hierarchy-only] [--deps-only]",
        .description = "Identifies issues that reference non-existent parent issues or dependencies.",
        .flags = &[_]FlagHelp{
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum results to show" },
            .{ .short = null, .long = "--hierarchy-only", .description = "Only check hierarchical parent refs" },
            .{ .short = null, .long = "--deps-only", .description = "Only check dependency refs" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz orphans", .description = "Find all orphaned references" },
            .{ .command = "bz orphans --limit 10", .description = "Show at most 10 orphans" },
        },
    },
    .{
        .name = "lint",
        .summary = "Validate database consistency",
        .usage = "bz lint [--limit N]",
        .description = "Checks for data quality issues: empty titles, invalid priorities, " ++
            "malformed IDs, and other consistency problems.",
        .flags = &[_]FlagHelp{
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum issues to report" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz lint", .description = "Run all lint checks" },
        },
    },

    // Issue CRUD commands
    .{
        .name = "create",
        .aliases = &[_][]const u8{ "add", "new" },
        .summary = "Create a new issue",
        .usage = "bz create <title> [options]",
        .description = "Creates a new issue with the given title. The issue is assigned a " ++
            "unique ID and added to the database. Use flags to set optional fields.",
        .arguments = &[_]ArgHelp{
            .{ .name = "title", .description = "Issue title (1-500 characters)" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = "-d", .long = "--description", .arg = "TEXT", .description = "Detailed description" },
            .{ .short = "-t", .long = "--type", .arg = "TYPE", .description = "Issue type (task, bug, feature, epic, chore, docs, question)" },
            .{ .short = "-p", .long = "--priority", .arg = "PRIO", .description = "Priority (critical, high, medium, low, backlog, or 0-4)" },
            .{ .short = "-a", .long = "--assignee", .arg = "USER", .description = "Assignee name or email" },
            .{ .short = "-l", .long = "--label", .arg = "LABEL", .description = "Add label (can be repeated)" },
            .{ .short = null, .long = "--depends-on", .arg = "ID", .description = "Add dependency (can be repeated)" },
            .{ .short = null, .long = "--due", .arg = "DATE", .description = "Due date (YYYY-MM-DD)" },
            .{ .short = "-e", .long = "--estimate", .arg = "MINS", .description = "Estimate in minutes" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz create \"Fix login bug\"", .description = "Create a simple issue" },
            .{ .command = "bz create \"Add OAuth\" -t feature -p high", .description = "Create a high-priority feature" },
            .{ .command = "bz create \"Bug fix\" -l urgent -l backend", .description = "Create with multiple labels" },
            .{ .command = "bz create \"Task\" --depends-on bd-abc123", .description = "Create with dependency" },
        },
        .see_also = &[_][]const u8{ "q", "show", "update" },
    },
    .{
        .name = "q",
        .aliases = &[_][]const u8{"quick"},
        .summary = "Quick capture (create + print ID only)",
        .usage = "bz q <title> [-p PRIORITY]",
        .description = "Creates a new issue and prints only the ID. Optimized for scripting " ++
            "and quick capture workflows.",
        .arguments = &[_]ArgHelp{
            .{ .name = "title", .description = "Issue title" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = "-p", .long = "--priority", .arg = "PRIO", .description = "Priority level" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz q \"Quick thought\"", .description = "Capture idea, get ID back" },
            .{ .command = "ID=$(bz q \"Task\"); echo $ID", .description = "Capture ID in shell variable" },
            .{ .command = "bz q \"Urgent fix\" -p critical", .description = "Quick capture with priority" },
        },
        .see_also = &[_][]const u8{ "create", "add-batch" },
    },
    .{
        .name = "show",
        .aliases = &[_][]const u8{ "get", "view" },
        .summary = "Show issue details",
        .usage = "bz show <id> [--no-comments] [--with-history]",
        .description = "Displays full details of an issue including description, status, " ++
            "dependencies, labels, and comments.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID (e.g., bd-abc123)" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = null, .long = "--no-comments", .description = "Hide comments" },
            .{ .short = null, .long = "--with-history", .description = "Include change history" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz show bd-abc123", .description = "Show issue details" },
            .{ .command = "bz show bd-abc --json", .description = "Get issue as JSON" },
            .{ .command = "bz show bd-abc --with-history", .description = "Include change history" },
        },
        .see_also = &[_][]const u8{ "update", "history" },
    },
    .{
        .name = "update",
        .aliases = &[_][]const u8{"edit"},
        .summary = "Update issue fields",
        .usage = "bz update <id> [options]",
        .description = "Modifies one or more fields of an existing issue. Only specified " ++
            "fields are changed; others remain unchanged.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID to update" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = null, .long = "--title", .arg = "TEXT", .description = "New title" },
            .{ .short = "-d", .long = "--description", .arg = "TEXT", .description = "New description" },
            .{ .short = "-t", .long = "--type", .arg = "TYPE", .description = "New issue type" },
            .{ .short = "-p", .long = "--priority", .arg = "PRIO", .description = "New priority" },
            .{ .short = "-a", .long = "--assignee", .arg = "USER", .description = "New assignee" },
            .{ .short = "-s", .long = "--status", .arg = "STATUS", .description = "New status (open, in_progress, blocked, deferred, closed)" },
            .{ .short = "-v", .long = "--version", .arg = "NUM", .description = "Expected version for optimistic locking (fails if issue was modified)" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz update bd-abc --title \"New title\"", .description = "Update title" },
            .{ .command = "bz update bd-abc -p critical -a alice", .description = "Update priority and assignee" },
            .{ .command = "bz update bd-abc -s in_progress", .description = "Change status to in_progress" },
            .{ .command = "bz update bd-abc -v 3 --title \"Safe update\"", .description = "Update only if version is 3 (optimistic lock)" },
        },
        .see_also = &[_][]const u8{ "show", "close" },
    },
    .{
        .name = "close",
        .aliases = &[_][]const u8{ "done", "finish" },
        .summary = "Close an issue",
        .usage = "bz close <id> [-r REASON]",
        .description = "Marks an issue as closed. Optionally provide a close reason.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID to close" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = "-r", .long = "--reason", .arg = "TEXT", .description = "Close reason (e.g., \"Fixed in PR #42\")" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz close bd-abc123", .description = "Close an issue" },
            .{ .command = "bz close bd-abc -r \"Duplicate of bd-xyz\"", .description = "Close with reason" },
            .{ .command = "bz done bd-abc", .description = "Close using alias" },
        },
        .see_also = &[_][]const u8{ "reopen", "delete" },
    },
    .{
        .name = "reopen",
        .summary = "Reopen a closed issue",
        .usage = "bz reopen <id>",
        .description = "Changes a closed issue's status back to open.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID to reopen" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz reopen bd-abc123", .description = "Reopen a closed issue" },
        },
        .see_also = &[_][]const u8{ "close", "update" },
    },
    .{
        .name = "delete",
        .aliases = &[_][]const u8{ "rm", "remove" },
        .summary = "Soft delete an issue (tombstone)",
        .usage = "bz delete <id>",
        .description = "Marks an issue as deleted (tombstone status). The issue remains in " ++
            "the database but is hidden from normal queries. Can be restored via update.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID to delete" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz delete bd-abc123", .description = "Soft delete an issue" },
            .{ .command = "bz rm bd-abc", .description = "Delete using alias" },
        },
        .see_also = &[_][]const u8{"close"},
    },
    .{
        .name = "defer",
        .summary = "Defer an issue",
        .usage = "bz defer <id> [--until DATE] [-r REASON]",
        .description = "Marks an issue as deferred, optionally until a specific date.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID to defer" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = "-u", .long = "--until", .arg = "DATE", .description = "Date to resurface (YYYY-MM-DD or +7d)" },
            .{ .short = "-r", .long = "--reason", .arg = "TEXT", .description = "Reason for deferral" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz defer bd-abc", .description = "Defer indefinitely" },
            .{ .command = "bz defer bd-abc --until 2024-03-01", .description = "Defer until specific date" },
            .{ .command = "bz defer bd-abc --until +7d", .description = "Defer for 7 days" },
        },
        .see_also = &[_][]const u8{"undefer"},
    },
    .{
        .name = "undefer",
        .summary = "Remove deferral from an issue",
        .usage = "bz undefer <id>",
        .description = "Clears the deferred status and defer_until date from an issue.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID to undefer" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz undefer bd-abc123", .description = "Remove deferral" },
        },
        .see_also = &[_][]const u8{"defer"},
    },

    // Batch operations
    .{
        .name = "add-batch",
        .aliases = &[_][]const u8{ "batch-add", "batch" },
        .summary = "Create issues from stdin/file (single lock)",
        .usage = "bz add-batch [-f FILE] [--format FORMAT]",
        .description = "Creates multiple issues efficiently with a single lock acquisition. " ++
            "Reads from stdin or a file. Supports plain titles (one per line) or JSONL format.",
        .flags = &[_]FlagHelp{
            .{ .short = "-f", .long = "--file", .arg = "FILE", .description = "Read from file instead of stdin" },
            .{ .short = null, .long = "--format", .arg = "FMT", .description = "Input format: titles (default) or jsonl" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "echo -e \"Task 1\\nTask 2\" | bz add-batch", .description = "Create from stdin" },
            .{ .command = "bz add-batch -f tasks.txt", .description = "Create from file (one title per line)" },
            .{ .command = "bz add-batch -f issues.jsonl --format jsonl", .description = "Create from JSONL file" },
        },
        .see_also = &[_][]const u8{ "create", "import" },
    },
    .{
        .name = "import",
        .summary = "Import issues from JSONL file",
        .usage = "bz import <file> [-m] [-n]",
        .description = "Imports issues from a JSONL file. Handles deduplication via content hash " ++
            "and external_ref matching.",
        .arguments = &[_]ArgHelp{
            .{ .name = "file", .description = "Path to JSONL file" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = "-m", .long = "--merge", .description = "Merge with existing issues (update if exists)" },
            .{ .short = "-n", .long = "--dry-run", .description = "Show what would be imported without importing" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz import backup.jsonl", .description = "Import from backup" },
            .{ .command = "bz import external.jsonl --merge", .description = "Merge external issues" },
            .{ .command = "bz import data.jsonl --dry-run", .description = "Preview import" },
        },
        .see_also = &[_][]const u8{ "sync", "add-batch" },
    },

    // Query commands
    .{
        .name = "list",
        .aliases = &[_][]const u8{"ls"},
        .summary = "List issues with filters",
        .usage = "bz list [options]",
        .description = "Lists issues matching optional filters. By default shows only open issues. " ++
            "Use --all to include closed/deleted issues.",
        .flags = &[_]FlagHelp{
            .{ .short = "-s", .long = "--status", .arg = "STATUS", .description = "Filter by status" },
            .{ .short = "-p", .long = "--priority", .arg = "PRIO", .description = "Filter by priority" },
            .{ .short = "-t", .long = "--type", .arg = "TYPE", .description = "Filter by issue type" },
            .{ .short = "-a", .long = "--assignee", .arg = "USER", .description = "Filter by assignee" },
            .{ .short = "-l", .long = "--label", .arg = "LABEL", .description = "Filter by label" },
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum results" },
            .{ .short = "-A", .long = "--all", .description = "Include all statuses (not just open)" },
            .{ .short = null, .long = "--sort", .arg = "FIELD", .description = "Sort by: created, updated, or priority" },
            .{ .short = null, .long = "--asc", .description = "Sort ascending" },
            .{ .short = null, .long = "--desc", .description = "Sort descending (default)" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz list", .description = "List open issues" },
            .{ .command = "bz list --all", .description = "List all issues" },
            .{ .command = "bz list -p high -t bug", .description = "High priority bugs" },
            .{ .command = "bz list --sort priority --asc", .description = "Sort by priority ascending" },
            .{ .command = "bz list -l backend -n 5", .description = "Top 5 issues with 'backend' label" },
        },
        .see_also = &[_][]const u8{ "ready", "blocked", "search" },
    },
    .{
        .name = "ready",
        .summary = "Show actionable issues (unblocked)",
        .usage = "bz ready [--limit N]",
        .description = "Lists open issues that have no unresolved blocking dependencies. " ++
            "These are issues ready to be worked on.",
        .flags = &[_]FlagHelp{
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum results" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz ready", .description = "Show all ready issues" },
            .{ .command = "bz ready -n 5", .description = "Show top 5 ready issues" },
            .{ .command = "bz ready --json", .description = "Get ready work as JSON (for agents)" },
        },
        .see_also = &[_][]const u8{ "blocked", "list" },
    },
    .{
        .name = "blocked",
        .summary = "Show blocked issues",
        .usage = "bz blocked [--limit N]",
        .description = "Lists open issues that have unresolved blocking dependencies.",
        .flags = &[_]FlagHelp{
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum results" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz blocked", .description = "Show all blocked issues" },
            .{ .command = "bz blocked --json", .description = "Get blocked issues as JSON" },
        },
        .see_also = &[_][]const u8{ "ready", "dep" },
    },
    .{
        .name = "search",
        .aliases = &[_][]const u8{"find"},
        .summary = "Full-text search",
        .usage = "bz search <query> [--limit N]",
        .description = "Searches issue titles and descriptions for the given query string.",
        .arguments = &[_]ArgHelp{
            .{ .name = "query", .description = "Search string" },
        },
        .flags = &[_]FlagHelp{
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum results" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz search login", .description = "Find issues mentioning 'login'" },
            .{ .command = "bz search \"OAuth flow\" -n 10", .description = "Search with limit" },
        },
        .see_also = &[_][]const u8{"list"},
    },
    .{
        .name = "stale",
        .summary = "Find issues not updated recently",
        .usage = "bz stale [--days N] [--limit N]",
        .description = "Lists open issues that haven't been updated within the specified " ++
            "number of days (default: 30).",
        .flags = &[_]FlagHelp{
            .{ .short = "-d", .long = "--days", .arg = "N", .description = "Days threshold (default: 30)" },
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum results" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz stale", .description = "Issues untouched for 30+ days" },
            .{ .command = "bz stale --days 7", .description = "Issues untouched for 7+ days" },
        },
        .see_also = &[_][]const u8{"list"},
    },
    .{
        .name = "count",
        .summary = "Count issues by group",
        .usage = "bz count [--group-by FIELD]",
        .description = "Counts issues, optionally grouped by a field.",
        .flags = &[_]FlagHelp{
            .{ .short = "-g", .long = "--group-by", .arg = "FIELD", .description = "Group by: status, priority, type, assignee" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz count", .description = "Total issue count" },
            .{ .command = "bz count --group-by status", .description = "Count by status" },
            .{ .command = "bz count -g priority", .description = "Count by priority" },
        },
        .see_also = &[_][]const u8{ "list", "stats" },
    },

    // Dependency commands
    .{
        .name = "dep",
        .aliases = &[_][]const u8{ "deps", "dependency" },
        .summary = "Manage issue dependencies",
        .usage = "bz dep <subcommand> [args]",
        .description = "Add, remove, or query dependencies between issues. " ++
            "Dependencies are directional: A depends-on B means A is blocked by B.",
        .arguments = &[_]ArgHelp{
            .{ .name = "subcommand", .description = "add, remove, list, tree, or cycles" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz dep add bd-child bd-parent", .description = "child depends on parent" },
            .{ .command = "bz dep add bd-a bd-b --type relates_to", .description = "Add non-blocking relation" },
            .{ .command = "bz dep remove bd-child bd-parent", .description = "Remove dependency" },
            .{ .command = "bz dep list bd-abc", .description = "List dependencies of an issue" },
            .{ .command = "bz dep tree bd-abc", .description = "Show dependency tree" },
            .{ .command = "bz dep cycles", .description = "Detect circular dependencies" },
        },
        .see_also = &[_][]const u8{ "graph", "ready", "blocked" },
    },
    .{
        .name = "graph",
        .summary = "Show dependency graph",
        .usage = "bz graph [ID] [--format FMT] [--depth N]",
        .description = "Visualizes the dependency graph. Without an ID, shows all dependencies. " ++
            "With an ID, shows that issue's dependency subgraph.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID (optional, shows all if omitted)", .required = false },
        },
        .flags = &[_]FlagHelp{
            .{ .short = "-f", .long = "--format", .arg = "FMT", .description = "Output format: ascii (default) or dot" },
            .{ .short = "-d", .long = "--depth", .arg = "N", .description = "Maximum tree depth" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz graph", .description = "Show full dependency graph (ASCII)" },
            .{ .command = "bz graph bd-abc", .description = "Show graph for specific issue" },
            .{ .command = "bz graph --format dot | dot -Tpng -o graph.png", .description = "Generate PNG via Graphviz" },
        },
        .see_also = &[_][]const u8{"dep"},
    },

    // Epic commands
    .{
        .name = "epic",
        .aliases = &[_][]const u8{"epics"},
        .summary = "Manage epics",
        .usage = "bz epic <subcommand> [args]",
        .description = "Epics are special issues that group related work. Use epic commands " ++
            "to create epics and manage their child issues.",
        .arguments = &[_]ArgHelp{
            .{ .name = "subcommand", .description = "create, add, remove, or list" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz epic create \"Q1 Goals\"", .description = "Create a new epic" },
            .{ .command = "bz epic create \"Auth Overhaul\" -p high", .description = "Create with priority" },
            .{ .command = "bz epic add bd-epic bd-task", .description = "Add issue to epic" },
            .{ .command = "bz epic remove bd-epic bd-task", .description = "Remove issue from epic" },
            .{ .command = "bz epic list bd-epic", .description = "List issues in epic" },
        },
        .see_also = &[_][]const u8{ "create", "dep" },
    },

    // Label commands
    .{
        .name = "label",
        .aliases = &[_][]const u8{ "labels", "tag" },
        .summary = "Manage issue labels",
        .usage = "bz label <subcommand> [args]",
        .description = "Add, remove, or list labels on issues.",
        .arguments = &[_]ArgHelp{
            .{ .name = "subcommand", .description = "add, remove, list, or list-all" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz label add bd-abc urgent backend", .description = "Add multiple labels" },
            .{ .command = "bz label remove bd-abc old-label", .description = "Remove a label" },
            .{ .command = "bz label list bd-abc", .description = "List labels on issue" },
            .{ .command = "bz label list-all", .description = "List all labels in project" },
        },
        .see_also = &[_][]const u8{ "list", "create" },
    },

    // Comment commands
    .{
        .name = "comments",
        .aliases = &[_][]const u8{ "comment", "note" },
        .summary = "Manage issue comments",
        .usage = "bz comments <subcommand> <id> [text]",
        .description = "Add or list comments on issues.",
        .arguments = &[_]ArgHelp{
            .{ .name = "subcommand", .description = "add or list" },
            .{ .name = "id", .description = "Issue ID" },
            .{ .name = "text", .description = "Comment text (for add)", .required = false },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz comments add bd-abc \"Working on this\"", .description = "Add a comment" },
            .{ .command = "bz comments list bd-abc", .description = "List comments" },
        },
        .see_also = &[_][]const u8{ "show", "history" },
    },

    // Audit commands
    .{
        .name = "history",
        .aliases = &[_][]const u8{"log"},
        .summary = "Show issue history",
        .usage = "bz history <id>",
        .description = "Displays the change history for a specific issue.",
        .arguments = &[_]ArgHelp{
            .{ .name = "id", .description = "Issue ID" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz history bd-abc123", .description = "Show change history" },
        },
        .see_also = &[_][]const u8{ "show", "audit" },
    },
    .{
        .name = "audit",
        .summary = "Project-wide audit log",
        .usage = "bz audit [--limit N]",
        .description = "Shows recent events across all issues.",
        .flags = &[_]FlagHelp{
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum events" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz audit", .description = "Show recent events" },
            .{ .command = "bz audit --limit 100", .description = "Show last 100 events" },
        },
        .see_also = &[_][]const u8{ "history", "changelog" },
    },
    .{
        .name = "changelog",
        .summary = "Generate changelog from closed issues",
        .usage = "bz changelog [--since DATE] [--until DATE] [--limit N] [--group-by FIELD]",
        .description = "Generates a changelog from recently closed issues, optionally filtered " ++
            "by date range and grouped by type.",
        .flags = &[_]FlagHelp{
            .{ .short = null, .long = "--since", .arg = "DATE", .description = "Start date (YYYY-MM-DD)" },
            .{ .short = null, .long = "--until", .arg = "DATE", .description = "End date (YYYY-MM-DD)" },
            .{ .short = "-n", .long = "--limit", .arg = "N", .description = "Maximum entries" },
            .{ .short = "-g", .long = "--group-by", .arg = "FIELD", .description = "Group by field (e.g., type)" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz changelog", .description = "Generate changelog" },
            .{ .command = "bz changelog --since 2024-01-01", .description = "Since specific date" },
            .{ .command = "bz changelog --group-by type", .description = "Group by issue type" },
        },
        .see_also = &[_][]const u8{"audit"},
    },

    // System commands
    .{
        .name = "version",
        .summary = "Show version",
        .usage = "bz version",
        .description = "Displays the beads_zig version and build information.",
        .examples = &[_]ExampleHelp{
            .{ .command = "bz version", .description = "Show version" },
            .{ .command = "bz --version", .description = "Same (alternate form)" },
        },
    },
    .{
        .name = "schema",
        .summary = "Show data schema",
        .usage = "bz schema",
        .description = "Displays the JSONL data schema for issues and related types.",
        .examples = &[_]ExampleHelp{
            .{ .command = "bz schema", .description = "Show schema documentation" },
        },
    },
    .{
        .name = "completions",
        .aliases = &[_][]const u8{"completion"},
        .summary = "Generate shell completions",
        .usage = "bz completions <shell>",
        .description = "Generates shell completion scripts for bash, zsh, fish, or powershell.",
        .arguments = &[_]ArgHelp{
            .{ .name = "shell", .description = "Shell type: bash, zsh, fish, or powershell" },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz completions bash >> ~/.bashrc", .description = "Add bash completions" },
            .{ .command = "bz completions zsh > ~/.zsh/completions/_bz", .description = "Install zsh completions" },
            .{ .command = "bz completions fish > ~/.config/fish/completions/bz.fish", .description = "Install fish completions" },
        },
    },
    .{
        .name = "help",
        .summary = "Show help",
        .usage = "bz help [command]",
        .description = "Shows general help or detailed help for a specific command.",
        .arguments = &[_]ArgHelp{
            .{ .name = "command", .description = "Command to get help for", .required = false },
        },
        .examples = &[_]ExampleHelp{
            .{ .command = "bz help", .description = "Show general help" },
            .{ .command = "bz help create", .description = "Show help for create command" },
            .{ .command = "bz --help", .description = "Same as bz help" },
        },
    },
};

/// Find help for a specific command (including aliases).
fn findCommand(name: []const u8) ?*const CommandHelp {
    for (&commands) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            return cmd;
        }
        for (cmd.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) {
                return cmd;
            }
        }
    }
    return null;
}

/// Run the help command.
pub fn run(topic: ?[]const u8, allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();
    if (topic) |t| {
        try showCommandHelp(t, stdout, allocator);
    } else {
        try showGeneralHelp(stdout);
    }
}

fn showGeneralHelp(file: std.fs.File) !void {
    try file.writeAll(
        \\bz - beads_zig issue tracker
        \\
        \\USAGE:
        \\  bz <command> [options]
        \\
        \\COMMANDS:
        \\  Workspace:
        \\    init              Initialize .beads/ workspace
        \\    info              Show workspace information
        \\    stats             Show project statistics
        \\    doctor            Run diagnostic checks
        \\    config            Manage configuration
        \\    sync              Sync with JSONL file
        \\    orphans           Find issues with missing parent refs
        \\    lint              Validate database consistency
        \\
        \\  Issue Management:
        \\    create <title>    Create new issue
        \\    q <title>         Quick capture (create + print ID only)
        \\    show <id>         Show issue details
        \\    update <id>       Update issue fields
        \\    close <id>        Close an issue
        \\    reopen <id>       Reopen a closed issue
        \\    delete <id>       Soft delete (tombstone)
        \\    defer <id>        Defer an issue
        \\    undefer <id>      Remove deferral from an issue
        \\
        \\  Batch Operations:
        \\    add-batch         Create issues from stdin/file (single lock)
        \\    import <file>     Import issues from JSONL file
        \\
        \\  Queries:
        \\    list              List issues (--sort created|updated|priority, --asc/--desc)
        \\    ready             Show actionable issues (unblocked)
        \\    blocked           Show blocked issues
        \\    search <query>    Full-text search
        \\    stale [--days N]  Find issues not updated recently
        \\    count [--group-by] Count issues by group
        \\
        \\  Dependencies:
        \\    dep add <a> <b>   Make issue A depend on B
        \\    dep remove <a> <b> Remove dependency
        \\    dep list <id>     List dependencies
        \\    dep tree <id>     Show dependency tree (ASCII)
        \\    dep cycles        Detect dependency cycles
        \\    graph [id]        Show dependency graph (ASCII/DOT)
        \\
        \\  Epics:
        \\    epic create <title>       Create a new epic
        \\    epic add <epic> <issue>   Add issue to epic
        \\    epic remove <epic> <issue> Remove issue from epic
        \\    epic list <epic>          List issues in epic
        \\
        \\  Labels:
        \\    label add <id> <labels...>    Add labels to an issue
        \\    label remove <id> <labels...> Remove labels from an issue
        \\    label list <id>               List labels on an issue
        \\    label list-all                List all labels in project
        \\
        \\  Comments:
        \\    comments add <id> <text>  Add comment to an issue
        \\    comments list <id>        List comments on an issue
        \\
        \\  Audit:
        \\    history <id>      Show issue history
        \\    audit             Project-wide audit log
        \\    changelog         Generate changelog from closed issues
        \\
        \\  System:
        \\    help              Show this help
        \\    version           Show version
        \\    schema            Show data schema
        \\    completions <shell>  Generate shell completions
        \\
        \\GLOBAL OPTIONS:
        \\  --json            Output in JSON format
        \\  --toon            Output in TOON format (LLM-optimized)
        \\  -q, --quiet       Suppress non-essential output
        \\  -v, --verbose     Increase verbosity
        \\  --no-color        Disable colors
        \\  --data <path>     Override .beads/ directory
        \\  --actor <name>    Override actor name for audit
        \\  --no-auto-flush   Skip automatic JSONL export
        \\  --no-auto-import  Skip JSONL freshness check
        \\
        \\Run 'bz help <command>' for command-specific help.
        \\
    );
}

fn showCommandHelp(name: []const u8, file: std.fs.File, allocator: std.mem.Allocator) !void {
    const cmd = findCommand(name) orelse {
        const msg = try std.fmt.allocPrint(allocator, "Unknown command: {s}\n\n", .{name});
        defer allocator.free(msg);
        try file.writeAll(msg);
        try file.writeAll("Run 'bz help' for a list of available commands.\n");
        return;
    };

    // Command name and aliases
    try file.writeAll(cmd.name);
    if (cmd.aliases.len > 0) {
        try file.writeAll(" (");
        for (cmd.aliases, 0..) |alias, i| {
            if (i > 0) try file.writeAll(", ");
            try file.writeAll(alias);
        }
        try file.writeAll(")");
    }
    try file.writeAll("\n");

    // Summary
    try file.writeAll("\n");
    try file.writeAll(cmd.summary);
    try file.writeAll("\n");

    // Usage
    try file.writeAll("\nUSAGE:\n  ");
    try file.writeAll(cmd.usage);
    try file.writeAll("\n");

    // Description
    if (cmd.description.len > 0) {
        try file.writeAll("\nDESCRIPTION:\n");
        try writeWrapped(file, cmd.description, 2, 78, allocator);
    }

    // Arguments
    if (cmd.arguments.len > 0) {
        try file.writeAll("\nARGUMENTS:\n");
        for (cmd.arguments) |arg| {
            const req = if (arg.required) " (required)" else " (optional)";
            const line = try std.fmt.allocPrint(allocator, "  {s}{s}\n", .{ arg.name, req });
            defer allocator.free(line);
            try file.writeAll(line);
            const desc = try std.fmt.allocPrint(allocator, "      {s}\n", .{arg.description});
            defer allocator.free(desc);
            try file.writeAll(desc);
        }
    }

    // Flags
    if (cmd.flags.len > 0) {
        try file.writeAll("\nFLAGS:\n");
        for (cmd.flags) |flag| {
            if (flag.short) |short| {
                const line = try std.fmt.allocPrint(allocator, "  {s}, {s}", .{ short, flag.long });
                defer allocator.free(line);
                try file.writeAll(line);
            } else {
                const line = try std.fmt.allocPrint(allocator, "      {s}", .{flag.long});
                defer allocator.free(line);
                try file.writeAll(line);
            }
            if (flag.arg) |arg| {
                const argline = try std.fmt.allocPrint(allocator, " <{s}>", .{arg});
                defer allocator.free(argline);
                try file.writeAll(argline);
            }
            try file.writeAll("\n");
            const desc = try std.fmt.allocPrint(allocator, "      {s}\n", .{flag.description});
            defer allocator.free(desc);
            try file.writeAll(desc);
        }
    }

    // Examples
    if (cmd.examples.len > 0) {
        try file.writeAll("\nEXAMPLES:\n");
        for (cmd.examples) |ex| {
            const cmd_line = try std.fmt.allocPrint(allocator, "  $ {s}\n", .{ex.command});
            defer allocator.free(cmd_line);
            try file.writeAll(cmd_line);
            const desc_line = try std.fmt.allocPrint(allocator, "    {s}\n\n", .{ex.description});
            defer allocator.free(desc_line);
            try file.writeAll(desc_line);
        }
    }

    // See also
    if (cmd.see_also.len > 0) {
        try file.writeAll("SEE ALSO:\n  ");
        for (cmd.see_also, 0..) |ref, i| {
            if (i > 0) try file.writeAll(", ");
            try file.writeAll(ref);
        }
        try file.writeAll("\n");
    }
}

/// Write text with word wrapping.
fn writeWrapped(file: std.fs.File, text: []const u8, indent: usize, max_width: usize, allocator: std.mem.Allocator) !void {
    const effective_width = max_width - indent;

    // Pre-allocate indent string
    const indent_str = try allocator.alloc(u8, indent);
    defer allocator.free(indent_str);
    @memset(indent_str, ' ');

    var line_start: usize = 0;
    var last_space: ?usize = null;
    var col: usize = 0;

    for (text, 0..) |c, i| {
        if (c == ' ') {
            last_space = i;
        }
        col += 1;

        if (col >= effective_width) {
            const break_at = last_space orelse i;
            try file.writeAll(indent_str);
            try file.writeAll(text[line_start..break_at]);
            try file.writeAll("\n");

            line_start = break_at + 1;
            col = i - break_at;
            last_space = null;
        }
    }

    if (line_start < text.len) {
        try file.writeAll(indent_str);
        try file.writeAll(text[line_start..]);
        try file.writeAll("\n");
    }
}

// Tests

test "findCommand finds by name" {
    const cmd = findCommand("create");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("create", cmd.?.name);
}

test "findCommand finds by alias" {
    const cmd = findCommand("add");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("create", cmd.?.name);
}

test "findCommand returns null for unknown" {
    const cmd = findCommand("nonexistent");
    try std.testing.expect(cmd == null);
}

test "findCommand finds all main commands" {
    // Verify a sampling of commands can be found
    try std.testing.expect(findCommand("init") != null);
    try std.testing.expect(findCommand("list") != null);
    try std.testing.expect(findCommand("show") != null);
    try std.testing.expect(findCommand("update") != null);
    try std.testing.expect(findCommand("close") != null);
    try std.testing.expect(findCommand("dep") != null);
    try std.testing.expect(findCommand("help") != null);
}

test "findCommand finds aliases" {
    // Test common aliases
    try std.testing.expect(findCommand("ls") != null);
    try std.testing.expectEqualStrings("list", findCommand("ls").?.name);

    try std.testing.expect(findCommand("rm") != null);
    try std.testing.expectEqualStrings("delete", findCommand("rm").?.name);

    try std.testing.expect(findCommand("done") != null);
    try std.testing.expectEqualStrings("close", findCommand("done").?.name);
}
