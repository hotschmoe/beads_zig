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
    const result = parser.parse() catch |err| {
        return handleParseError(err, allocator);
    };

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
        .help => |help_args| {
            try showHelp(help_args.topic, allocator);
        },
        .version => {
            try showVersion();
        },
        else => {
            var out = output.Output.init(allocator, .{
                .json = result.global.json,
                .quiet = result.global.quiet,
                .no_color = result.global.no_color,
            });
            try out.err("command not yet implemented", .{});
            std.process.exit(1);
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
        cli.ParseError.InvalidShell => try out.err("invalid shell type", .{}),
        cli.ParseError.UnknownSubcommand => try out.err("unknown subcommand", .{}),
    }
    std.process.exit(1);
}

fn showHelp(topic: ?[]const u8, allocator: std.mem.Allocator) !void {
    var out = output.Output.init(allocator, .{});
    if (topic) |t| {
        try out.println("Help for: {s}", .{t});
        try out.println("(detailed help not yet implemented)", .{});
    } else {
        try out.raw(
            \\bz - beads_zig issue tracker
            \\
            \\USAGE:
            \\  bz <command> [options]
            \\
            \\COMMANDS:
            \\  init              Initialize .beads/ workspace
            \\  create <title>    Create new issue
            \\  list              List issues
            \\  show <id>         Show issue details
            \\  close <id>        Close an issue
            \\  help              Show this help
            \\  version           Show version
            \\
            \\GLOBAL OPTIONS:
            \\  --json            Output in JSON format
            \\  -q, --quiet       Suppress non-essential output
            \\  -v, --verbose     Increase verbosity
            \\  --no-color        Disable colors
            \\  --data <path>     Override .beads/ directory
            \\
            \\Run 'bz help <command>' for command-specific help.
            \\
        );
    }
}

fn showVersion() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("bz 0.1.0-dev (beads_zig)\n");
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
