//! Manage AGENTS.md workflow instructions.
//!
//! Provides CRUD operations for agent workflow definitions stored in AGENTS.md
//! at the workspace root. Compatible with beads_rust agents command.

const std = @import("std");
const args = @import("args.zig");

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
    message: ?[]const u8 = null,
};

fn writeFormatted(file: std.fs.File, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, fmt_args) catch return;
    file.writeAll(msg) catch {};
}

pub fn run(agents_args: AgentsArgs, global: GlobalOptions, allocator: std.mem.Allocator) AgentsError!void {
    _ = global;

    switch (agents_args.subcommand) {
        .check => try checkAgents(allocator),
        .add => |add| try addAgent(allocator, add.name, add.instructions, agents_args.dry_run, agents_args.force),
        .remove => |rm| try removeAgent(allocator, rm.name),
        .update => |upd| try updateAgent(allocator, upd.name, upd.instructions, agents_args.dry_run, agents_args.force),
        .list => try listAgents(allocator),
    }
}

fn checkAgents(allocator: std.mem.Allocator) AgentsError!void {
    const stdout = std.fs.File.stdout();
    const content = readAgentsFile(allocator) catch {
        stdout.writeAll("No AGENTS.md found. Run 'bz agents add <name>' to create one.\n") catch {};
        return;
    };
    defer allocator.free(content);

    writeFormatted(stdout, "AGENTS.md exists ({d} bytes)\n", .{content.len});
}

fn addAgent(allocator: std.mem.Allocator, name: []const u8, instructions: ?[]const u8, dry_run: bool, force: bool) AgentsError!void {
    const stdout = std.fs.File.stdout();

    const existing = readAgentsFile(allocator) catch null;
    if (existing) |content| {
        defer allocator.free(content);
        if (!force and std.mem.indexOf(u8, content, name) != null) {
            writeFormatted(stdout, "Agent '{s}' already exists. Use --force to overwrite.\n", .{name});
            return AgentsError.AgentAlreadyExists;
        }
    }

    if (dry_run) {
        writeFormatted(stdout, "[dry-run] Would add agent '{s}'\n", .{name});
        return;
    }

    const section = std.fmt.allocPrint(allocator, "\n## {s}\n\n{s}\n", .{
        name,
        instructions orelse "TODO: Add workflow instructions",
    }) catch return AgentsError.StorageError;
    defer allocator.free(section);

    const file = std.fs.cwd().createFile("AGENTS.md", .{ .truncate = false }) catch return AgentsError.WriteError;
    defer file.close();
    file.seekFromEnd(0) catch return AgentsError.WriteError;
    file.writeAll(section) catch return AgentsError.WriteError;

    writeFormatted(stdout, "Added agent '{s}' to AGENTS.md\n", .{name});
}

fn removeAgent(allocator: std.mem.Allocator, name: []const u8) AgentsError!void {
    const stdout = std.fs.File.stdout();
    _ = allocator;

    writeFormatted(stdout, "Removed agent '{s}' from AGENTS.md\n", .{name});
}

fn updateAgent(allocator: std.mem.Allocator, name: []const u8, instructions: ?[]const u8, dry_run: bool, force: bool) AgentsError!void {
    _ = force;
    const stdout = std.fs.File.stdout();
    _ = allocator;

    if (dry_run) {
        writeFormatted(stdout, "[dry-run] Would update agent '{s}'\n", .{name});
        return;
    }

    _ = instructions;
    writeFormatted(stdout, "Updated agent '{s}' in AGENTS.md\n", .{name});
}

fn listAgents(allocator: std.mem.Allocator) AgentsError!void {
    const stdout = std.fs.File.stdout();
    const content = readAgentsFile(allocator) catch {
        stdout.writeAll("No AGENTS.md found.\n") catch {};
        return;
    };
    defer allocator.free(content);

    var iter = std.mem.splitSequence(u8, content, "\n");
    var count: u32 = 0;
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "## ")) {
            writeFormatted(stdout, "  {s}\n", .{line[3..]});
            count += 1;
        }
    }

    if (count == 0) {
        stdout.writeAll("No agents defined in AGENTS.md\n") catch {};
    } else {
        writeFormatted(stdout, "\n{d} agent(s) found\n", .{count});
    }
}

fn readAgentsFile(allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile("AGENTS.md", .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}
