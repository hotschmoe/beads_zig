//! beads_zig CLI entry point.
//!
//! Binary name: bz (beads-zig)

const std = @import("std");
const beads_zig = @import("beads_zig");
const cli = beads_zig.cli;
const output = beads_zig.output;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    run(allocator) catch |err| {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("error: ") catch {};
        stderr.writeAll(@errorName(err)) catch {};
        stderr.writeAll("\n") catch {};
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip program name
    const cmd_args = if (args.len > 1) args[1..] else args[0..0];

    var parser = cli.ArgParser.init(allocator, cmd_args);
    var result = parser.parse() catch |err| {
        return handleParseError(err, allocator);
    };
    defer result.deinit(allocator);

    try dispatch(result, allocator);
}

fn dispatch(result: cli.ParseResult, allocator: std.mem.Allocator) !void {
    switch (result.command) {
        .init => |init_args| {
            cli.runInit(init_args, result.global, allocator) catch |err| switch (err) {
                error.AlreadyInitialized => std.process.exit(1),
                else => return err,
            };
        },
        .create => |create_args| {
            cli.runCreate(create_args, result.global, allocator) catch |err| switch (err) {
                error.EmptyTitle, error.TitleTooLong, error.InvalidPriority, error.WorkspaceNotInitialized => std.process.exit(1),
                else => return err,
            };
        },
        .q => |quick_args| {
            cli.runQuick(quick_args, result.global, allocator) catch |err| switch (err) {
                error.EmptyTitle, error.TitleTooLong, error.InvalidPriority, error.WorkspaceNotInitialized => std.process.exit(1),
                else => return err,
            };
        },
        .list => |list_args| {
            cli.runList(list_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.InvalidFilter => std.process.exit(1),
                else => return err,
            };
        },
        .show => |show_args| {
            cli.runShow(show_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound => std.process.exit(1),
                else => return err,
            };
        },
        .update => |update_args| {
            cli.runUpdate(update_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.InvalidArgument => std.process.exit(1),
                else => return err,
            };
        },
        .close => |close_args| {
            cli.runClose(close_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.AlreadyClosed => std.process.exit(1),
                else => return err,
            };
        },
        .reopen => |reopen_args| {
            cli.runReopen(reopen_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.NotClosed => std.process.exit(1),
                else => return err,
            };
        },
        .delete => |delete_args| {
            cli.runDelete(delete_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.AlreadyDeleted => std.process.exit(1),
                else => return err,
            };
        },
        .ready => |ready_args| {
            cli.runReady(ready_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized => std.process.exit(1),
                else => return err,
            };
        },
        .blocked => |blocked_args| {
            cli.runBlocked(blocked_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized => std.process.exit(1),
                else => return err,
            };
        },
        .dep => |dep_args| {
            cli.runDep(dep_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.CycleDetected, error.SelfDependency => std.process.exit(1),
                else => return err,
            };
        },
        .graph => |graph_args| {
            cli.runGraph(graph_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound => std.process.exit(1),
                else => return err,
            };
        },
        .epic => |epic_args| {
            cli.runEpic(epic_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.EpicNotFound, error.IssueNotFound, error.NotAnEpic, error.EmptyTitle, error.TitleTooLong, error.InvalidPriority, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .sync => |sync_args| {
            cli.runSync(sync_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.MergeConflictDetected, error.ImportError, error.ExportError => std.process.exit(1),
                else => return err,
            };
        },
        .search => |search_args| {
            cli.runSearch(search_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized => std.process.exit(1),
                else => return err,
            };
        },
        .stale => |stale_args| {
            cli.runStale(stale_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .count => |count_args| {
            cli.runCount(count_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .defer_cmd => |defer_args| {
            cli.runDefer(defer_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.AlreadyDeferred, error.InvalidDate => std.process.exit(1),
                else => return err,
            };
        },
        .undefer => |undefer_args| {
            cli.runUndefer(undefer_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound => std.process.exit(1),
                else => return err,
            };
        },
        .help => |_| {
            const stdout = std.fs.File.stdout();
            stdout.writeAll(
                \\Agent-first issue tracker (SQLite + JSONL)
                \\
                \\Usage: bz [OPTIONS] <COMMAND>
                \\
                \\Commands:
                \\  init         Initialize a beads workspace
                \\  create       Create a new issue
                \\  q            Quick capture (create issue, print ID only)
                \\  list         List issues
                \\  show         Show issue details
                \\  update       Update an issue
                \\  close        Close an issue
                \\  reopen       Reopen an issue
                \\  delete       Delete an issue (creates tombstone)
                \\  ready        List ready issues (unblocked, not deferred)
                \\  blocked      List blocked issues
                \\  search       Search issues
                \\  dep          Manage dependencies
                \\  label        Manage labels
                \\  comments     Manage comments
                \\  stats        Show project statistics
                \\  count        Count issues with optional grouping
                \\  stale        List stale issues
                \\  lint         Check issues for consistency
                \\  defer        Defer issues (schedule for later)
                \\  undefer      Undefer issues (make ready again)
                \\  config       Configuration management
                \\  sync         Sync database with JSONL file (export or import)
                \\  doctor       Run read-only diagnostics
                \\  info         Show diagnostic metadata about the workspace
                \\  schema       Emit JSON Schemas for bz output types
                \\  where        Show the active .beads directory
                \\  version      Show version information
                \\  completions  Generate shell completions
                \\  audit        View audit log
                \\  history      Show issue history
                \\  orphans      List orphan issues
                \\  changelog    Generate changelog from closed issues
                \\  help         Print this message or the help of the given subcommand(s)
                \\
                \\Options:
                \\      --json       Output as JSON
                \\      --toon       Output in TOON format
                \\  -q, --quiet      Quiet mode (no output except errors)
                \\  -v, --verbose    Increase logging verbosity
                \\      --no-color   Disable colored output
                \\      --data       Override .beads/ directory
                \\  -h, --help       Print help
                \\  -V, --version    Print version
                \\
            ) catch {};
        },
        .version => {
            _ = cli.runVersion(result.global, allocator) catch |err| switch (err) {
                error.WriteError => std.process.exit(1),
            };
        },
        .schema => {
            _ = cli.runSchema(result.global, allocator) catch |err| switch (err) {
                error.WriteError, error.OutOfMemory => std.process.exit(1),
            };
        },
        .completions => |comp_args| {
            _ = cli.runCompletions(comp_args, result.global, allocator) catch |err| switch (err) {
                error.WriteError => std.process.exit(1),
            };
        },
        .info => {
            cli.runInfo(result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .stats => |stats_args| {
            cli.runStats(stats_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError, error.GitError => std.process.exit(1),
                else => return err,
            };
        },
        .doctor => {
            cli.runDoctor(result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .config => |config_args| {
            cli.runConfig(config_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.ConfigNotFound, error.InvalidKey, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .orphans => |orphans_args| {
            cli.runOrphans(orphans_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .lint => |lint_args| {
            cli.runLint(lint_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .label => |label_args| {
            cli.runLabel(label_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .comments => |comments_args| {
            cli.runComments(comments_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.EmptyCommentBody, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .history => |history_args| {
            cli.runHistory(history_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.IssueNotFound, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .audit => |audit_args| {
            cli.runAudit(audit_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError, error.InvalidKind, error.EntryNotFound => std.process.exit(1),
                else => return err,
            };
        },
        .changelog => |changelog_args| {
            cli.runChangelog(changelog_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.InvalidDateFormat, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .query => |query_args| {
            cli.runQuery(query_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.QueryNotFound, error.QueryAlreadyExists, error.InvalidQueryName, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .upgrade => |upgrade_args| {
            cli.runUpgrade(upgrade_args, result.global, allocator) catch |err| switch (err) {
                error.NetworkError, error.UnsupportedPlatform, error.WriteError => std.process.exit(1),
                else => return err,
            };
        },
        .agents => |agents_args| {
            cli.runAgents(agents_args, result.global, allocator) catch |err| switch (err) {
                error.WorkspaceNotInitialized, error.StorageError => std.process.exit(1),
                else => return err,
            };
        },
        .where => {
            _ = cli.runWhere(result.global, allocator) catch |err| switch (err) {
                error.WriteError, error.WorkspaceNotFound => std.process.exit(1),
            };
        },
    }
}

fn handleParseError(err: cli.ParseError, allocator: std.mem.Allocator) !void {
    var out = output.Output.init(allocator, .{});
    switch (err) {
        cli.ParseError.UnknownCommand => try out.err("unknown command. Run 'bz help' for usage.", .{}),
        cli.ParseError.MissingRequiredArgument => try out.err("missing required argument", .{}),
        cli.ParseError.InvalidArgument => try out.err("invalid argument value", .{}),
        cli.ParseError.UnknownFlag => try out.err("unknown flag", .{}),
        cli.ParseError.MissingFlagValue => try out.err("flag requires a value", .{}),
        cli.ParseError.InvalidFlagValue => try out.err("invalid flag value", .{}),
        cli.ParseError.InvalidShell => try out.err("invalid shell type", .{}),
        cli.ParseError.UnknownSubcommand => try out.err("unknown subcommand", .{}),
    }
    std.process.exit(1);
}

test "library imports compile" {
    // Verify all modules are accessible
    _ = beads_zig.cli;
    _ = beads_zig.storage;
    _ = beads_zig.models;
    _ = beads_zig.sync;
    _ = beads_zig.id;
    _ = beads_zig.config;
    _ = beads_zig.output;
}
