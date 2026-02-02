const std = @import("std");
const Allocator = std.mem.Allocator;

/// Nanosecond-precision timer that reports milliseconds
pub const Timer = struct {
    start: i128,

    pub fn begin() Timer {
        return .{ .start = std.time.nanoTimestamp() };
    }

    pub fn elapsedMs(self: Timer) i64 {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start;
        return @intCast(@divTrunc(elapsed_ns, 1_000_000));
    }
};

/// Result of running a command
pub const RunResult = struct {
    exit_code: u8,
    elapsed_ms: i64,
};

/// Run a command and return exit code + elapsed time
pub fn runCommand(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) !RunResult {
    const timer = Timer.begin();

    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();

    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };

    return .{
        .exit_code = exit_code,
        .elapsed_ms = timer.elapsedMs(),
    };
}

/// Run a command N times and return total elapsed time
pub fn runCommandLoop(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8, count: usize) !i64 {
    const timer = Timer.begin();

    for (0..count) |_| {
        var child = std.process.Child.init(argv, allocator);
        child.cwd = cwd;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        _ = try child.spawnAndWait();
    }

    return timer.elapsedMs();
}

/// Temporary directory in sandbox/ with automatic cleanup
pub const TempDir = struct {
    path: []u8,
    allocator: Allocator,

    pub fn create(allocator: Allocator, prefix: []const u8) !TempDir {
        const timestamp = std.time.timestamp();
        const path = try std.fmt.allocPrint(allocator, "sandbox/{s}_{d}", .{ prefix, timestamp });

        std.fs.cwd().makePath(path) catch |err| {
            allocator.free(path);
            return err;
        };

        return .{
            .path = path,
            .allocator = allocator,
        };
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

    // Default: zig-out/bin/bz relative to cwd, converted to absolute
    const default = "zig-out/bin/bz";
    std.fs.cwd().access(default, .{}) catch {
        return error.BinaryNotFound;
    };

    // Get absolute path
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    return try std.fs.path.join(allocator, &.{ cwd_path, default });
}

/// Find the br binary via BR_PATH env var or PATH
pub fn findBr(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "BR_PATH")) |path| {
        return path;
    } else |_| {}

    // Try to find 'br' in PATH using which and capture output
    var child = std.process.Child.init(&.{ "which", "br" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    _ = try child.spawn();

    // Read stdout using a buffer
    var output_buf: [4096]u8 = undefined;
    const stdout_file = child.stdout.?;
    const bytes_read = try stdout_file.readAll(&output_buf);
    const output = output_buf[0..bytes_read];

    const term = try child.wait();

    if (term == .Exited and term.Exited == 0) {
        // Remove trailing newline from which output
        const trimmed = std.mem.trim(u8, output, "\n\r ");
        return try allocator.dupe(u8, trimmed);
    }

    return error.BinaryNotFound;
}

/// Print formatted message to file
pub fn print(allocator: Allocator, file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try file.writeAll(msg);
}

/// Print a formatted table row (operation name + time)
pub fn printRow(allocator: Allocator, file: std.fs.File, operation: []const u8, time_ms: i64) !void {
    const ms: u64 = @intCast(time_ms);
    try print(allocator, file, "{s: <20} {: >8}ms\n", .{ operation, ms });
}

/// Print comparison table row (operation + bz time + br time)
pub fn printCompareRow(allocator: Allocator, file: std.fs.File, operation: []const u8, bz_ms: i64, br_ms: i64) !void {
    const bz: u64 = @intCast(bz_ms);
    const br: u64 = @intCast(br_ms);
    try print(allocator, file, "{s: <20} {: >8}ms {: >8}ms\n", .{ operation, bz, br });
}
