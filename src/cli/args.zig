//! CLI argument parsing for beads_zig.
//!
//! Parses command-line arguments into structured data for command dispatch.
//! Supports global flags, subcommands, and subcommand-specific arguments.

const std = @import("std");

/// Global CLI options that apply to all commands.
pub const GlobalOptions = struct {
    json: bool = false,
    toon: bool = false,
    robot: bool = false, // Line-oriented machine-readable output for scripting
    quiet: bool = false,
    silent: bool = false, // Suppress ALL output including errors (for tests)
    verbose: u8 = 0,
    no_color: bool = false,
    wrap: bool = false, // Wrap long lines in plain text output
    stats: bool = false, // Show token savings stats for TOON output
    data_path: ?[]const u8 = null,
    actor: ?[]const u8 = null,
    lock_timeout: u32 = 5000,
    no_auto_flush: bool = false,
    no_auto_import: bool = false,

    /// Returns true if structured output (JSON or TOON) is enabled.
    pub fn isStructuredOutput(self: GlobalOptions) bool {
        return self.json or self.toon;
    }

    /// Returns true if any machine-readable output is enabled.
    pub fn isMachineOutput(self: GlobalOptions) bool {
        return self.json or self.toon or self.robot;
    }
};

/// All available subcommands.
pub const Command = union(enum) {
    // Workspace
    init: InitArgs,
    info: void,
    stats: StatsArgs,
    doctor: void,
    config: ConfigArgs,
    orphans: OrphansArgs,
    lint: LintArgs,
    where: void,

    // Issue CRUD
    create: CreateArgs,
    q: QuickArgs,
    show: ShowArgs,
    update: UpdateArgs,
    close: CloseArgs,
    reopen: ReopenArgs,
    delete: DeleteArgs,

    // Batch Operations
    add_batch: AddBatchArgs,
    import_cmd: ImportArgs,

    // Query
    list: ListArgs,
    ready: ReadyArgs,
    blocked: BlockedArgs,
    search: SearchArgs,
    stale: StaleArgs,
    count: CountArgs,
    defer_cmd: DeferArgs,
    undefer: UndeferArgs,

    // Dependencies
    dep: DepArgs,
    graph: GraphArgs,

    // Epics
    epic: EpicArgs,

    // Labels
    label: LabelArgs,

    // Comments
    comments: CommentsArgs,

    // Audit
    history: HistoryArgs,
    audit: AuditArgs,

    // Changelog
    changelog: ChangelogArgs,

    // Sync
    sync: SyncArgs,

    // Backup
    backup: BackupArgs,

    // System
    version: void,
    schema: void,
    completions: CompletionsArgs,
    metrics: MetricsArgs,

    // Saved Queries
    query: QueryArgs,

    // Self-upgrade
    upgrade: UpgradeArgs,

    // Help
    help: HelpArgs,
};

/// Init command arguments.
pub const InitArgs = struct {
    prefix: []const u8 = "bd",
};

/// Stats command arguments.
pub const StatsArgs = struct {
    activity: bool = false, // Show git-based activity statistics
    activity_hours: u32 = 24, // Hours to look back for activity stats (default 24)
};

/// Create command arguments.
pub const CreateArgs = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    design: ?[]const u8 = null,
    acceptance_criteria: ?[]const u8 = null,
    external_ref: ?[]const u8 = null,
    labels: []const []const u8 = &[_][]const u8{},
    deps: []const []const u8 = &[_][]const u8{},
    due: ?[]const u8 = null,
    estimate: ?i32 = null,
    ephemeral: bool = false, // Local-only, not written to JSONL
    dry_run: bool = false, // Preview issue creation without persisting
};

/// Quick capture command arguments.
pub const QuickArgs = struct {
    title: []const u8,
    priority: ?[]const u8 = null,
};

/// Show command arguments.
pub const ShowArgs = struct {
    id: []const u8,
    with_comments: bool = true,
    with_history: bool = false,
};

/// Update command arguments.
pub const UpdateArgs = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    design: ?[]const u8 = null,
    acceptance_criteria: ?[]const u8 = null,
    external_ref: ?[]const u8 = null,
    status: ?[]const u8 = null,
    /// Expected version for optimistic locking (compare-and-swap).
    expected_version: ?u64 = null,
    /// Claim: set assignee to actor AND status to in_progress atomically.
    claim: bool = false,
};

