//! CLI argument parsing for beads_zig.
//!
//! Parses command-line arguments into structured data for command dispatch.
//! Supports global flags, subcommands, and subcommand-specific arguments.

const std = @import("std");

/// Global CLI options that apply to all commands.
pub const GlobalOptions = struct {
    json: bool = false,
    quiet: bool = false,
    verbose: u8 = 0,
    no_color: bool = false,
    data_path: ?[]const u8 = null,
    actor: ?[]const u8 = null,
    lock_timeout: u32 = 5000,
    no_auto_flush: bool = false,
    no_auto_import: bool = false,
};

/// All available subcommands.
pub const Command = union(enum) {
    // Workspace
    init: InitArgs,
    info: void,
    stats: void,
    doctor: void,
    config: ConfigArgs,

    // Issue CRUD
    create: CreateArgs,
    q: QuickArgs,
    show: ShowArgs,
    update: UpdateArgs,
    close: CloseArgs,
    reopen: ReopenArgs,
    delete: DeleteArgs,

    // Query
    list: ListArgs,
    ready: ReadyArgs,
    blocked: BlockedArgs,
    search: SearchArgs,
    stale: StaleArgs,
    count: CountArgs,

    // Dependencies
    dep: DepArgs,

    // Labels
    label: LabelArgs,

    // Comments
    comments: CommentsArgs,

    // Audit
    history: HistoryArgs,
    audit: AuditArgs,

    // Sync
    sync: SyncArgs,

    // System
    version: void,
    schema: void,
    completions: CompletionsArgs,

    // Help
    help: HelpArgs,
};

/// Init command arguments.
pub const InitArgs = struct {
    prefix: []const u8 = "bd",
};

/// Create command arguments.
pub const CreateArgs = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    labels: []const []const u8 = &[_][]const u8{},
    deps: []const []const u8 = &[_][]const u8{},
    due: ?[]const u8 = null,
    estimate: ?i32 = null,
};

/// Quick capture command arguments.
pub const QuickArgs = struct {
    title: []const u8,
    priority: ?[]const u8 = null,
};

/// Show command arguments.
pub const ShowArgs = struct {
    id: []const u8,
};

/// Update command arguments.
pub const UpdateArgs = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

/// Close command arguments.
pub const CloseArgs = struct {
    id: []const u8,
    reason: ?[]const u8 = null,
};

/// Reopen command arguments.
pub const ReopenArgs = struct {
    id: []const u8,
};

/// Delete command arguments.
pub const DeleteArgs = struct {
    id: []const u8,
};

/// List command arguments.
pub const ListArgs = struct {
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    issue_type: ?[]const u8 = null,
    assignee: ?[]const u8 = null,
    label: ?[]const u8 = null,
    limit: ?u32 = null,
    all: bool = false,
};

/// Ready command arguments.
pub const ReadyArgs = struct {
    limit: ?u32 = null,
};

