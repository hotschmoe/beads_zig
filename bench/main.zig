const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Nanosecond-precision timer that reports milliseconds
pub const Timer = struct {
    start: i128,

    pub fn begin() Timer {
        return .{ .start = std.time.nanoTimestamp() };
    }

    pub fn elapsedMs(self: Timer) i64 {
        const elapsed_ns = std.time.nanoTimestamp() - self.start;
        return @intCast(@divTrunc(elapsed_ns, 1_000_000));
    }
};

/// Result of running a command
pub const RunResult = struct {
    exit_code: u8,
    elapsed_ms: i64,
};

/// Spawn a child process with stdout/stderr ignored
fn spawnChild(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) std.process.Child {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    return child;
}

/// Extract exit code from termination status
fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| code,
        else => 255,
    };
}

/// Run a command and return exit code + elapsed time
pub fn runCommand(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) !RunResult {
    const timer = Timer.begin();
    var child = spawnChild(allocator, argv, cwd);
    const term = try child.spawnAndWait();
    return .{
        .exit_code = exitCode(term),
        .elapsed_ms = timer.elapsedMs(),
    };
}

/// Run a command N times and return total elapsed time
pub fn runCommandLoop(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8, count: usize) !i64 {
    const timer = Timer.begin();
    for (0..count) |_| {
        var child = spawnChild(allocator, argv, cwd);
        _ = try child.spawnAndWait();
    }
    return timer.elapsedMs();
}

/// Result of running commands with output capture
pub const CaptureResult = struct {
    elapsed_ms: i64,
    last_output: ?[]u8,
};

/// Run a command N times, capturing stdout from the last run
pub fn runCommandLoopCapture(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8, count: usize) !CaptureResult {
    const timer = Timer.begin();
    var last_output: ?[]u8 = null;

    for (0..count) |i| {
        var child = std.process.Child.init(argv, allocator);
        child.cwd = cwd;
        child.stderr_behavior = .Ignore;

        // Capture stdout only on last iteration
        if (i == count - 1) {
            child.stdout_behavior = .Pipe;
            _ = try child.spawn();

            var output_buf: [4096]u8 = undefined;
            const bytes_read = try child.stdout.?.readAll(&output_buf);
            _ = try child.wait();

            if (bytes_read > 0) {
                const trimmed = std.mem.trim(u8, output_buf[0..bytes_read], "\n\r \t");
                if (trimmed.len > 0) {
                    last_output = try allocator.dupe(u8, trimmed);
                }
            }
        } else {
            child.stdout_behavior = .Ignore;
            _ = try child.spawnAndWait();
        }
    }

    return .{
        .elapsed_ms = timer.elapsedMs(),
        .last_output = last_output,
    };
}

/// Temporary directory in sandbox/ with automatic cleanup
pub const TempDir = struct {
    path: []u8,
    allocator: Allocator,

    pub fn create(allocator: Allocator, prefix: []const u8) !TempDir {
        const timestamp = std.time.timestamp();
        const path = try std.fmt.allocPrint(allocator, "sandbox/{s}_{d}", .{ prefix, timestamp });
        errdefer allocator.free(path);
        try std.fs.cwd().makePath(path);
        return .{ .path = path, .allocator = allocator };
    }

    pub fn cleanup(self: *TempDir) void {
        std.fs.cwd().deleteTree(self.path) catch {};
        self.allocator.free(self.path);
        self.path = "";
    }
};

/// Find the bz binary via BZ_PATH env var or default location
pub fn findBz(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "BZ_PATH")) |path| {
        return path;
    } else |_| {}

    const default = if (builtin.os.tag == .windows) "zig-out/bin/bz.exe" else "zig-out/bin/bz";
    std.fs.cwd().access(default, .{}) catch return error.BinaryNotFound;

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, default });
}

/// Find the br binary via BR_PATH env var or PATH
pub fn findBr(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "BR_PATH")) |path| {
        return path;
    } else |_| {}

    var child = std.process.Child.init(&.{ "which", "br" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    _ = try child.spawn();

    var output_buf: [4096]u8 = undefined;
    const bytes_read = try child.stdout.?.readAll(&output_buf);
    const term = try child.wait();

    if (term == .Exited and term.Exited == 0) {
        const trimmed = std.mem.trim(u8, output_buf[0..bytes_read], "\n\r ");
        return allocator.dupe(u8, trimmed);
    }
    return error.BinaryNotFound;
}

/// Simple print helper that allocates and writes
pub fn print(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try std.fs.File.stdout().writeAll(msg);
}

/// Print a formatted table row (operation name + time)
pub fn printRow(allocator: Allocator, operation: []const u8, time_ms: i64) !void {
    try print(allocator, "{s: <20} {: >8}ms\n", .{ operation, @as(u64, @intCast(time_ms)) });
}

/// Print comparison table row (operation + bz time + br time)
pub fn printCompareRow(allocator: Allocator, operation: []const u8, bz_ms: i64, br_ms: i64) !void {
    try print(allocator, "{s: <20} {: >8}ms {: >8}ms\n", .{
        operation,
        @as(u64, @intCast(bz_ms)),
        @as(u64, @intCast(br_ms)),
    });
}

/// Run N copies of a command in parallel, return total elapsed time
pub fn runCommandParallel(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8, count: usize) !i64 {
    const timer = Timer.begin();

    // Spawn all children
    var children = try allocator.alloc(std.process.Child, count);
    defer allocator.free(children);

    for (0..count) |i| {
        children[i] = spawnChild(allocator, argv, cwd);
        _ = try children[i].spawn();
    }

    // Wait for all to complete
    for (children) |*child| {
        _ = try child.wait();
    }

    return timer.elapsedMs();
}