/// Close command arguments.
pub const CloseArgs = struct {
    id: []const u8,
    reason: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

/// Reopen command arguments.
pub const ReopenArgs = struct {
    id: []const u8,
};

/// Delete command arguments.
pub const DeleteArgs = struct {
    /// Single issue ID to delete (mutually exclusive with from_file).
    id: ?[]const u8 = null,
    /// Path to file containing issue IDs to delete (one per line).
    from_file: ?[]const u8 = null,
    /// Delete issue and all its dependents recursively.
    cascade: bool = false,
    /// Prune from database immediately instead of marking as tombstone.
    hard: bool = false,
    /// Preview what would be deleted without making changes.
    dry_run: bool = false,
};

/// Add-batch command arguments.
/// Creates multiple issues from stdin or a file with single lock acquisition.
pub const AddBatchArgs = struct {
    file: ?[]const u8 = null, // Read from file instead of stdin
    format: BatchFormat = .titles, // Input format
};

/// Batch input format.
pub const BatchFormat = enum {
    titles, // One title per line
    jsonl, // Full JSONL format (one issue per line)

    pub fn fromString(s: []const u8) ?BatchFormat {
        if (std.ascii.eqlIgnoreCase(s, "titles")) return .titles;
        if (std.ascii.eqlIgnoreCase(s, "jsonl")) return .jsonl;
        if (std.ascii.eqlIgnoreCase(s, "json")) return .jsonl;
        return null;
    }
};

/// Import command arguments.
/// Imports issues from a JSONL file with single lock acquisition.
pub const ImportArgs = struct {
    file: []const u8, // Path to JSONL file (required)
    merge: bool = false, // Merge instead of replace
    dry_run: bool = false, // Show what would be imported without importing
};

/// Output format for list/ready commands.
pub const OutputFormat = enum {
    default,
    csv,

    pub fn fromString(s: []const u8) ?OutputFormat {
        if (std.ascii.eqlIgnoreCase(s, "default") or std.ascii.eqlIgnoreCase(s, "plain")) return .default;
        if (std.ascii.eqlIgnoreCase(s, "csv")) return .csv;
        return null;
    }
};

/// Sort field options for list command.
pub const SortField = enum {
    created_at,
    updated_at,
    priority,

    pub fn fromString(s: []const u8) ?SortField {
        if (std.ascii.eqlIgnoreCase(s, "created") or std.ascii.eqlIgnoreCase(s, "created_at")) return .created_at;
        if (std.ascii.eqlIgnoreCase(s, "updated") or std.ascii.eqlIgnoreCase(s, "updated_at")) return .updated_at;
        if (std.ascii.eqlIgnoreCase(s, "priority")) return .priority;
        return null;
    }
};

/// List command arguments.
pub const ListArgs = struct {
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    priority_min: ?[]const u8 = null,
    priority_max: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    label: ?[]const u8 = null,
    label_any: []const []const u8 = &[_][]const u8{},
    title_contains: ?[]const u8 = null,
    desc_contains: ?[]const u8 = null,
    notes_contains: ?[]const u8 = null,
    limit: ?u32 = null,
    all: bool = false,
    overdue: bool = false,
    include_deferred: bool = false,
    sort: SortField = .created_at,
    sort_desc: bool = true,
    parent: ?[]const u8 = null,
    recursive: bool = false,
    format: OutputFormat = .default,
    fields: ?[]const u8 = null,
};

/// Ready command arguments.
pub const ReadyArgs = struct {
    limit: ?u32 = null,
    priority_min: ?[]const u8 = null,
    priority_max: ?[]const u8 = null,
    title_contains: ?[]const u8 = null,
    desc_contains: ?[]const u8 = null,
    notes_contains: ?[]const u8 = null,
    overdue: bool = false,
    include_deferred: bool = false,
    parent: ?[]const u8 = null,
    recursive: bool = false,
    format: OutputFormat = .default,
    fields: ?[]const u8 = null,
};

/// Blocked command arguments.
pub const BlockedArgs = struct {
    limit: ?u32 = null,
    priority_min: ?[]const u8 = null,
    priority_max: ?[]const u8 = null,
    title_contains: ?[]const u8 = null,
    desc_contains: ?[]const u8 = null,
    notes_contains: ?[]const u8 = null,
};

/// Search command arguments.
pub const SearchArgs = struct {
    query: []const u8,
    limit: ?u32 = null,
};

/// Stale command arguments.
pub const StaleArgs = struct {
    days: u32 = 30,
    limit: ?u32 = null,
};

/// Count command arguments.
pub const CountArgs = struct {
    group_by: ?[]const u8 = null,
};

/// Defer command arguments.
pub const DeferArgs = struct {
    id: []const u8,
    until: ?[]const u8 = null, // RFC3339 date or relative like "+7d"
    reason: ?[]const u8 = null,
};

/// Undefer command arguments.
pub const UndeferArgs = struct {
    id: []const u8,
};

/// Epic subcommand variants.
pub const EpicSubcommand = union(enum) {
    create: struct {
        title: []const u8,
        description: ?[]const u8 = null,
        priority: ?[]const u8 = null,
    },
    add: struct {
        epic_id: []const u8,
        issue_id: []const u8,
    },
    remove: struct {
        epic_id: []const u8,
        issue_id: []const u8,
    },
    list: struct {
        epic_id: []const u8,
    },
    status: void,
    close_eligible: struct {
        dry_run: bool = false,
    },
};

/// Epic command arguments.
pub const EpicArgs = struct {
    subcommand: EpicSubcommand,
};

/// Direction filter for dependency listing.
pub const DepDirection = enum {
    up, // What depends on this issue (dependents/blocked-by)
    down, // What this issue depends on
    both, // Both directions (default)

    pub fn fromString(s: []const u8) ?DepDirection {
        if (std.ascii.eqlIgnoreCase(s, "up")) return .up;
        if (std.ascii.eqlIgnoreCase(s, "down")) return .down;
        if (std.ascii.eqlIgnoreCase(s, "both")) return .both;
        return null;
    }
};

/// Tree output formats for dep tree.
pub const TreeFormat = enum {
    ascii,
    mermaid,

    pub fn fromString(s: []const u8) ?TreeFormat {
        if (std.ascii.eqlIgnoreCase(s, "ascii")) return .ascii;
        if (std.ascii.eqlIgnoreCase(s, "mermaid")) return .mermaid;
        return null;
    }
};

/// Dependency subcommand variants.
pub const DepSubcommand = union(enum) {
    add: struct {
        child: []const u8,
        parent: []const u8,
        dep_type: []const u8 = "blocks",
        metadata: ?[]const u8 = null,
    },
    remove: struct {
        child: []const u8,
        parent: []const u8,
    },
    list: struct {
        id: []const u8,
        direction: DepDirection = .both,
    },
    tree: struct {
        id: []const u8,
        format: TreeFormat = .ascii,
    },
    cycles: void,
};

/// Dependency command arguments.
pub const DepArgs = struct {
    subcommand: DepSubcommand,
};

/// Graph command output formats.
pub const GraphFormat = enum {
    ascii,
    dot,

    pub fn fromString(s: []const u8) ?GraphFormat {
        if (std.ascii.eqlIgnoreCase(s, "ascii")) return .ascii;
        if (std.ascii.eqlIgnoreCase(s, "dot")) return .dot;
        if (std.ascii.eqlIgnoreCase(s, "graphviz")) return .dot;
        return null;
    }
};

/// Graph command arguments.
pub const GraphArgs = struct {
    id: ?[]const u8 = null, // Optional: show graph for specific issue, otherwise show all
    format: GraphFormat = .ascii,
    depth: ?u32 = null, // Max depth for tree traversal
    all: bool = false, // Show dependency graph for all open issues
    compact: bool = false, // Compact one-line-per-issue output
};

/// Label subcommand variants.
pub const LabelSubcommand = union(enum) {
    add: struct {
        id: []const u8,
        labels: []const []const u8,
    },
    remove: struct {
        id: []const u8,
        labels: []const []const u8,
    },
    list: struct {
        id: []const u8,
    },
    list_all: void,
    rename: struct {
        old_name: []const u8,
        new_name: []const u8,
    },
};

/// Label command arguments.
pub const LabelArgs = struct {
    subcommand: LabelSubcommand,
};

/// Comments subcommand variants.
pub const CommentsSubcommand = union(enum) {
    add: struct {
        id: []const u8,
        text: []const u8,
    },
    list: struct {
        id: []const u8,
    },
};

/// Comments command arguments.
pub const CommentsArgs = struct {
    subcommand: CommentsSubcommand,
};

/// History command arguments.
pub const HistoryArgs = struct {
    id: []const u8,
};

/// Audit subcommand variants.
pub const AuditSubcommand = union(enum) {
    /// Record an LLM/tool interaction for training data.
    record: struct {
        kind: []const u8, // "llm_call" or "tool_call"
        issue_id: ?[]const u8 = null, // Optional issue context
        model: ?[]const u8 = null, // Model name (for llm_call)
        prompt: ?[]const u8 = null, // Input prompt (for llm_call)
        response: ?[]const u8 = null, // Output response (for llm_call)
        tool_name: ?[]const u8 = null, // Tool name (for tool_call)
        exit_code: ?i32 = null, // Exit code (for tool_call)
        metadata: ?[]const u8 = null, // Additional JSON metadata
    },
    /// Label an audit entry for quality tracking.
    label: struct {
        entry_id: i64, // Event ID to label
        label_value: []const u8, // e.g., "good", "bad", "neutral"
        reason: ?[]const u8 = null, // Explanation for the label
    },
    /// View audit log for a specific issue.
    log: struct {
        issue_id: []const u8,
        limit: ?u32 = null,
    },
    /// Summary of audit data over time period.
    summary: struct {
        days: u32 = 7, // Number of days to summarize
    },
    /// Legacy: show project-wide audit log (default behavior).
    list: struct {
        limit: ?u32 = null,
    },
};

/// Audit command arguments.
pub const AuditArgs = struct {
    subcommand: AuditSubcommand,
};

/// Changelog command arguments.
pub const ChangelogArgs = struct {
    since: ?[]const u8 = null, // Start date filter (YYYY-MM-DD)
    until: ?[]const u8 = null, // End date filter (YYYY-MM-DD)
    since_tag: ?[]const u8 = null, // Git tag for start date (e.g., "v1.0.0")
    since_commit: ?[]const u8 = null, // Git commit for start date (e.g., "abc123")
    limit: ?u32 = null,
    group_by: ?[]const u8 = null, // Group by field (e.g., "type")
};

/// Error policy for export operations.
pub const ErrorPolicy = enum {
    strict, // Fail on any error
    best_effort, // Continue on errors, report at end
    partial, // Export what we can, skip errors silently

    pub fn fromString(s: []const u8) ?ErrorPolicy {
        if (std.ascii.eqlIgnoreCase(s, "strict")) return .strict;
        if (std.ascii.eqlIgnoreCase(s, "best-effort") or std.ascii.eqlIgnoreCase(s, "best_effort")) return .best_effort;
        if (std.ascii.eqlIgnoreCase(s, "partial")) return .partial;
        return null;
    }
};

/// Orphan handling policy for import operations.
pub const OrphanPolicy = enum {
    strict, // Fail if orphans detected
    resurrect, // Create placeholder parents for orphans
    skip, // Skip orphaned issues silently

    pub fn fromString(s: []const u8) ?OrphanPolicy {
        if (std.ascii.eqlIgnoreCase(s, "strict")) return .strict;
        if (std.ascii.eqlIgnoreCase(s, "resurrect")) return .resurrect;
        if (std.ascii.eqlIgnoreCase(s, "skip")) return .skip;
        return null;
    }
};

/// Sync command arguments.
pub const SyncArgs = struct {
    flush_only: bool = false,
    import_only: bool = false,
    merge: bool = false,
    status: bool = false,
    manifest: bool = false,
    error_policy: ErrorPolicy = .strict,
    orphan_policy: OrphanPolicy = .strict,
    rename_prefix: bool = false,
};

/// Backup subcommand variants.
pub const BackupSubcommand = union(enum) {
    list: void,
    diff: struct {
        file: []const u8,
    },
    restore: struct {
        file: []const u8,
        dry_run: bool = false,
    },
    prune: struct {
        keep: u32 = 10,
        dry_run: bool = false,
    },
    create: void,
};

/// Backup command arguments.
pub const BackupArgs = struct {
    subcommand: BackupSubcommand,
};

/// Shell completion types.
pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,

    pub fn fromString(s: []const u8) ?Shell {
        if (std.ascii.eqlIgnoreCase(s, "bash")) return .bash;
        if (std.ascii.eqlIgnoreCase(s, "zsh")) return .zsh;
        if (std.ascii.eqlIgnoreCase(s, "fish")) return .fish;
        if (std.ascii.eqlIgnoreCase(s, "powershell")) return .powershell;
        if (std.ascii.eqlIgnoreCase(s, "ps")) return .powershell;
        return null;
    }
};

/// Completions command arguments.
pub const CompletionsArgs = struct {
    shell: Shell,
};

/// Metrics command arguments.
pub const MetricsArgs = struct {
    reset: bool = false, // Reset metrics after displaying
};

/// Help command arguments.
pub const HelpArgs = struct {
    topic: ?[]const u8 = null,
};

/// Config subcommand variants.
pub const ConfigSubcommand = union(enum) {
    get: struct {
        key: []const u8,
    },
    set: struct {
        key: []const u8,
        value: []const u8,
    },
    list: void,
};

/// Config command arguments.
pub const ConfigArgs = struct {
    subcommand: ConfigSubcommand,
};

/// Query subcommand variants.
pub const QuerySubcommand = union(enum) {
    save: struct {
        name: []const u8,
        status: ?[]const u8 = null,
        priority: ?[]const u8 = null,
        issue_type: ?[]const u8 = null,
        assignee: ?[]const u8 = null,
        label: ?[]const u8 = null,
        limit: ?u32 = null,
    },
    run: struct {
        name: []const u8,
    },
    list: void,
    delete: struct {
        name: []const u8,
    },
};

/// Query command arguments.
pub const QueryArgs = struct {
    subcommand: QuerySubcommand,
};

/// Upgrade command arguments.
pub const UpgradeArgs = struct {
    check_only: bool = false,
    dry_run: bool = false, // Show what would be updated without installing
    version: ?[]const u8 = null,
    verify: bool = true, // Verify checksum (default: on)
    force: bool = false, // Force upgrade even if same version
};

/// Orphans command arguments.
pub const OrphansArgs = struct {
    limit: ?u32 = null,
    hierarchy_only: bool = false,
    deps_only: bool = false,
};

/// Lint command arguments.
pub const LintArgs = struct {
    limit: ?u32 = null,
};

/// Result of parsing command-line arguments.
pub const ParseResult = struct {
    global: GlobalOptions,
    command: Command,

    /// Free any memory allocated during parsing (labels, deps slices).
    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        switch (self.command) {
            .create => |create| {
                if (create.labels.len > 0) allocator.free(create.labels);
                if (create.deps.len > 0) allocator.free(create.deps);
            },
            .list => |list_cmd| {
                if (list_cmd.label_any.len > 0) allocator.free(list_cmd.label_any);
            },
            .label => |label_cmd| {
                switch (label_cmd.subcommand) {
                    .add => |add| if (add.labels.len > 0) allocator.free(add.labels),
                    .remove => |remove| if (remove.labels.len > 0) allocator.free(remove.labels),
                    else => {},
                }
            },
            else => {},
        }
    }
};

/// Errors that can occur during argument parsing.
pub const ParseError = error{
    UnknownCommand,
    MissingRequiredArgument,
    InvalidArgument,
    UnknownFlag,
    MissingFlagValue,
    InvalidFlagValue,
    InvalidShell,
    UnknownSubcommand,
};