/// Blocked command arguments.
pub const BlockedArgs = struct {
    limit: ?u32 = null,
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

/// Dependency subcommand variants.
pub const DepSubcommand = union(enum) {
    add: struct {
        child: []const u8,
        parent: []const u8,
        dep_type: []const u8 = "blocks",
    },
    remove: struct {
        child: []const u8,
        parent: []const u8,
    },
    list: struct {
        id: []const u8,
    },
    tree: struct {
        id: []const u8,
    },
    cycles: void,
};

/// Dependency command arguments.
pub const DepArgs = struct {
    subcommand: DepSubcommand,
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

/// Audit command arguments.
pub const AuditArgs = struct {
    limit: ?u32 = null,
};

/// Sync command arguments.
pub const SyncArgs = struct {
    flush_only: bool = false,
    import_only: bool = false,
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

/// Result of parsing command-line arguments.
pub const ParseResult = struct {
    global: GlobalOptions,
    command: Command,
};

/// Errors that can occur during argument parsing.
pub const ParseError = error{
    UnknownCommand,
    MissingRequiredArgument,
    InvalidArgument,
    UnknownFlag,
    MissingFlagValue,
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
    pub fn parse(self: *Self) ParseError!ParseResult {
        var global = GlobalOptions{};

        // Parse global flags first
        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.startsWith(u8, arg, "-")) {
                if (self.parseGlobalFlag(&global)) |consumed| {
                    if (!consumed) break;
                } else |_| {
                    break;
                }
            } else {
                break;
            }
        }

        // Parse subcommand
        const cmd_str = self.next() orelse {
            return .{
                .global = global,
                .command = .{ .help = .{ .topic = null } },
            };
        };

        const command = try self.parseCommand(cmd_str);

        return .{
            .global = global,
            .command = command,
        };
    }

    fn parseGlobalFlag(self: *Self, global: *GlobalOptions) ParseError!bool {
        const arg = self.next().?;

        if (std.mem.eql(u8, arg, "--json")) {
            global.json = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            global.quiet = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            global.verbose +|= 1;
            return true;
        }
        if (std.mem.eql(u8, arg, "-vv")) {
            global.verbose +|= 2;
            return true;
        }
        if (std.mem.eql(u8, arg, "--no-color")) {
            global.no_color = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "--no-auto-flush")) {
            global.no_auto_flush = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "--no-auto-import")) {
            global.no_auto_import = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "--db")) {
            global.data_path = self.next() orelse return error.MissingFlagValue;
            return true;
        }
        if (std.mem.eql(u8, arg, "--actor")) {
            global.actor = self.next() orelse return error.MissingFlagValue;
            return true;
        }
        if (std.mem.eql(u8, arg, "--lock-timeout")) {
            const val = self.next() orelse return error.MissingFlagValue;
            global.lock_timeout = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            return true;
        }

        // Put back if not recognized
        self.index -= 1;
        return error.UnknownFlag;
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
            return .{ .stats = {} };
        }
        if (std.mem.eql(u8, cmd, "doctor")) {
            return .{ .doctor = {} };
        }
        if (std.mem.eql(u8, cmd, "config")) {
            return .{ .config = try self.parseConfigArgs() };
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

        // Dependencies
        if (std.mem.eql(u8, cmd, "dep") or std.mem.eql(u8, cmd, "deps") or std.mem.eql(u8, cmd, "dependency")) {
            return .{ .dep = try self.parseDepArgs() };
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

        // Sync
        if (std.mem.eql(u8, cmd, "sync") or std.mem.eql(u8, cmd, "flush") or std.mem.eql(u8, cmd, "export")) {
            return .{ .sync = try self.parseSyncArgs() };
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

        // Help
        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            return .{ .help = try self.parseHelpArgs() };
        }

        return error.UnknownCommand;
    }

    fn parseInitArgs(self: *Self) ParseError!InitArgs {
        var args = InitArgs{};
        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--prefix") or std.mem.eql(u8, arg, "-p")) {
                _ = self.next();
                args.prefix = self.next() orelse return error.MissingFlagValue;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                args.prefix = self.next().?;
            } else {
                break;
            }
        }
        return args;
    }

    fn parseCreateArgs(self: *Self) ParseError!CreateArgs {
        var args = CreateArgs{ .title = undefined };
        var title_set = false;
        var labels: std.ArrayListUnmanaged([]const u8) = .{};
        var deps: std.ArrayListUnmanaged([]const u8) = .{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--description") or std.mem.eql(u8, arg, "-d")) {
                _ = self.next();
                args.description = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--type") or std.mem.eql(u8, arg, "-t")) {
                _ = self.next();
                args.issue_type = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--priority") or std.mem.eql(u8, arg, "-p")) {
                _ = self.next();
                args.priority = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "-a")) {
                _ = self.next();
                args.assignee = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--label") or std.mem.eql(u8, arg, "-l")) {
                _ = self.next();
                labels.append(self.allocator, self.next() orelse return error.MissingFlagValue) catch return error.InvalidArgument;
            } else if (std.mem.eql(u8, arg, "--dep") or std.mem.eql(u8, arg, "--depends-on")) {
                _ = self.next();
                deps.append(self.allocator, self.next() orelse return error.MissingFlagValue) catch return error.InvalidArgument;
            } else if (std.mem.eql(u8, arg, "--due")) {
                _ = self.next();
                args.due = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--estimate") or std.mem.eql(u8, arg, "-e")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.estimate = std.fmt.parseInt(i32, val, 10) catch return error.InvalidArgument;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (!title_set) {
                    args.title = self.next().?;
                    title_set = true;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (!title_set) {
            return error.MissingRequiredArgument;
        }

        if (labels.items.len > 0) {
            args.labels = labels.toOwnedSlice(self.allocator) catch return error.InvalidArgument;
        }
        if (deps.items.len > 0) {
            args.deps = deps.toOwnedSlice(self.allocator) catch return error.InvalidArgument;
        }

        return args;
    }

    fn parseQuickArgs(self: *Self) ParseError!QuickArgs {
        var args = QuickArgs{ .title = undefined };
        var title_set = false;

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--priority") or std.mem.eql(u8, arg, "-p")) {
                _ = self.next();
                args.priority = self.next() orelse return error.MissingFlagValue;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (!title_set) {
                    args.title = self.next().?;
                    title_set = true;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (!title_set) {
            return error.MissingRequiredArgument;
        }

        return args;
    }

    fn parseShowArgs(self: *Self) ParseError!ShowArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        return .{ .id = id };
    }

    fn parseUpdateArgs(self: *Self) ParseError!UpdateArgs {
        var args = UpdateArgs{ .id = undefined };
        var id_set = false;

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--title")) {
                _ = self.next();
                args.title = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--description") or std.mem.eql(u8, arg, "-d")) {
                _ = self.next();
                args.description = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--type") or std.mem.eql(u8, arg, "-t")) {
                _ = self.next();
                args.issue_type = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--priority") or std.mem.eql(u8, arg, "-p")) {
                _ = self.next();
                args.priority = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "-a")) {
                _ = self.next();
                args.assignee = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--status") or std.mem.eql(u8, arg, "-s")) {
                _ = self.next();
                args.status = self.next() orelse return error.MissingFlagValue;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (!id_set) {
                    args.id = self.next().?;
                    id_set = true;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (!id_set) {
            return error.MissingRequiredArgument;
        }

        return args;
    }

    fn parseCloseArgs(self: *Self) ParseError!CloseArgs {
        var args = CloseArgs{ .id = undefined };
        var id_set = false;

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--reason") or std.mem.eql(u8, arg, "-r")) {
                _ = self.next();
                args.reason = self.next() orelse return error.MissingFlagValue;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (!id_set) {
                    args.id = self.next().?;
                    id_set = true;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (!id_set) {
            return error.MissingRequiredArgument;
        }

        return args;
    }

    fn parseReopenArgs(self: *Self) ParseError!ReopenArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        return .{ .id = id };
    }

    fn parseDeleteArgs(self: *Self) ParseError!DeleteArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        return .{ .id = id };
    }

    fn parseListArgs(self: *Self) ParseError!ListArgs {
        var args = ListArgs{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--status") or std.mem.eql(u8, arg, "-s")) {
                _ = self.next();
                args.status = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--priority") or std.mem.eql(u8, arg, "-p")) {
                _ = self.next();
                args.priority = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--type") or std.mem.eql(u8, arg, "-t")) {
                _ = self.next();
                args.issue_type = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--assignee") or std.mem.eql(u8, arg, "-a")) {
                _ = self.next();
                args.assignee = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--label") or std.mem.eql(u8, arg, "-l")) {
                _ = self.next();
                args.label = self.next() orelse return error.MissingFlagValue;
            } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-n")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.limit = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-A")) {
                _ = self.next();
                args.all = true;
            } else {
                break;
            }
        }

        return args;
    }

    fn parseReadyArgs(self: *Self) ParseError!ReadyArgs {
        var args = ReadyArgs{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-n")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.limit = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else {
                break;
            }
        }

        return args;
    }

    fn parseBlockedArgs(self: *Self) ParseError!BlockedArgs {
        var args = BlockedArgs{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-n")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.limit = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else {
                break;
            }
        }

        return args;
    }

    fn parseSearchArgs(self: *Self) ParseError!SearchArgs {
        var args = SearchArgs{ .query = undefined };
        var query_set = false;

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-n")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.limit = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (!query_set) {
                    args.query = self.next().?;
                    query_set = true;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (!query_set) {
            return error.MissingRequiredArgument;
        }

        return args;
    }

    fn parseStaleArgs(self: *Self) ParseError!StaleArgs {
        var args = StaleArgs{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--days") or std.mem.eql(u8, arg, "-d")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.days = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-n")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.limit = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else {
                break;
            }
        }

        return args;
    }

    fn parseCountArgs(self: *Self) ParseError!CountArgs {
        var args = CountArgs{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--group-by") or std.mem.eql(u8, arg, "-g")) {
                _ = self.next();
                args.group_by = self.next() orelse return error.MissingFlagValue;
            } else {
                break;
            }
        }

        return args;
    }

    fn parseDepArgs(self: *Self) ParseError!DepArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "add")) {
            const child = self.next() orelse return error.MissingRequiredArgument;
            const parent = self.next() orelse return error.MissingRequiredArgument;
            var dep_type: []const u8 = "blocks";

            while (self.hasNext()) {
                const arg = self.peek().?;
                if (std.mem.eql(u8, arg, "--type") or std.mem.eql(u8, arg, "-t")) {
                    _ = self.next();
                    dep_type = self.next() orelse return error.MissingFlagValue;
                } else {
                    break;
                }
            }

            return .{ .subcommand = .{ .add = .{ .child = child, .parent = parent, .dep_type = dep_type } } };
        }

        if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
            const child = self.next() orelse return error.MissingRequiredArgument;
            const parent = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .remove = .{ .child = child, .parent = parent } } };
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .list = .{ .id = id } } };
        }

        if (std.mem.eql(u8, subcmd, "tree")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .tree = .{ .id = id } } };
        }

        if (std.mem.eql(u8, subcmd, "cycles")) {
            return .{ .subcommand = .{ .cycles = {} } };
        }

        return error.UnknownSubcommand;
    }

    fn parseLabelArgs(self: *Self) ParseError!LabelArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "add")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            var labels: std.ArrayListUnmanaged([]const u8) = .{};

            while (self.hasNext()) {
                const arg = self.peek().?;
                if (!std.mem.startsWith(u8, arg, "-")) {
                    labels.append(self.allocator, self.next().?) catch return error.InvalidArgument;
                } else {
                    break;
                }
            }

            if (labels.items.len == 0) {
                return error.MissingRequiredArgument;
            }

            return .{ .subcommand = .{ .add = .{
                .id = id,
                .labels = labels.toOwnedSlice(self.allocator) catch return error.InvalidArgument,
            } } };
        }

        if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            var labels: std.ArrayListUnmanaged([]const u8) = .{};

            while (self.hasNext()) {
                const arg = self.peek().?;
                if (!std.mem.startsWith(u8, arg, "-")) {
                    labels.append(self.allocator, self.next().?) catch return error.InvalidArgument;
                } else {
                    break;
                }
            }

            if (labels.items.len == 0) {
                return error.MissingRequiredArgument;
            }

            return .{ .subcommand = .{ .remove = .{
                .id = id,
                .labels = labels.toOwnedSlice(self.allocator) catch return error.InvalidArgument,
            } } };
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .list = .{ .id = id } } };
        }

        if (std.mem.eql(u8, subcmd, "list-all") or std.mem.eql(u8, subcmd, "all")) {
            return .{ .subcommand = .{ .list_all = {} } };
        }

        return error.UnknownSubcommand;
    }

    fn parseCommentsArgs(self: *Self) ParseError!CommentsArgs {
        const subcmd = self.next() orelse return error.MissingRequiredArgument;

        if (std.mem.eql(u8, subcmd, "add")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            const text = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .add = .{ .id = id, .text = text } } };
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            const id = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .list = .{ .id = id } } };
        }

        return error.UnknownSubcommand;
    }

    fn parseHistoryArgs(self: *Self) ParseError!HistoryArgs {
        const id = self.next() orelse return error.MissingRequiredArgument;
        return .{ .id = id };
    }

    fn parseAuditArgs(self: *Self) ParseError!AuditArgs {
        var args = AuditArgs{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-n")) {
                _ = self.next();
                const val = self.next() orelse return error.MissingFlagValue;
                args.limit = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else {
                break;
            }
        }

        return args;
    }

    fn parseSyncArgs(self: *Self) ParseError!SyncArgs {
        var args = SyncArgs{};

        while (self.hasNext()) {
            const arg = self.peek().?;
            if (std.mem.eql(u8, arg, "--flush-only") or std.mem.eql(u8, arg, "--export")) {
                _ = self.next();
                args.flush_only = true;
            } else if (std.mem.eql(u8, arg, "--import-only") or std.mem.eql(u8, arg, "--import")) {
                _ = self.next();
                args.import_only = true;
            } else {
                break;
            }
        }

        return args;
    }

    fn parseCompletionsArgs(self: *Self) ParseError!CompletionsArgs {
        const shell_str = self.next() orelse return error.MissingRequiredArgument;
        const shell = Shell.fromString(shell_str) orelse return error.InvalidShell;
        return .{ .shell = shell };
    }

    fn parseHelpArgs(self: *Self) ParseError!HelpArgs {
        return .{ .topic = self.next() };
    }

    fn parseConfigArgs(self: *Self) ParseError!ConfigArgs {
        const subcmd = self.next() orelse {
            return .{ .subcommand = .{ .list = {} } };
        };

        if (std.mem.eql(u8, subcmd, "get")) {
            const key = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .get = .{ .key = key } } };
        }

        if (std.mem.eql(u8, subcmd, "set")) {
            const key = self.next() orelse return error.MissingRequiredArgument;
            const value = self.next() orelse return error.MissingRequiredArgument;
            return .{ .subcommand = .{ .set = .{ .key = key, .value = value } } };
        }

        if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) {
            return .{ .subcommand = .{ .list = {} } };
        }

        return error.UnknownSubcommand;
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
    const args = [_][]const u8{ "delete", "bd-abc123" };
    var parser = ArgParser.init(std.testing.allocator, &args);
    const result = try parser.parse();

    try std.testing.expect(result.command == .delete);
    try std.testing.expectEqualStrings("bd-abc123", result.command.delete.id);
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
    const result = try parser.parse();

    try std.testing.expectEqual(@as(u32, 50), result.command.audit.limit.?);
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

test "Shell.fromString handles case insensitivity" {
    try std.testing.expectEqual(Shell.bash, Shell.fromString("BASH").?);
    try std.testing.expectEqual(Shell.zsh, Shell.fromString("ZSH").?);
    try std.testing.expectEqual(Shell.fish, Shell.fromString("Fish").?);
    try std.testing.expectEqual(Shell.powershell, Shell.fromString("PowerShell").?);
    try std.testing.expectEqual(Shell.powershell, Shell.fromString("ps").?);
}
