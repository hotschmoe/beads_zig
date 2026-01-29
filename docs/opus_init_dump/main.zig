// src/main.zig - Entry point for bz (beads-zig)
const std = @import("std");
const cli = @import("cli/parser.zig");
const commands = @import("cli/commands.zig");
const storage = @import("storage/sqlite.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const global_flags = try cli.parseGlobalFlags(args[1..]);
    const cmd = try cli.parseCommand(args[1..]);

    const stdout = std.io.getStdOut().writer();
    var output = commands.Output.init(stdout, global_flags.json, !global_flags.no_color);

    switch (cmd) {
        .init => |c| try commands.init(allocator, c, &output),
        .create => |c| try commands.create(allocator, c, &output),
        .list => |c| try commands.list(allocator, c, &output),
        .ready => |c| try commands.ready(allocator, c, &output),
        .show => |c| try commands.show(allocator, c, &output),
        .update => |c| try commands.update(allocator, c, &output),
        .close => |c| try commands.close(allocator, c, &output),
        .sync => |c| try commands.sync(allocator, c, &output),
        .dep => |c| try commands.dep(allocator, c, &output),
        .version => try commands.version(&output),
        .help => try printUsage(),
    }
}

fn printUsage() !void {
    const usage =
        \\bz - Beads Zig - Local-first issue tracker for git repositories
        \\
        \\USAGE:
        \\    bz <command> [options]
        \\
        \\COMMANDS:
        \\    init                Initialize workspace in current directory
        \\    create <title>      Create a new issue
        \\    q <title>           Quick capture (minimal output)
        \\    list                List issues
        \\    ready               Show actionable (unblocked) issues
        \\    show <id>           Show issue details
        \\    update <id>         Update an issue
        \\    close <id>          Close an issue
        \\    reopen <id>         Reopen a closed issue
        \\    delete <id>         Delete an issue (tombstone)
        \\    search <query>      Full-text search
        \\    dep <subcommand>    Manage dependencies
        \\    label <subcommand>  Manage labels
        \\    comments <subcmd>   Manage comments
        \\    sync                Sync database with JSONL
        \\    doctor              Run diagnostics
        \\    stats               Show statistics
        \\    config              Manage configuration
        \\    version             Show version
        \\
        \\GLOBAL FLAGS:
        \\    --json              Output as JSON
        \\    --quiet, -q         Suppress output
        \\    --verbose, -v       Increase verbosity (-vv for debug)
        \\    --no-color          Disable colored output
        \\    --db <path>         Override database path
        \\
        \\EXAMPLES:
        \\    bz init
        \\    bz create "Fix login bug" --type bug --priority 1
        \\    bz list --status open --priority 0-1
        \\    bz ready
        \\    bz dep add bd-abc123 bd-def456
        \\    bz sync --flush-only
        \\
    ;
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(usage);
}

test "basic main test" {
    // Integration tests would go here
}