/// Command-line argument parser.
pub const ArgParser = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) Self {
        return .{
            .allocator = allocator,
            .args = args,
        };
    }

    /// Parse all arguments into a ParseResult.
    /// Global flags can appear before or after the subcommand.
    pub fn parse(self: *Self) ParseError!ParseResult {
        var global = GlobalOptions{};

        // First pass: extract global flags from anywhere in the argument list
        var filtered_indices: std.ArrayListUnmanaged(usize) = .{};
        defer filtered_indices.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.args.len) {
            const arg = self.args[i];

            // Try to parse as global flag
            if (std.mem.startsWith(u8, arg, "-")) {
                if (isGlobalFlag(arg)) |needs_value| {
                    // Apply the global flag
                    applyGlobalFlag(arg, &global);
                    if (needs_value) {
                        // Consume the next argument as the value
                        i += 1;
                        if (i < self.args.len) {
                            applyGlobalFlagValue(arg, self.args[i], &global) catch {
                                return error.InvalidArgument;
                            };
                        } else {
                            return error.MissingFlagValue;
                        }
                    }
                    i += 1;
                    continue;
                }
            }

            // Not a global flag - add to filtered list
            filtered_indices.append(self.allocator, i) catch return error.InvalidArgument;
            i += 1;
        }

        // Reset parser to use filtered indices
        // We need to parse command args from the filtered list
        if (filtered_indices.items.len == 0) {
            return .{
                .global = global,
                .command = .{ .help = .{ .topic = null } },
            };
        }

        // Get the subcommand string
        const first_filtered = filtered_indices.items[0];
        const cmd_str = self.args[first_filtered];

        // Set parser index to after the filtered command for subcommand arg parsing
        // We need to skip processed global flags in subsequent parsing
        self.index = first_filtered + 1;

        // Parse subcommand with remaining args (which may still have subcommand-specific flags)
        const command = try self.parseCommand(cmd_str);

        return .{
            .global = global,
            .command = command,
        };
    }

    /// Check if an argument is a global flag.
    /// Returns true (needs value) / false (no value) if it's a global flag, null otherwise.
    fn isGlobalFlag(arg: []const u8) ?bool {
        // Flags that don't need values
        const no_value_flags = [_][]const u8{
            "--json",
            "--toon",
            "-q",
            "--quiet",
            "-v",
            "--verbose",
            "-vv",
            "--no-color",
            "--no-auto-flush",
            "--no-auto-import",
            "--wrap",
            "--stats",
            "--robot",
        };
        for (no_value_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) return false;
        }

        // Flags that need values
        const value_flags = [_][]const u8{
            "--data",
            "--db",
            "--actor",
            "--lock-timeout",
        };
        for (value_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) return true;
        }

        return null;
    }

    /// Apply a global flag (no value).
    fn applyGlobalFlag(arg: []const u8, global: *GlobalOptions) void {
        if (std.mem.eql(u8, arg, "--json")) {
            global.json = true;
        } else if (std.mem.eql(u8, arg, "--toon")) {
            global.toon = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            global.quiet = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            global.verbose +|= 1;
        } else if (std.mem.eql(u8, arg, "-vv")) {
            global.verbose +|= 2;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            global.no_color = true;
        } else if (std.mem.eql(u8, arg, "--no-auto-flush")) {
            global.no_auto_flush = true;
        } else if (std.mem.eql(u8, arg, "--no-auto-import")) {
            global.no_auto_import = true;
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            global.wrap = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            global.stats = true;
        } else if (std.mem.eql(u8, arg, "--robot")) {
            global.robot = true;
        }
    }

    /// Apply a global flag that requires a value.
    fn applyGlobalFlagValue(flag: []const u8, value: []const u8, global: *GlobalOptions) !void {
        if (std.mem.eql(u8, flag, "--data") or std.mem.eql(u8, flag, "--db")) {
            global.data_path = value;
        } else if (std.mem.eql(u8, flag, "--actor")) {
            global.actor = value;
        } else if (std.mem.eql(u8, flag, "--lock-timeout")) {
            global.lock_timeout = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArgument;
        }
    }

    fn parseCommand(self: *Self, cmd: []const u8) ParseError!Command {
        // Workspace
        if (std.mem.eql(u8, cmd, "init")) {
            return .{ .init = try self.parseInitArgs() };
        }
        if (std.mem.eql(u8, cmd, "info")) {
            return .{ .info = {} };
        }
        if (std.mem.eql(u8, cmd, "stats")) {
            return .{ .stats = try self.parseStatsArgs() };
        }
        if (std.mem.eql(u8, cmd, "doctor")) {
            return .{ .doctor = {} };
        }
        if (std.mem.eql(u8, cmd, "config")) {
            return .{ .config = try self.parseConfigArgs() };
        }
        if (std.mem.eql(u8, cmd, "orphans")) {
            return .{ .orphans = try self.parseOrphansArgs() };
        }
        if (std.mem.eql(u8, cmd, "lint")) {
            return .{ .lint = try self.parseLintArgs() };
        }
        if (std.mem.eql(u8, cmd, "where")) {
            return .{ .where = {} };
        }

        // Issue CRUD
        if (std.mem.eql(u8, cmd, "create") or std.mem.eql(u8, cmd, "add") or std.mem.eql(u8, cmd, "new")) {
            return .{ .create = try self.parseCreateArgs() };
        }
        if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quick")) {
            return .{ .q = try self.parseQuickArgs() };
        }
        if (std.mem.eql(u8, cmd, "show") or std.mem.eql(u8, cmd, "get") or std.mem.eql(u8, cmd, "view")) {
            return .{ .show = try self.parseShowArgs() };
        }
        if (std.mem.eql(u8, cmd, "update") or std.mem.eql(u8, cmd, "edit")) {
            return .{ .update = try self.parseUpdateArgs() };
        }
        if (std.mem.eql(u8, cmd, "close") or std.mem.eql(u8, cmd, "done") or std.mem.eql(u8, cmd, "finish")) {
            return .{ .close = try self.parseCloseArgs() };
        }
        if (std.mem.eql(u8, cmd, "reopen")) {
            return .{ .reopen = try self.parseReopenArgs() };
        }
        if (std.mem.eql(u8, cmd, "delete") or std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "remove")) {
            return .{ .delete = try self.parseDeleteArgs() };
        }

        // Batch Operations
        if (std.mem.eql(u8, cmd, "add-batch") or std.mem.eql(u8, cmd, "batch-add") or std.mem.eql(u8, cmd, "batch")) {
            return .{ .add_batch = try self.parseAddBatchArgs() };
        }
        if (std.mem.eql(u8, cmd, "import")) {
            return .{ .import_cmd = try self.parseImportArgs() };
        }

        // Query
        if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
            return .{ .list = try self.parseListArgs() };
        }
        if (std.mem.eql(u8, cmd, "ready")) {
            return .{ .ready = try self.parseReadyArgs() };
        }
        if (std.mem.eql(u8, cmd, "blocked")) {
            return .{ .blocked = try self.parseBlockedArgs() };
        }
        if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "find")) {
            return .{ .search = try self.parseSearchArgs() };
        }
        if (std.mem.eql(u8, cmd, "stale")) {
            return .{ .stale = try self.parseStaleArgs() };
        }
        if (std.mem.eql(u8, cmd, "count")) {
            return .{ .count = try self.parseCountArgs() };
        }
        if (std.mem.eql(u8, cmd, "defer")) {
            return .{ .defer_cmd = try self.parseDeferArgs() };
        }
        if (std.mem.eql(u8, cmd, "undefer")) {
            return .{ .undefer = try self.parseUndeferArgs() };
        }

        // Dependencies
        if (std.mem.eql(u8, cmd, "dep") or std.mem.eql(u8, cmd, "deps") or std.mem.eql(u8, cmd, "dependency")) {
            return .{ .dep = try self.parseDepArgs() };
        }
        if (std.mem.eql(u8, cmd, "graph")) {
            return .{ .graph = try self.parseGraphArgs() };
        }

        // Epics
        if (std.mem.eql(u8, cmd, "epic") or std.mem.eql(u8, cmd, "epics")) {
            return .{ .epic = try self.parseEpicArgs() };
        }

        // Labels
        if (std.mem.eql(u8, cmd, "label") or std.mem.eql(u8, cmd, "labels") or std.mem.eql(u8, cmd, "tag")) {
            return .{ .label = try self.parseLabelArgs() };
        }

        // Comments
        if (std.mem.eql(u8, cmd, "comments") or std.mem.eql(u8, cmd, "comment") or std.mem.eql(u8, cmd, "note")) {
            return .{ .comments = try self.parseCommentsArgs() };
        }

        // Audit
        if (std.mem.eql(u8, cmd, "history") or std.mem.eql(u8, cmd, "log")) {
            return .{ .history = try self.parseHistoryArgs() };
        }
        if (std.mem.eql(u8, cmd, "audit")) {
            return .{ .audit = try self.parseAuditArgs() };
        }

        // Changelog
        if (std.mem.eql(u8, cmd, "changelog")) {
            return .{ .changelog = try self.parseChangelogArgs() };
        }

        // Sync
        if (std.mem.eql(u8, cmd, "sync") or std.mem.eql(u8, cmd, "flush") or std.mem.eql(u8, cmd, "export")) {
            return .{ .sync = try self.parseSyncArgs() };
        }

        // Backup
        if (std.mem.eql(u8, cmd, "backup") or std.mem.eql(u8, cmd, "backups")) {
            return .{ .backup = try self.parseBackupArgs() };
        }

        // System
        if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
            return .{ .version = {} };
        }
        if (std.mem.eql(u8, cmd, "schema")) {
            return .{ .schema = {} };
        }
        if (std.mem.eql(u8, cmd, "completions") or std.mem.eql(u8, cmd, "completion")) {
            return .{ .completions = try self.parseCompletionsArgs() };
        }
        if (std.mem.eql(u8, cmd, "metrics")) {
            return .{ .metrics = try self.parseMetricsArgs() };
        }

        // Saved Queries
        if (std.mem.eql(u8, cmd, "query")) {
            return .{ .query = try self.parseQueryArgs() };
        }

        // Self-upgrade
        if (std.mem.eql(u8, cmd, "upgrade")) {
            return .{ .upgrade = try self.parseUpgradeArgs() };
        }

        // Help
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            return .{ .help = try self.parseHelpArgs() };
        }

        return error.UnknownCommand;
    }

    fn parseInitArgs(self: *Self) ParseError!InitArgs {
        var result = InitArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("-p", "--prefix")) {
                result.prefix = self.next() orelse return error.MissingFlagValue;
            } else if (self.peekPositional()) |_| {
                result.prefix = self.next().?;
            } else break;
        }
        return result;
    }

    fn parseStatsArgs(self: *Self) ParseError!StatsArgs {
        var result = StatsArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("-a", "--activity")) {
                result.activity = true;
            } else if (self.consumeFlag(null, "--activity-hours")) {
                result.activity_hours = try self.consumeU32() orelse return error.MissingFlagValue;
            } else break;
        }
        return result;
    }

    fn parseCreateArgs(self: *Self) ParseError!CreateArgs {
        var result = CreateArgs{ .title = undefined };
        var title_set = false;
        var labels: std.ArrayListUnmanaged([]const u8) = .{};
        var deps: std.ArrayListUnmanaged([]const u8) = .{};

        while (self.hasNext()) {
            if (self.consumeFlag("-d", "--description")) {
                result.description = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-t", "--type")) {
                result.issue_type = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-p", "--priority")) {
                result.priority = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-a", "--assignee")) {
                result.assignee = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-o", "--owner")) {
                result.owner = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--design")) {
                result.design = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--acceptance-criteria")) {
                result.acceptance_criteria = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--external-ref")) {
                result.external_ref = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-l", "--label")) {
                labels.append(self.allocator, self.next() orelse return error.MissingFlagValue) catch return error.InvalidArgument;
            } else if (self.consumeFlag("--depends-on", "--dep")) {
                deps.append(self.allocator, self.next() orelse return error.MissingFlagValue) catch return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--due")) {
                result.due = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-e", "--estimate")) {
                const val = self.next() orelse return error.MissingFlagValue;
                result.estimate = std.fmt.parseInt(i32, val, 10) catch return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--ephemeral")) {
                result.ephemeral = true;
            } else if (self.consumeFlag(null, "--dry-run")) {
                result.dry_run = true;
            } else if (self.peekPositional()) |_| {
                if (!title_set) {
                    result.title = self.next().?;
                    title_set = true;
                } else break;
            } else break;
        }

        if (!title_set) return error.MissingRequiredArgument;

        if (labels.items.len > 0) {
            result.labels = labels.toOwnedSlice(self.allocator) catch return error.InvalidArgument;
        }
        if (deps.items.len > 0) {
            result.deps = deps.toOwnedSlice(self.allocator) catch return error.InvalidArgument;
        }

        return result;
    }

    fn parseQuickArgs(self: *Self) ParseError!QuickArgs {
        var result = QuickArgs{ .title = undefined };
        var title_set = false;

        while (self.hasNext()) {
            if (self.consumeFlag("-p", "--priority")) {
                result.priority = self.next() orelse return error.MissingFlagValue;
            } else if (self.peekPositional()) |_| {
                if (!title_set) {
                    result.title = self.next().?;
                    title_set = true;
                } else break;
            } else break;
        }

        if (!title_set) return error.MissingRequiredArgument;
        return result;
    }

    fn parseShowArgs(self: *Self) ParseError!ShowArgs {
        var result = ShowArgs{ .id = undefined };
        var id_set = false;

        while (self.hasNext()) {
            if (self.consumeFlag(null, "--no-comments")) {
                result.with_comments = false;
            } else if (self.consumeFlag(null, "--with-history")) {
                result.with_history = true;
            } else if (self.peekPositional()) |_| {
                if (!id_set) {
                    result.id = self.next().?;
                    id_set = true;
                } else break;
            } else break;
        }

        if (!id_set) return error.MissingRequiredArgument;
        return result;
    }

    fn parseUpdateArgs(self: *Self) ParseError!UpdateArgs {
        var result = UpdateArgs{ .id = undefined };
        var id_set = false;

        while (self.hasNext()) {
            if (self.consumeFlag(null, "--title")) {
                result.title = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-d", "--description")) {
                result.description = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-t", "--type")) {
                result.issue_type = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-p", "--priority")) {
                result.priority = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-a", "--assignee")) {
                result.assignee = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-o", "--owner")) {
                result.owner = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--design")) {
                result.design = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--acceptance-criteria")) {
                result.acceptance_criteria = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--external-ref")) {
                result.external_ref = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-s", "--status")) {
                result.status = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-v", "--version")) {
                const version_str = self.next() orelse return error.MissingFlagValue;
                result.expected_version = std.fmt.parseInt(u64, version_str, 10) catch return error.InvalidFlagValue;
            } else if (self.consumeFlag(null, "--claim")) {
                result.claim = true;
            } else if (self.peekPositional()) |_| {
                if (!id_set) {
                    result.id = self.next().?;
                    id_set = true;
                } else break;
            } else break;
        }

        if (!id_set) return error.MissingRequiredArgument;
        return result;
    }

    fn parseCloseArgs(self: *Self) ParseError!CloseArgs {
        var result = CloseArgs{ .id = undefined };
        var id_set = false;

        while (self.hasNext()) {
            if (self.consumeFlag("-r", "--reason")) {
                result.reason = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-s", "--session")) {
                result.session = self.next() orelse return error.MissingFlagValue;
            } else if (self.peekPositional()) |_| {
                if (!id_set) {
                    result.id = self.next().?;
                    id_set = true;
                } else break;
            } else break;
        }

        if (!id_set) return error.MissingRequiredArgument;
        return result;
    }

    fn parseReopenArgs(self: *Self) ParseError!ReopenArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        return .{ .id = id };
    }

    fn parseDeleteArgs(self: *Self) ParseError!DeleteArgs {
        var result = DeleteArgs{};

        while (self.hasNext()) {
            if (self.consumeFlag("-f", "--from-file")) {
                result.from_file = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--cascade")) {
                result.cascade = true;
            } else if (self.consumeFlag(null, "--hard")) {
                result.hard = true;
            } else if (self.consumeFlag(null, "--dry-run")) {
                result.dry_run = true;
            } else if (self.peekPositional()) |_| {
                if (result.id == null) {
                    result.id = self.next().?;
                } else break;
            } else break;
        }

        // Require either id or from_file
        if (result.id == null and result.from_file == null) {
            return error.MissingRequiredArgument;
        }

        return result;
    }

    fn parseAddBatchArgs(self: *Self) ParseError!AddBatchArgs {
        var result = AddBatchArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("-f", "--file")) {
                result.file = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--format")) {
                const fmt_str = self.next() orelse return error.MissingFlagValue;
                result.format = BatchFormat.fromString(fmt_str) orelse return error.InvalidArgument;
            } else if (self.peekPositional()) |_| {
                // Positional argument is treated as file path
                if (result.file == null) {
                    result.file = self.next().?;
                } else break;
            } else break;
        }
        return result;
    }

    fn parseImportArgs(self: *Self) ParseError!ImportArgs {
        var result = ImportArgs{ .file = undefined };
        var file_set = false;

        while (self.hasNext()) {
            if (self.consumeFlag("-m", "--merge")) {
                result.merge = true;
            } else if (self.consumeFlag("-n", "--dry-run")) {
                result.dry_run = true;
            } else if (self.peekPositional()) |_| {
                if (!file_set) {
                    result.file = self.next().?;
                    file_set = true;
                } else break;
            } else break;
        }

        if (!file_set) return error.MissingRequiredArgument;
        return result;
    }

    fn parseListArgs(self: *Self) ParseError!ListArgs {
        var result = ListArgs{};
        var label_any_list: std.ArrayListUnmanaged([]const u8) = .{};

        while (self.hasNext()) {
            if (self.consumeFlag("-s", "--status")) {
                result.status = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-p", "--priority")) {
                result.priority = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--priority-min")) {
                result.priority_min = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--priority-max")) {
                result.priority_max = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-t", "--type")) {
                result.issue_type = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-a", "--assignee")) {
                result.assignee = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-l", "--label")) {
                result.label = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--label-any")) {
                label_any_list.append(self.allocator, self.next() orelse return error.MissingFlagValue) catch return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--title-contains")) {
                result.title_contains = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--desc-contains")) {
                result.desc_contains = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--notes-contains")) {
                result.notes_contains = self.next() orelse return error.MissingFlagValue;
            } else if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else if (self.consumeFlag("-A", "--all")) {
                result.all = true;
            } else if (self.consumeFlag(null, "--overdue")) {
                result.overdue = true;
            } else if (self.consumeFlag(null, "--deferred") or self.consumeFlag(null, "--include-deferred")) {
                result.include_deferred = true;
            } else if (self.consumeFlag(null, "--sort")) {
                const sort_str = self.next() orelse return error.MissingFlagValue;
                result.sort = SortField.fromString(sort_str) orelse return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--asc")) {
                result.sort_desc = false;
            } else if (self.consumeFlag(null, "--desc")) {
                result.sort_desc = true;
            } else if (self.consumeFlag(null, "--parent")) {
                result.parent = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-r", "--recursive")) {
                result.recursive = true;
            } else if (self.consumeFlag("-f", "--format")) {
                const fmt_str = self.next() orelse return error.MissingFlagValue;
                result.format = OutputFormat.fromString(fmt_str) orelse return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--fields")) {
                result.fields = self.next() orelse return error.MissingFlagValue;
            } else break;
        }

        if (label_any_list.items.len > 0) {
            result.label_any = label_any_list.toOwnedSlice(self.allocator) catch return error.InvalidArgument;
        }

        return result;
    }

    fn parseReadyArgs(self: *Self) ParseError!ReadyArgs {
        var result = ReadyArgs{};
        while (self.hasNext()) {
            if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else if (self.consumeFlag(null, "--priority-min")) {
                result.priority_min = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--priority-max")) {
                result.priority_max = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--title-contains")) {
                result.title_contains = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--desc-contains")) {
                result.desc_contains = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--notes-contains")) {
                result.notes_contains = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--overdue")) {
                result.overdue = true;
            } else if (self.consumeFlag(null, "--include-deferred")) {
                result.include_deferred = true;
            } else if (self.consumeFlag(null, "--parent")) {
                result.parent = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-r", "--recursive")) {
                result.recursive = true;
            } else if (self.consumeFlag("-f", "--format")) {
                const fmt_str = self.next() orelse return error.MissingFlagValue;
                result.format = OutputFormat.fromString(fmt_str) orelse return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--fields")) {
                result.fields = self.next() orelse return error.MissingFlagValue;
            } else break;
        }
        return result;
    }

    fn parseBlockedArgs(self: *Self) ParseError!BlockedArgs {
        var result = BlockedArgs{};
        while (self.hasNext()) {
            if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else if (self.consumeFlag(null, "--priority-min")) {
                result.priority_min = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--priority-max")) {
                result.priority_max = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--title-contains")) {
                result.title_contains = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--desc-contains")) {
                result.desc_contains = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--notes-contains")) {
                result.notes_contains = self.next() orelse return error.MissingFlagValue;
            } else break;
        }
        return result;
    }

    fn parseSearchArgs(self: *Self) ParseError!SearchArgs {
        var result = SearchArgs{ .query = undefined };
        var query_set = false;

        while (self.hasNext()) {
            if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else if (self.peekPositional()) |_| {
                if (!query_set) {
                    result.query = self.next().?;
                    query_set = true;
                } else break;
            } else break;
        }

        if (!query_set) return error.MissingRequiredArgument;
        return result;
    }

    fn parseStaleArgs(self: *Self) ParseError!StaleArgs {
        var result = StaleArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("-d", "--days")) {
                result.days = try self.consumeU32() orelse return error.MissingFlagValue;
            } else if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else break;
        }
        return result;
    }

    fn parseCountArgs(self: *Self) ParseError!CountArgs {
        var result = CountArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("-g", "--group-by")) {
                result.group_by = self.next() orelse return error.MissingFlagValue;
            } else break;
        }
        return result;
    }

    fn parseDeferArgs(self: *Self) ParseError!DeferArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        var result = DeferArgs{ .id = id };
        while (self.hasNext()) {
            if (self.consumeFlag("-u", "--until")) {
                result.until = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-r", "--reason")) {
                result.reason = self.next() orelse return error.MissingFlagValue;
            } else break;
        }
        return result;
    }

    fn parseUndeferArgs(self: *Self) ParseError!UndeferArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        return UndeferArgs{ .id = id };
    }

    fn parseDepArgs(self: *Self) ParseError!DepArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "add")) {
            const child = self.next() orelse return error.MissingRequiredArgument;
            const parent = self.next() orelse return error.MissingRequiredArgument;
            var dep_type: []const u8 = "blocks";
            var metadata: ?[]const u8 = null;
            while (self.hasNext()) {
                if (self.consumeFlag("-t", "--type")) {
                    dep_type = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-m", "--metadata")) {
                    metadata = self.next() orelse return error.MissingFlagValue;
                } else break;
            }
            return .{ .subcommand = .{ .add = .{ .child = child, .parent = parent, .dep_type = dep_type, .metadata = metadata } } };
        }
        if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
            const child = self.next() orelse return error.MissingRequiredArgument;
            const parent = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .remove = .{ .child = child, .parent = parent } } };
        }
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            var direction: DepDirection = .both;
            while (self.hasNext()) {
                if (self.consumeFlag("-d", "--direction")) {
                    const dir_str = self.next() orelse return error.MissingFlagValue;
                    direction = DepDirection.fromString(dir_str) orelse return error.InvalidArgument;
                } else break;
            }
            return .{ .subcommand = .{ .list = .{ .id = id, .direction = direction } } };
        }
        if (std.mem.eql(u8, subcmd, "tree")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            var format: TreeFormat = .ascii;
            while (self.hasNext()) {
                if (self.consumeFlag("-f", "--format")) {
                    const fmt_str = self.next() orelse return error.MissingFlagValue;
                    format = TreeFormat.fromString(fmt_str) orelse return error.InvalidArgument;
                } else break;
            }
            return .{ .subcommand = .{ .tree = .{ .id = id, .format = format } } };
        }
        if (std.mem.eql(u8, subcmd, "cycles")) {
            return .{ .subcommand = .{ .cycles = {} } };
        }
        return error.UnknownSubcommand;
    }

    fn parseGraphArgs(self: *Self) ParseError!GraphArgs {
        var result = GraphArgs{};

        while (self.hasNext()) {
            if (self.consumeFlag("-f", "--format")) {
                const fmt_str = self.next() orelse return error.MissingFlagValue;
                result.format = GraphFormat.fromString(fmt_str) orelse return error.InvalidArgument;
            } else if (self.consumeFlag("-d", "--depth")) {
                result.depth = try self.consumeU32() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag("-a", "--all")) {
                result.all = true;
            } else if (self.consumeFlag("-c", "--compact")) {
                result.compact = true;
            } else if (self.peekPositional()) |_| {
                if (result.id == null) {
                    result.id = self.next().?;
                } else break;
            } else break;
        }

        return result;
    }

    fn parseEpicArgs(self: *Self) ParseError!EpicArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "create") or std.mem.eql(u8, subcmd, "new")) {
            var title: ?[]const u8 = null;
            var description: ?[]const u8 = null;
            var priority: ?[]const u8 = null;

            while (self.hasNext()) {
                if (self.consumeFlag("-d", "--description")) {
                    description = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-p", "--priority")) {
                    priority = self.next() orelse return error.MissingFlagValue;
                } else if (self.peekPositional()) |_| {
                    if (title == null) {
                        title = self.next().?;
                    } else break;
                } else break;
            }

            if (title == null) return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .create = .{
                .title = title.?,
                .description = description,
                .priority = priority,
            } } };
        }
        if (std.mem.eql(u8, subcmd, "add")) {
            const epic_id = self.next() orelse return error.MissingRequiredArgument;
            const issue_id = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .add = .{ .epic_id = epic_id, .issue_id = issue_id } } };
        }
        if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
            const epic_id = self.next() orelse return error.MissingRequiredArgument;
            const issue_id = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .remove = .{ .epic_id = epic_id, .issue_id = issue_id } } };
        }
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            return .{ .subcommand = .{ .list = .{ .epic_id = self.next() orelse return error.MissingRequiredArgument } } };
        }
        if (std.mem.eql(u8, subcmd, "status")) {
            return .{ .subcommand = .{ .status = {} } };
        }
        if (std.mem.eql(u8, subcmd, "close-eligible")) {
            var dry_run = false;
            while (self.hasNext()) {
                if (self.consumeFlag("-n", "--dry-run")) {
                    dry_run = true;
                } else break;
            }
            return .{ .subcommand = .{ .close_eligible = .{ .dry_run = dry_run } } };
        }
        return error.UnknownSubcommand;
    }

    fn parseLabelArgs(self: *Self) ParseError!LabelArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "add") or std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
            const is_add = std.mem.eql(u8, subcmd, "add");
            const id = self.next() orelse return error.MissingRequiredArgument;
            var labels: std.ArrayListUnmanaged([]const u8) = .{};

            while (self.peekPositional()) |_| {
                labels.append(self.allocator, self.next().?) catch return error.InvalidArgument;
            }

            if (labels.items.len == 0) return error.MissingRequiredArgument;

            const label_slice = labels.toOwnedSlice(self.allocator) catch return error.InvalidArgument;
            if (is_add) {
                return .{ .subcommand = .{ .add = .{ .id = id, .labels = label_slice } } };
            } else {
                return .{ .subcommand = .{ .remove = .{ .id = id, .labels = label_slice } } };
            }
        }
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            return .{ .subcommand = .{ .list = .{ .id = self.next() orelse return error.MissingRequiredArgument } } };
        }
        if (std.mem.eql(u8, subcmd, "list-all") or std.mem.eql(u8, subcmd, "all")) {
            return .{ .subcommand = .{ .list_all = {} } };
        }
        if (std.mem.eql(u8, subcmd, "rename") or std.mem.eql(u8, subcmd, "mv")) {
            const old_name = self.next() orelse return error.MissingRequiredArgument;
            const new_name = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .rename = .{ .old_name = old_name, .new_name = new_name } } };
        }
        return error.UnknownSubcommand;
    }

    fn parseCommentsArgs(self: *Self) ParseError!CommentsArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "add")) {
            return .{ .subcommand = .{ .add = .{
                .id = self.next() orelse return error.MissingRequiredArgument,
                .text = self.next() orelse return error.MissingRequiredArgument,
            } } };
        }
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            return .{ .subcommand = .{ .list = .{ .id = self.next() orelse return error.MissingRequiredArgument } } };
        }
        return error.UnknownSubcommand;
    }

    fn parseHistoryArgs(self: *Self) ParseError!HistoryArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        return .{ .id = id };
    }

    fn parseAuditArgs(self: *Self) ParseError!AuditArgs {
        // Check for subcommand
        const subcmd = self.next() orelse {
            // Default: list with no limit
            return .{ .subcommand = .{ .list = .{ .limit = null } } };
        };

        // Handle --limit flag at top level (legacy support)
        if (std.mem.startsWith(u8, subcmd, "-")) {
            // Put it back and parse as list subcommand with limit
            self.index -= 1;
            var limit: ?u32 = null;
            while (self.hasNext()) {
                if (try self.parseLimitFlag()) |l| {
                    limit = l;
                } else break;
            }
            return .{ .subcommand = .{ .list = .{ .limit = limit } } };
        }

        if (std.mem.eql(u8, subcmd, "record")) {
            const kind = self.next() orelse return error.MissingRequiredArgument;
            var result = AuditSubcommand{ .record = .{ .kind = kind } };

            while (self.hasNext()) {
                if (self.consumeFlag("-i", "--issue")) {
                    result.record.issue_id = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-m", "--model")) {
                    result.record.model = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-p", "--prompt")) {
                    result.record.prompt = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-r", "--response")) {
                    result.record.response = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-t", "--tool-name")) {
                    result.record.tool_name = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-e", "--exit-code")) {
                    const exit_str = self.next() orelse return error.MissingFlagValue;
                    result.record.exit_code = std.fmt.parseInt(i32, exit_str, 10) catch return error.InvalidFlagValue;
                } else if (self.consumeFlag(null, "--metadata")) {
                    result.record.metadata = self.next() orelse return error.MissingFlagValue;
                } else break;
            }
            return .{ .subcommand = result };
        }

        if (std.mem.eql(u8, subcmd, "label")) {
            const entry_id_str = self.next() orelse return error.MissingRequiredArgument;
            const entry_id = std.fmt.parseInt(i64, entry_id_str, 10) catch return error.InvalidArgument;
            var label_value: ?[]const u8 = null;
            var reason: ?[]const u8 = null;

            while (self.hasNext()) {
                if (self.consumeFlag("-l", "--label")) {
                    label_value = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-r", "--reason")) {
                    reason = self.next() orelse return error.MissingFlagValue;
                } else if (self.peekPositional()) |_| {
                    if (label_value == null) {
                        label_value = self.next().?;
                    } else break;
                } else break;
            }

            if (label_value == null) return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .label = .{
                .entry_id = entry_id,
                .label_value = label_value.?,
                .reason = reason,
            } } };
        }

        if (std.mem.eql(u8, subcmd, "log")) {
            const issue_id = self.next() orelse return error.MissingRequiredArgument;
            var limit: ?u32 = null;
            while (self.hasNext()) {
                if (try self.parseLimitFlag()) |l| {
                    limit = l;
                } else break;
            }
            return .{ .subcommand = .{ .log = .{ .issue_id = issue_id, .limit = limit } } };
        }

        if (std.mem.eql(u8, subcmd, "summary")) {
            var days: u32 = 7;
            while (self.hasNext()) {
                if (self.consumeFlag("-d", "--days")) {
                    days = try self.consumeU32() orelse return error.MissingFlagValue;
                } else break;
            }
            return .{ .subcommand = .{ .summary = .{ .days = days } } };
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            var limit: ?u32 = null;
            while (self.hasNext()) {
                if (try self.parseLimitFlag()) |l| {
                    limit = l;
                } else break;
            }
            return .{ .subcommand = .{ .list = .{ .limit = limit } } };
        }

        return error.UnknownSubcommand;
    }

    fn parseChangelogArgs(self: *Self) ParseError!ChangelogArgs {
        var result = ChangelogArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag(null, "--since")) {
                result.since = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--until")) {
                result.until = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--since-tag")) {
                result.since_tag = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--since-commit")) {
                result.since_commit = self.next() orelse return error.MissingFlagValue;
            } else if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else if (self.consumeFlag("-g", "--group-by")) {
                result.group_by = self.next() orelse return error.MissingFlagValue;
            } else break;
        }
        return result;
    }

    fn parseSyncArgs(self: *Self) ParseError!SyncArgs {
        var result = SyncArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("--export", "--flush-only")) {
                result.flush_only = true;
            } else if (self.consumeFlag("--import", "--import-only")) {
                result.import_only = true;
            } else if (self.consumeFlag("-m", "--merge")) {
                result.merge = true;
            } else if (self.consumeFlag("-s", "--status")) {
                result.status = true;
            } else if (self.consumeFlag(null, "--manifest")) {
                result.manifest = true;
            } else if (self.consumeFlag(null, "--error-policy")) {
                const policy_str = self.next() orelse return error.MissingFlagValue;
                result.error_policy = ErrorPolicy.fromString(policy_str) orelse return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--orphans")) {
                const policy_str = self.next() orelse return error.MissingFlagValue;
                result.orphan_policy = OrphanPolicy.fromString(policy_str) orelse return error.InvalidArgument;
            } else if (self.consumeFlag(null, "--rename-prefix")) {
                result.rename_prefix = true;
            } else break;
        }
        return result;
    }

    fn parseBackupArgs(self: *Self) ParseError!BackupArgs {
        const subcmd = self.next() orelse return .{ .subcommand = .{ .list = {} } };

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            return .{ .subcommand = .{ .list = {} } };
        }
        if (std.mem.eql(u8, subcmd, "diff")) {
            const file = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .diff = .{ .file = file } } };
        }
        if (std.mem.eql(u8, subcmd, "restore")) {
            const file = self.next() orelse return error.MissingRequiredArgument;
            var dry_run = false;
            while (self.hasNext()) {
                if (self.consumeFlag("-n", "--dry-run")) {
                    dry_run = true;
                } else break;
            }
            return .{ .subcommand = .{ .restore = .{ .file = file, .dry_run = dry_run } } };
        }
        if (std.mem.eql(u8, subcmd, "prune")) {
            var keep: u32 = 10;
            var dry_run = false;
            while (self.hasNext()) {
                if (self.consumeFlag("-k", "--keep")) {
                    const keep_str = self.next() orelse return error.MissingFlagValue;
                    keep = std.fmt.parseInt(u32, keep_str, 10) catch return error.InvalidArgument;
                } else if (self.consumeFlag("-n", "--dry-run")) {
                    dry_run = true;
                } else break;
            }
            return .{ .subcommand = .{ .prune = .{ .keep = keep, .dry_run = dry_run } } };
        }
        if (std.mem.eql(u8, subcmd, "create") or std.mem.eql(u8, subcmd, "new")) {
            return .{ .subcommand = .{ .create = {} } };
        }
        return error.UnknownSubcommand;
    }

    fn parseCompletionsArgs(self: *Self) ParseError!CompletionsArgs {
        const shell_str = self.next() orelse return error.MissingRequiredArgument;
        const shell = Shell.fromString(shell_str) orelse return error.InvalidShell;
        return .{ .shell = shell };
    }

    fn parseMetricsArgs(self: *Self) ParseError!MetricsArgs {
        var result = MetricsArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("-r", "--reset")) {
                result.reset = true;
            } else break;
        }
        return result;
    }

    fn parseHelpArgs(self: *Self) ParseError!HelpArgs {
        return .{ .topic = self.next() };
    }

    fn parseConfigArgs(self: *Self) ParseError!ConfigArgs {
        const subcmd = self.next() orelse return .{ .subcommand = .{ .list = {} } };

        if (std.mem.eql(u8, subcmd, "get")) {
            return .{ .subcommand = .{ .get = .{ .key = self.next() orelse return error.MissingRequiredArgument } } };
        }
        if (std.mem.eql(u8, subcmd, "set")) {
            return .{ .subcommand = .{ .set = .{
                .key = self.next() orelse return error.MissingRequiredArgument,
                .value = self.next() orelse return error.MissingRequiredArgument,
            } } };
        }
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            return .{ .subcommand = .{ .list = {} } };
        }
        return error.UnknownSubcommand;
    }

    fn parseOrphansArgs(self: *Self) ParseError!OrphansArgs {
        var result = OrphansArgs{};
        while (self.hasNext()) {
            if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else if (self.consumeFlag(null, "--hierarchy-only")) {
                result.hierarchy_only = true;
            } else if (self.consumeFlag(null, "--deps-only")) {
                result.deps_only = true;
            } else break;
        }
        return result;
    }

    fn parseLintArgs(self: *Self) ParseError!LintArgs {
        var result = LintArgs{};
        while (self.hasNext()) {
            if (try self.parseLimitFlag()) |limit| {
                result.limit = limit;
            } else break;
        }
        return result;
    }

    fn parseQueryArgs(self: *Self) ParseError!QueryArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "save")) {
            const name = self.next() orelse return error.MissingRequiredArgument;
            var save_args = QuerySubcommand{ .save = .{ .name = name } };

            while (self.hasNext()) {
                if (self.consumeFlag("-s", "--status")) {
                    save_args.save.status = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-p", "--priority")) {
                    save_args.save.priority = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-t", "--type")) {
                    save_args.save.issue_type = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-a", "--assignee")) {
                    save_args.save.assignee = self.next() orelse return error.MissingFlagValue;
                } else if (self.consumeFlag("-l", "--label")) {
                    save_args.save.label = self.next() orelse return error.MissingFlagValue;
                } else if (try self.parseLimitFlag()) |limit| {
                    save_args.save.limit = limit;
                } else break;
            }

            return .{ .subcommand = save_args };
        }
        if (std.mem.eql(u8, subcmd, "run")) {
            return .{ .subcommand = .{ .run = .{ .name = self.next() orelse return error.MissingRequiredArgument } } };
        }
        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            return .{ .subcommand = .{ .list = {} } };
        }
        if (std.mem.eql(u8, subcmd, "delete") or std.mem.eql(u8, subcmd, "rm")) {
            return .{ .subcommand = .{ .delete = .{ .name = self.next() orelse return error.MissingRequiredArgument } } };
        }
        return error.UnknownSubcommand;
    }

    fn parseUpgradeArgs(self: *Self) ParseError!UpgradeArgs {
        var result = UpgradeArgs{};
        while (self.hasNext()) {
            if (self.consumeFlag("-c", "--check")) {
                result.check_only = true;
            } else if (self.consumeFlag("-n", "--dry-run")) {
                result.dry_run = true;
            } else if (self.consumeFlag("-V", "--version")) {
                result.version = self.next() orelse return error.MissingFlagValue;
            } else if (self.consumeFlag(null, "--no-verify")) {
                result.verify = false;
            } else if (self.consumeFlag(null, "--verify")) {
                result.verify = true;
            } else if (self.consumeFlag("-f", "--force")) {
                result.force = true;
            } else break;
        }
        return result;
    }

    fn hasNext(self: *Self) bool {
        return self.index < self.args.len;
    }

    fn peek(self: *Self) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        return self.args[self.index];
    }

    fn next(self: *Self) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }

    /// Skip a peeked argument (used after checking with peek() and wanting to consume it).
    fn skip(self: *Self) void {
        if (self.index < self.args.len) {
            self.index += 1;
        }
    }

    /// Check if current arg matches a flag, and if so consume it and return true.
    fn consumeFlag(self: *Self, short: ?[]const u8, long: []const u8) bool {
        const arg = self.peek() orelse return false;
        if (std.mem.eql(u8, arg, long) or (short != null and std.mem.eql(u8, arg, short.?))) {
            self.skip();
            return true;
        }
        return false;
    }

    /// Parse a u32 value after consuming a flag. Returns null if missing, error if invalid.
    fn consumeU32(self: *Self) ParseError!?u32 {
        const val = self.next() orelse return error.MissingFlagValue;
        return std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
    }

    /// Parse an optional --limit/-n flag, returning the value if present.
    fn parseLimitFlag(self: *Self) ParseError!?u32 {
        if (self.consumeFlag("-n", "--limit")) {
            return try self.consumeU32();
        }
        return null;
    }

    /// Returns the next arg if it's a positional (doesn't start with "-"), otherwise null.
    fn peekPositional(self: *Self) ?[]const u8 {
        const arg = self.peek() orelse return null;
        if (std.mem.startsWith(u8, arg, "-")) return null;
        return arg;
    }
};

