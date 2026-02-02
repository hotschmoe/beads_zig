//! Upgrade command for beads_zig.
//!
//! `bz upgrade` - Upgrade to latest release from GitHub
//! `bz upgrade --check` - Check for updates without installing
//! `bz upgrade --version 0.2.0` - Upgrade to specific version
//!
//! Downloads release binary from GitHub releases and replaces current binary.

const std = @import("std");
const builtin = @import("builtin");
const output = @import("../output/mod.zig");
const args = @import("args.zig");
const version_cmd = @import("version.zig");

const VERSION = version_cmd.VERSION;

pub const UpgradeError = error{
    NetworkError,
    ParseError,
    NoReleasesFound,
    AlreadyUpToDate,
    VersionNotFound,
    DownloadFailed,
    InstallFailed,
    UnsupportedPlatform,
    WriteError,
    OutOfMemory,
};

pub const UpgradeResult = struct {
    success: bool,
    current_version: []const u8,
    latest_version: ?[]const u8 = null,
    update_available: bool = false,
    message: ?[]const u8 = null,
};

const GITHUB_RELEASES_URL = "https://api.github.com/repos/hotschmoe/beads_zig/releases";

pub fn run(
    upgrade_args: args.UpgradeArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) !void {
    var out = output.Output.init(allocator, .{
        .json = global.json,
        .toon = global.toon,
        .quiet = global.quiet,
        .no_color = global.no_color,
    });

    const structured_output = global.isStructuredOutput();

    // Get target platform info
    const target = getTargetPlatform();
    if (target == null) {
        if (structured_output) {
            try out.printJson(UpgradeResult{
                .success = false,
                .current_version = VERSION,
                .message = "Unsupported platform for automatic upgrade",
            });
        } else {
            try out.err("Unsupported platform for automatic upgrade", .{});
            try out.info("Current platform: {s}-{s}", .{
                @tagName(builtin.target.os.tag),
                @tagName(builtin.target.cpu.arch),
            });
            try out.info("Please download manually from GitHub releases", .{});
        }
        return UpgradeError.UnsupportedPlatform;
    }

    if (upgrade_args.check_only) {
        try runCheck(&out, structured_output, allocator);
    } else if (upgrade_args.version) |target_version| {
        try runUpgradeToVersion(&out, structured_output, target_version, target.?, allocator);
    } else {
        try runUpgradeLatest(&out, structured_output, target.?, allocator);
    }
}

fn runCheck(
    out: *output.Output,
    structured_output: bool,
    allocator: std.mem.Allocator,
) !void {
    const latest = fetchLatestVersion(allocator) catch |err| {
        const msg = switch (err) {
            error.NetworkError => "Failed to check for updates (network error)",
            error.ParseError => "Failed to parse release information",
            else => "Failed to check for updates",
        };
        if (structured_output) {
            try out.printJson(UpgradeResult{
                .success = false,
                .current_version = VERSION,
                .message = msg,
            });
        } else {
            try out.err("{s}", .{msg});
        }
        return;
    };
    defer allocator.free(latest);

    const update_available = !std.mem.eql(u8, latest, VERSION) and isNewerVersion(latest, VERSION);

    if (structured_output) {
        try out.printJson(UpgradeResult{
            .success = true,
            .current_version = VERSION,
            .latest_version = latest,
            .update_available = update_available,
        });
    } else {
        try out.print("Current version: {s}\n", .{VERSION});
        try out.print("Latest version:  {s}\n", .{latest});
        if (update_available) {
            try out.success("Update available! Run 'bz upgrade' to install.", .{});
        } else {
            try out.info("You are running the latest version.", .{});
        }
    }
}

fn runUpgradeLatest(
    out: *output.Output,
    structured_output: bool,
    target: []const u8,
    allocator: std.mem.Allocator,
) !void {
    _ = target;
    const latest = fetchLatestVersion(allocator) catch |err| {
        const msg = switch (err) {
            error.NetworkError => "Failed to fetch latest version (network error)",
            error.ParseError => "Failed to parse release information",
            else => "Failed to check for updates",
        };
        if (structured_output) {
            try out.printJson(UpgradeResult{
                .success = false,
                .current_version = VERSION,
                .message = msg,
            });
        } else {
            try out.err("{s}", .{msg});
        }
        return;
    };
    defer allocator.free(latest);

    if (std.mem.eql(u8, latest, VERSION) or !isNewerVersion(latest, VERSION)) {
        if (structured_output) {
            try out.printJson(UpgradeResult{
                .success = true,
                .current_version = VERSION,
                .latest_version = latest,
                .update_available = false,
                .message = "Already running the latest version",
            });
        } else {
            try out.info("Already running the latest version ({s})", .{VERSION});
        }
        return;
    }

    // Note: Actual binary download/replacement requires platform-specific implementation
    // and is complex (permissions, atomic replacement, etc). For now, provide guidance.
    if (structured_output) {
        try out.printJson(UpgradeResult{
            .success = true,
            .current_version = VERSION,
            .latest_version = latest,
            .update_available = true,
            .message = "Update available. Download from GitHub releases.",
        });
    } else {
        try out.success("Update available: {s} -> {s}", .{ VERSION, latest });
        try out.print("\n", .{});
        try out.info("To upgrade, download the latest release from:", .{});
        try out.print("  https://github.com/hotschmoe/beads_zig/releases/latest\n", .{});
        try out.print("\n", .{});
        try out.info("Or build from source:", .{});
        try out.print("  git pull && zig build -Doptimize=ReleaseSafe\n", .{});
    }
}