// Tests

test "parse no arguments shows help" {
    const args = [_][]const u8{};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .help);
    try std.testing.expectEqual(@as(?[]const u8, null), result.command.help.topic);
}

test "parse global flag --json" {
    const args = [_][]const u8{ "--json", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.json);
    try std.testing.expect(result.command == .list);
}

test "parse global flag --json after subcommand" {
    const args = [_][]const u8{ "list", "--json" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.json);
    try std.testing.expect(result.command == .list);
}

test "parse global flag --json after subcommand with ready" {
    const args = [_][]const u8{ "ready", "--json" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.json);
    try std.testing.expect(result.command == .ready);
}

test "parse global flags before and after subcommand" {
    const args = [_][]const u8{ "--quiet", "list", "--json" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.json);
    try std.testing.expect(result.global.quiet);
    try std.testing.expect(result.command == .list);
}

test "parse global flag --toon" {
    const args = [_][]const u8{ "--toon", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.toon);
    try std.testing.expect(result.command == .list);
}

test "parse global flag -q (quiet)" {
    const args = [_][]const u8{ "-q", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.quiet);
    try std.testing.expect(result.command == .list);
}

test "parse global flag --quiet" {
    const args = [_][]const u8{ "--quiet", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.quiet);
    try std.testing.expect(result.command == .list);
}

test "parse global flag -v (verbose)" {
    const args = [_][]const u8{ "-v", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(@as(u8, 1), result.global.verbose);
}

test "parse global flag -v multiple times" {
    const args = [_][]const u8{ "-v", "-v", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(@as(u8, 2), result.global.verbose);
}

test "parse global flag -vv (double verbose)" {
    const args = [_][]const u8{ "-vv", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(@as(u8, 2), result.global.verbose);
}

test "parse global flag --no-color" {
    const args = [_][]const u8{ "--no-color", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.no_color);
}

test "parse global flag --no-auto-flush" {
    const args = [_][]const u8{ "--no-auto-flush", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.no_auto_flush);
}

test "parse global flag --no-auto-import" {
    const args = [_][]const u8{ "--no-auto-import", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.no_auto_import);
}

test "parse global flag --data with value" {
    const args = [_][]const u8{ "--data", "/custom/path", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("/custom/path", result.global.data_path.?);
}

test "parse global flag --actor with value" {
    const args = [_][]const u8{ "--actor", "alice", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("alice", result.global.actor.?);
}

test "parse global flag --lock-timeout with value" {
    const args = [_][]const u8{ "--lock-timeout", "10000", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(@as(u32, 10000), result.global.lock_timeout);
}

test "parse multiple global flags" {
    const args = [_][]const u8{ "--json", "-v", "--no-color", "list" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.global.json);
    try std.testing.expectEqual(@as(u8, 1), result.global.verbose);
    try std.testing.expect(result.global.no_color);
    try std.testing.expect(result.command == .list);
}

test "parse unknown command returns error" {
    const args = [_][]const u8{"unknown_command"};
    var parser = ArgParser.init(std.testing.allocator, &args);

    try std.testing.expectError(error.UnknownCommand, parser.parse());
}

test "parse help command" {
    const args = [_][]const u8{"help"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .help);
}

test "parse help command with topic" {
    const args = [_][]const u8{ "help", "create" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .help);
    try std.testing.expectEqualStrings("create", result.command.help.topic.?);
}

test "parse --help as help command" {
    const args = [_][]const u8{"--help"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .help);
}

test "parse -h as help command" {
    const args = [_][]const u8{"-h"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .help);
}

test "parse version command" {
    const args = [_][]const u8{"version"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .version);
}

test "parse --version as version command" {
    const args = [_][]const u8{"--version"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .version);
}

test "parse -V as version command" {
    const args = [_][]const u8{"-V"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .version);
}

test "parse init command" {
    const args = [_][]const u8{"init"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .init);
    try std.testing.expectEqualStrings("bd", result.command.init.prefix);
}

test "parse init command with prefix" {
    const args = [_][]const u8{ "init", "--prefix", "proj" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .init);
    try std.testing.expectEqualStrings("proj", result.command.init.prefix);
}

test "parse create command with title" {
    const args = [_][]const u8{ "create", "Fix login bug" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .create);
    try std.testing.expectEqualStrings("Fix login bug", result.command.create.title);
}

test "parse create command missing title returns error" {
    const args = [_][]const u8{"create"};
    var parser = ArgParser.init(std.testing.allocator, &args);

    try std.testing.expectError(error.MissingRequiredArgument, parser.parse());
}

test "parse create command with all options" {
    const args = [_][]const u8{
        "create",
        "Fix login bug",
        "--description",
        "OAuth fails for Google",
        "--type",
        "bug",
        "--priority",
        "high",
        "--assignee",
        "alice",
        "--due",
        "2024-02-15",
        "--estimate",
        "60",
    };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    const create = result.command.create;
    try std.testing.expectEqualStrings("Fix login bug", create.title);
    try std.testing.expectEqualStrings("OAuth fails for Google", create.description.?);
    try std.testing.expectEqualStrings("bug", create.issue_type.?);
    try std.testing.expectEqualStrings("high", create.priority.?);
    try std.testing.expectEqualStrings("alice", create.assignee.?);
    try std.testing.expectEqualStrings("2024-02-15", create.due.?);
    try std.testing.expectEqual(@as(i32, 60), create.estimate.?);
}

test "parse q (quick) command" {
    const args = [_][]const u8{ "q", "Quick issue" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .q);
    try std.testing.expectEqualStrings("Quick issue", result.command.q.title);
}

test "parse show command" {
    const args = [_][]const u8{ "show", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .show);
    try std.testing.expectEqualStrings("bd-abc123", result.command.show.id);
}

test "parse show command missing id returns error" {
    const args = [_][]const u8{"show"};
    var parser = ArgParser.init(std.testing.allocator, &args);

    try std.testing.expectError(error.MissingRequiredArgument, parser.parse());
}

test "parse update command" {
    const args = [_][]const u8{ "update", "bd-abc123", "--title", "New title" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .update);
    try std.testing.expectEqualStrings("bd-abc123", result.command.update.id);
    try std.testing.expectEqualStrings("New title", result.command.update.title.?);
}

test "parse close command" {
    const args = [_][]const u8{ "close", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .close);
    try std.testing.expectEqualStrings("bd-abc123", result.command.close.id);
}

test "parse close command with reason" {
    const args = [_][]const u8{ "close", "bd-abc123", "--reason", "Fixed in PR #42" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .close);
    try std.testing.expectEqualStrings("bd-abc123", result.command.close.id);
    try std.testing.expectEqualStrings("Fixed in PR #42", result.command.close.reason.?);
}

test "parse reopen command" {
    const args = [_][]const u8{ "reopen", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .reopen);
    try std.testing.expectEqualStrings("bd-abc123", result.command.reopen.id);
}

test "parse delete command" {
    const args_arr = [_][]const u8{ "delete", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args_arr);
    const result = try parser.parse();

    try std.testing.expect(result.command == .delete);
    try std.testing.expectEqualStrings("bd-abc123", result.command.delete.id.?);
}

test "parse delete command with flags" {
    const args_arr = [_][]const u8{ "delete", "bd-abc123", "--cascade", "--dry-run" };
    var parser = ArgParser.init(std.testing.allocator, &args_arr);
    const result = try parser.parse();

    try std.testing.expect(result.command == .delete);
    try std.testing.expectEqualStrings("bd-abc123", result.command.delete.id.?);
    try std.testing.expect(result.command.delete.cascade);
    try std.testing.expect(result.command.delete.dry_run);
    try std.testing.expect(!result.command.delete.hard);
}

test "parse delete command with from-file" {
    const args_arr = [_][]const u8{ "delete", "--from-file", "ids.txt" };
    var parser = ArgParser.init(std.testing.allocator, &args_arr);
    const result = try parser.parse();

    try std.testing.expect(result.command == .delete);
    try std.testing.expect(result.command.delete.id == null);
    try std.testing.expectEqualStrings("ids.txt", result.command.delete.from_file.?);
}

test "parse list command" {
    const args = [_][]const u8{"list"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .list);
}

test "parse list command with filters" {
    const args = [_][]const u8{ "list", "--status", "open", "--priority", "high", "--limit", "10" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    const list = result.command.list;
    try std.testing.expectEqualStrings("open", list.status.?);
    try std.testing.expectEqualStrings("high", list.priority.?);
    try std.testing.expectEqual(@as(u32, 10), list.limit.?);
}

test "parse list --all flag" {
    const args = [_][]const u8{ "list", "--all" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command.list.all);
}

test "parse list --sort flag" {
    const args = [_][]const u8{ "list", "--sort", "priority" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(SortField.priority, result.command.list.sort);
    try std.testing.expect(result.command.list.sort_desc); // default
}

test "parse list --sort with --asc" {
    const args = [_][]const u8{ "list", "--sort", "updated", "--asc" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(SortField.updated_at, result.command.list.sort);
    try std.testing.expect(!result.command.list.sort_desc);
}

test "parse list --sort with --desc" {
    const args = [_][]const u8{ "list", "--sort", "created", "--desc" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(SortField.created_at, result.command.list.sort);
    try std.testing.expect(result.command.list.sort_desc);
}

test "SortField.fromString" {
    try std.testing.expectEqual(SortField.created_at, SortField.fromString("created").?);
    try std.testing.expectEqual(SortField.created_at, SortField.fromString("created_at").?);
    try std.testing.expectEqual(SortField.updated_at, SortField.fromString("updated").?);
    try std.testing.expectEqual(SortField.updated_at, SortField.fromString("updated_at").?);
    try std.testing.expectEqual(SortField.priority, SortField.fromString("priority").?);
    try std.testing.expectEqual(SortField.priority, SortField.fromString("PRIORITY").?);
    try std.testing.expectEqual(@as(?SortField, null), SortField.fromString("invalid"));
}

test "parse ready command" {
    const args = [_][]const u8{"ready"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .ready);
}

test "parse blocked command" {
    const args = [_][]const u8{"blocked"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .blocked);
}

test "parse search command" {
    const args = [_][]const u8{ "search", "login" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .search);
    try std.testing.expectEqualStrings("login", result.command.search.query);
}

test "parse search command missing query returns error" {
    const args = [_][]const u8{"search"};
    var parser = ArgParser.init(std.testing.allocator, &args);

    try std.testing.expectError(error.MissingRequiredArgument, parser.parse());
}

test "parse stale command" {
    const args = [_][]const u8{"stale"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .stale);
    try std.testing.expectEqual(@as(u32, 30), result.command.stale.days);
}

test "parse stale command with days" {
    const args = [_][]const u8{ "stale", "--days", "7" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(@as(u32, 7), result.command.stale.days);
}

test "parse count command" {
    const args = [_][]const u8{"count"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .count);
}

test "parse count command with group-by" {
    const args = [_][]const u8{ "count", "--group-by", "status" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("status", result.command.count.group_by.?);
}

test "parse dep add command" {
    const args = [_][]const u8{ "dep", "add", "bd-child", "bd-parent" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .dep);
    const add = result.command.dep.subcommand.add;
    try std.testing.expectEqualStrings("bd-child", add.child);
    try std.testing.expectEqualStrings("bd-parent", add.parent);
    try std.testing.expectEqualStrings("blocks", add.dep_type);
}

test "parse dep add command with type" {
    const args = [_][]const u8{ "dep", "add", "bd-child", "bd-parent", "--type", "relates_to" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    const add = result.command.dep.subcommand.add;
    try std.testing.expectEqualStrings("relates_to", add.dep_type);
}

test "parse dep remove command" {
    const args = [_][]const u8{ "dep", "remove", "bd-child", "bd-parent" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    const remove = result.command.dep.subcommand.remove;
    try std.testing.expectEqualStrings("bd-child", remove.child);
    try std.testing.expectEqualStrings("bd-parent", remove.parent);
}

test "parse dep list command" {
    const args = [_][]const u8{ "dep", "list", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("bd-abc123", result.command.dep.subcommand.list.id);
}

test "parse dep tree command" {
    const args = [_][]const u8{ "dep", "tree", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("bd-abc123", result.command.dep.subcommand.tree.id);
}

test "parse dep cycles command" {
    const args = [_][]const u8{ "dep", "cycles" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command.dep.subcommand == .cycles);
}

test "parse dep add command with metadata" {
    const input = [_][]const u8{ "dep", "add", "bd-child", "bd-parent", "--type", "blocks", "--metadata", "{\"reason\":\"needs API\"}" };
    var parser = ArgParser.init(std.testing.allocator, &input);
    const result = try parser.parse();

    const add = result.command.dep.subcommand.add;
    try std.testing.expectEqualStrings("bd-child", add.child);
    try std.testing.expectEqualStrings("bd-parent", add.parent);
    try std.testing.expectEqualStrings("blocks", add.dep_type);
    try std.testing.expectEqualStrings("{\"reason\":\"needs API\"}", add.metadata.?);
}

test "parse dep list command with direction down" {
    const input = [_][]const u8{ "dep", "list", "bd-abc123", "--direction", "down" };
    var parser = ArgParser.init(std.testing.allocator, &input);
    const result = try parser.parse();

    const list = result.command.dep.subcommand.list;
    try std.testing.expectEqualStrings("bd-abc123", list.id);
    try std.testing.expectEqual(DepDirection.down, list.direction);
}

test "parse dep list command with direction up" {
    const input = [_][]const u8{ "dep", "list", "bd-abc123", "--direction", "up" };
    var parser = ArgParser.init(std.testing.allocator, &input);
    const result = try parser.parse();

    const list = result.command.dep.subcommand.list;
    try std.testing.expectEqual(DepDirection.up, list.direction);
}

test "parse dep tree command with format mermaid" {
    const input = [_][]const u8{ "dep", "tree", "bd-abc123", "--format", "mermaid" };
    var parser = ArgParser.init(std.testing.allocator, &input);
    const result = try parser.parse();

    const tree = result.command.dep.subcommand.tree;
    try std.testing.expectEqualStrings("bd-abc123", tree.id);
    try std.testing.expectEqual(TreeFormat.mermaid, tree.format);
}

test "parse label add command" {
    const args = [_][]const u8{ "label", "add", "bd-abc123", "urgent", "backend" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();
    defer std.testing.allocator.free(result.command.label.subcommand.add.labels);

    const add = result.command.label.subcommand.add;
    try std.testing.expectEqualStrings("bd-abc123", add.id);
    try std.testing.expectEqual(@as(usize, 2), add.labels.len);
    try std.testing.expectEqualStrings("urgent", add.labels[0]);
    try std.testing.expectEqualStrings("backend", add.labels[1]);
}

test "parse label remove command" {
    const args = [_][]const u8{ "label", "remove", "bd-abc123", "old-label" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();
    defer std.testing.allocator.free(result.command.label.subcommand.remove.labels);

    const remove = result.command.label.subcommand.remove;
    try std.testing.expectEqualStrings("bd-abc123", remove.id);
    try std.testing.expectEqual(@as(usize, 1), remove.labels.len);
    try std.testing.expectEqualStrings("old-label", remove.labels[0]);
}

test "parse label list command" {
    const args = [_][]const u8{ "label", "list", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("bd-abc123", result.command.label.subcommand.list.id);
}

test "parse label list-all command" {
    const args = [_][]const u8{ "label", "list-all" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command.label.subcommand == .list_all);
}

test "parse label rename command" {
    const input = [_][]const u8{ "label", "rename", "old-label", "new-label" };
    var parser = ArgParser.init(std.testing.allocator, &input);
    const result = try parser.parse();

    const rename = result.command.label.subcommand.rename;
    try std.testing.expectEqualStrings("old-label", rename.old_name);
    try std.testing.expectEqualStrings("new-label", rename.new_name);
}

test "parse label mv command (alias for rename)" {
    const input = [_][]const u8{ "label", "mv", "old-name", "new-name" };
    var parser = ArgParser.init(std.testing.allocator, &input);
    const result = try parser.parse();

    const rename = result.command.label.subcommand.rename;
    try std.testing.expectEqualStrings("old-name", rename.old_name);
    try std.testing.expectEqualStrings("new-name", rename.new_name);
}

test "parse comments add command" {
    const args = [_][]const u8{ "comments", "add", "bd-abc123", "This is a comment" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    const add = result.command.comments.subcommand.add;
    try std.testing.expectEqualStrings("bd-abc123", add.id);
    try std.testing.expectEqualStrings("This is a comment", add.text);
}

test "parse comments list command" {
    const args = [_][]const u8{ "comments", "list", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("bd-abc123", result.command.comments.subcommand.list.id);
}

test "parse history command" {
    const args = [_][]const u8{ "history", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .history);
    try std.testing.expectEqualStrings("bd-abc123", result.command.history.id);
}

test "parse audit command" {
    const args = [_][]const u8{"audit"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .audit);
}

test "parse audit command with limit" {
    const args = [_][]const u8{ "audit", "--limit", "50" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    var result = try parser.parse();
    defer result.deinit(std.testing.allocator);

    switch (result.command.audit.subcommand) {
        .list => |list_args| try std.testing.expectEqual(@as(u32, 50), list_args.limit.?),
        else => try std.testing.expect(false),
    }
}

test "parse sync command" {
    const args = [_][]const u8{"sync"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .sync);
    try std.testing.expect(!result.command.sync.flush_only);
    try std.testing.expect(!result.command.sync.import_only);
}

test "parse sync --flush-only" {
    const args = [_][]const u8{ "sync", "--flush-only" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command.sync.flush_only);
    try std.testing.expect(!result.command.sync.import_only);
}

test "parse sync --import-only" {
    const args = [_][]const u8{ "sync", "--import-only" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(!result.command.sync.flush_only);
    try std.testing.expect(result.command.sync.import_only);
}

test "parse completions command with bash" {
    const args = [_][]const u8{ "completions", "bash" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .completions);
    try std.testing.expectEqual(Shell.bash, result.command.completions.shell);
}

test "parse completions command with zsh" {
    const args = [_][]const u8{ "completions", "zsh" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(Shell.zsh, result.command.completions.shell);
}

test "parse completions command with fish" {
    const args = [_][]const u8{ "completions", "fish" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(Shell.fish, result.command.completions.shell);
}

test "parse completions command with powershell" {
    const args = [_][]const u8{ "completions", "powershell" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqual(Shell.powershell, result.command.completions.shell);
}

test "parse completions command with invalid shell returns error" {
    const args = [_][]const u8{ "completions", "invalid" };
    var parser = ArgParser.init(std.testing.allocator, &args);

    try std.testing.expectError(error.InvalidShell, parser.parse());
}

test "parse completions command missing shell returns error" {
    const args = [_][]const u8{"completions"};
    var parser = ArgParser.init(std.testing.allocator, &args);

    try std.testing.expectError(error.MissingRequiredArgument, parser.parse());
}

test "parse config list (default)" {
    const args = [_][]const u8{"config"};
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .config);
    try std.testing.expect(result.command.config.subcommand == .list);
}

test "parse config get" {
    const args = [_][]const u8{ "config", "get", "id.prefix" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expectEqualStrings("id.prefix", result.command.config.subcommand.get.key);
}

test "parse config set" {
    const args = [_][]const u8{ "config", "set", "id.prefix", "proj" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    const set = result.command.config.subcommand.set;
    try std.testing.expectEqualStrings("id.prefix", set.key);
    try std.testing.expectEqualStrings("proj", set.value);
}

test "command aliases work" {
    // Test 'add' as alias for 'create'
    {
        const args = [_][]const u8{ "add", "Test title" };
        var parser = ArgParser.init(std.testing.allocator, &args);
        const result = try parser.parse();
        try std.testing.expect(result.command == .create);
    }

    // Test 'ls' as alias for 'list'
    {
        const args = [_][]const u8{"ls"};
        var parser = ArgParser.init(std.testing.allocator, &args);
        const result = try parser.parse();
        try std.testing.expect(result.command == .list);
    }

    // Test 'rm' as alias for 'delete'
    {
        const args = [_][]const u8{ "rm", "bd-abc" };
        var parser = ArgParser.init(std.testing.allocator, &args);
        const result = try parser.parse();
        try std.testing.expect(result.command == .delete);
    }

    // Test 'done' as alias for 'close'
    {
        const args = [_][]const u8{ "done", "bd-abc" };
        var parser = ArgParser.init(std.testing.allocator, &args);
        const result = try parser.parse();
        try std.testing.expect(result.command == .close);
    }

    // Test 'find' as alias for 'search'
    {
        const args = [_][]const u8{ "find", "query" };
        var parser = ArgParser.init(std.testing.allocator, &args);
        const result = try parser.parse();
        try std.testing.expect(result.command == .search);
    }
}

test "parse epic create command" {
    const args = [_][]const u8{ "epic", "create", "Test Epic Title" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .epic);
    const create = result.command.epic.subcommand.create;
    try std.testing.expectEqualStrings("Test Epic Title", create.title);
}

test "parse epic create with options" {
    const args = [_][]const u8{ "epic", "create", "My Epic", "--description", "Epic description", "--priority", "high" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .epic);
    const create = result.command.epic.subcommand.create;
    try std.testing.expectEqualStrings("My Epic", create.title);
    try std.testing.expectEqualStrings("Epic description", create.description.?);
    try std.testing.expectEqualStrings("high", create.priority.?);
}

test "parse epic add command" {
    const args = [_][]const u8{ "epic", "add", "bd-epic1", "bd-task1" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .epic);
    const add = result.command.epic.subcommand.add;
    try std.testing.expectEqualStrings("bd-epic1", add.epic_id);
    try std.testing.expectEqualStrings("bd-task1", add.issue_id);
}

test "parse epic remove command" {
    const args = [_][]const u8{ "epic", "remove", "bd-epic1", "bd-task1" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .epic);
    const remove = result.command.epic.subcommand.remove;
    try std.testing.expectEqualStrings("bd-epic1", remove.epic_id);
    try std.testing.expectEqualStrings("bd-task1", remove.issue_id);
}

test "parse epic list command" {
    const args = [_][]const u8{ "epic", "list", "bd-epic1" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .epic);
    try std.testing.expectEqualStrings("bd-epic1", result.command.epic.subcommand.list.epic_id);
}

test "parse epic command missing subcommand" {
    const args = [_][]const u8{"epic"};
    var parser = ArgParser.init(std.testing.allocator, &args);

    try std.testing.expectError(error.MissingRequiredArgument, parser.parse());
}

test "Shell.fromString handles case insensitivity" {
    try std.testing.expectEqual(Shell.bash, Shell.fromString("BASH").?);
    try std.testing.expectEqual(Shell.zsh, Shell.fromString("ZSH").?);
    try std.testing.expectEqual(Shell.fish, Shell.fromString("Fish").?);
    try std.testing.expectEqual(Shell.powershell, Shell.fromString("PowerShell").?);
    try std.testing.expectEqual(Shell.powershell, Shell.fromString("ps").?);
}

test "GlobalOptions.isStructuredOutput" {
    // Default: neither json nor toon
    const default_opts = GlobalOptions{};
    try std.testing.expect(!default_opts.isStructuredOutput());

    // JSON mode
    const json_opts = GlobalOptions{ .json = true };
    try std.testing.expect(json_opts.isStructuredOutput());

    // TOON mode
    const toon_opts = GlobalOptions{ .toon = true };
    try std.testing.expect(toon_opts.isStructuredOutput());

    // Both (edge case)
    const both_opts = GlobalOptions{ .json = true, .toon = true };
    try std.testing.expect(both_opts.isStructuredOutput());
}

test "parse metrics command" {
    const args_list = [_][]const u8{"metrics"};
    var parser = ArgParser.init(std.testing.allocator, &args_list);
    const result = try parser.parse();

    try std.testing.expect(result.command == .metrics);
    try std.testing.expect(!result.command.metrics.reset);
}

test "parse metrics command with reset flag" {
    const args_list = [_][]const u8{ "metrics", "--reset" };
    var parser = ArgParser.init(std.testing.allocator, &args_list);
    const result = try parser.parse();

    try std.testing.expect(result.command == .metrics);
    try std.testing.expect(result.command.metrics.reset);
}

test "parse metrics command with -r flag" {
    const args_list = [_][]const u8{ "metrics", "-r" };
    var parser = ArgParser.init(std.testing.allocator, &args_list);
    const result = try parser.parse();

    try std.testing.expect(result.command == .metrics);
    try std.testing.expect(result.command.metrics.reset);
}