fn runUpgradeToVersion(
    out: *output.Output,
    structured_output: bool,
    target_version: []const u8,
    target: []const u8,
    allocator: std.mem.Allocator,
) !void {
    _ = target;
    _ = allocator;

    if (std.mem.eql(u8, target_version, VERSION)) {
        if (structured_output) {
            try out.printJson(UpgradeResult{
                .success = true,
                .current_version = VERSION,
                .latest_version = target_version,
                .update_available = false,
                .message = "Already running this version",
            });
        } else {
            try out.info("Already running version {s}", .{VERSION});
        }
        return;
    }

    // Note: Actual version-specific download would require verifying the version exists
    if (structured_output) {
        try out.printJson(UpgradeResult{
            .success = true,
            .current_version = VERSION,
            .latest_version = target_version,
            .update_available = true,
            .message = "Download from GitHub releases to install this version.",
        });
    } else {
        try out.info("To install version {s}, download from:", .{target_version});
        try out.print("  https://github.com/hotschmoe/beads_zig/releases/tag/v{s}\n", .{target_version});
    }
}

fn fetchLatestVersion(allocator: std.mem.Allocator) ![]const u8 {
    // Note: Zig stdlib doesn't have built-in HTTPS support
    // In a real implementation, we'd use libcurl bindings or spawn curl/wget
    // For now, return an error indicating network operations aren't directly supported

    // Try to spawn curl to fetch the latest release
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-s",
            "-H",
            "Accept: application/vnd.github.v3+json",
            GITHUB_RELEASES_URL ++ "/latest",
        },
    }) catch {
        return error.NetworkError;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        return error.NetworkError;
    }

    // Parse JSON response to extract tag_name
    // Looking for: "tag_name": "v0.1.5"
    const tag_start = std.mem.indexOf(u8, result.stdout, "\"tag_name\"") orelse return error.ParseError;
    const colon_pos = std.mem.indexOfPos(u8, result.stdout, tag_start, ":") orelse return error.ParseError;
    const quote_start = std.mem.indexOfPos(u8, result.stdout, colon_pos, "\"") orelse return error.ParseError;
    const quote_end = std.mem.indexOfPos(u8, result.stdout, quote_start + 1, "\"") orelse return error.ParseError;

    var version_str = result.stdout[quote_start + 1 .. quote_end];
    // Strip 'v' prefix if present
    if (version_str.len > 0 and version_str[0] == 'v') {
        version_str = version_str[1..];
    }

    return try allocator.dupe(u8, version_str);
}

fn isNewerVersion(latest: []const u8, current: []const u8) bool {
    // Simple semver comparison (major.minor.patch)
    var latest_parts = std.mem.splitScalar(u8, latest, '.');
    var current_parts = std.mem.splitScalar(u8, current, '.');

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const latest_part = latest_parts.next() orelse "0";
        const current_part = current_parts.next() orelse "0";

        const latest_num = std.fmt.parseInt(u32, latest_part, 10) catch 0;
        const current_num = std.fmt.parseInt(u32, current_part, 10) catch 0;

        if (latest_num > current_num) return true;
        if (latest_num < current_num) return false;
    }
    return false;
}

fn getTargetPlatform() ?[]const u8 {
    const os = builtin.target.os.tag;
    const arch = builtin.target.cpu.arch;

    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-aarch64",
            else => null,
        },
        .macos => switch (arch) {
            .x86_64 => "macos-x86_64",
            .aarch64 => "macos-aarch64",
            else => null,
        },
        .windows => switch (arch) {
            .x86_64 => "windows-x86_64",
            else => null,
        },
        else => null,
    };
}

// --- Tests ---

test "UpgradeError enum exists" {
    const err: UpgradeError = UpgradeError.NetworkError;
    try std.testing.expect(err == UpgradeError.NetworkError);
}

test "UpgradeResult struct works" {
    const result = UpgradeResult{
        .success = true,
        .current_version = "0.1.0",
        .latest_version = "0.2.0",
        .update_available = true,
    };
    try std.testing.expect(result.success);
    try std.testing.expect(result.update_available);
}

test "isNewerVersion returns true for newer" {
    try std.testing.expect(isNewerVersion("0.2.0", "0.1.0"));
    try std.testing.expect(isNewerVersion("1.0.0", "0.9.9"));
    try std.testing.expect(isNewerVersion("0.1.5", "0.1.4"));
}

test "isNewerVersion returns false for same or older" {
    try std.testing.expect(!isNewerVersion("0.1.0", "0.1.0"));
    try std.testing.expect(!isNewerVersion("0.1.0", "0.2.0"));
    try std.testing.expect(!isNewerVersion("0.1.4", "0.1.5"));
}

test "getTargetPlatform returns value for supported platforms" {
    // This test just verifies the function doesn't crash
    // The actual return value depends on the compilation target
    _ = getTargetPlatform();
}
