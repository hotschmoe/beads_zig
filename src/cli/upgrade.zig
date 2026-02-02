//! Upgrade command for beads_zig.
//!
//! `bz upgrade` - Upgrade to latest release from GitHub
//! `bz upgrade --check` - Check for updates without installing
//! `bz upgrade --version 0.2.0` - Upgrade to specific version
//! `bz upgrade --no-verify` - Skip checksum verification
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
    ChecksumMismatch,
    ChecksumUnavailable,
    InstallFailed,
    UnsupportedPlatform,
    WriteError,
    PermissionDenied,
    OutOfMemory,
    SelfPathError,
};

pub const UpgradeResult = struct {
    success: bool,
    current_version: []const u8,
    latest_version: ?[]const u8 = null,
    update_available: bool = false,
    upgraded: bool = false,
    checksum_verified: bool = false,
    message: ?[]const u8 = null,
};

const GITHUB_OWNER = "hotschmoe";
const GITHUB_REPO = "beads_zig";
const GITHUB_RELEASES_URL = "https://api.github.com/repos/" ++ GITHUB_OWNER ++ "/" ++ GITHUB_REPO ++ "/releases";
const GITHUB_DOWNLOAD_URL = "https://github.com/" ++ GITHUB_OWNER ++ "/" ++ GITHUB_REPO ++ "/releases/download";

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
        try runUpgradeToVersion(&out, structured_output, global.verbose > 0, target_version, target.?, upgrade_args.verify, upgrade_args.force, allocator);
    } else {
        try runUpgradeLatest(&out, structured_output, global.verbose > 0, target.?, upgrade_args.verify, upgrade_args.force, allocator);
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
    verbose: bool,
    target: []const u8,
    verify_checksum: bool,
    force: bool,
    allocator: std.mem.Allocator,
) !void {
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

    if (!force and (std.mem.eql(u8, latest, VERSION) or !isNewerVersion(latest, VERSION))) {
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

    try performUpgrade(out, structured_output, verbose, latest, target, verify_checksum, allocator);
}

fn runUpgradeToVersion(
    out: *output.Output,
    structured_output: bool,
    verbose: bool,
    target_version: []const u8,
    target: []const u8,
    verify_checksum: bool,
    force: bool,
    allocator: std.mem.Allocator,
) !void {
    if (!force and std.mem.eql(u8, target_version, VERSION)) {
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

    try performUpgrade(out, structured_output, verbose, target_version, target, verify_checksum, allocator);
}

fn performUpgrade(
    out: *output.Output,
    structured_output: bool,
    verbose: bool,
    target_version: []const u8,
    target_platform: []const u8,
    verify_checksum: bool,
    allocator: std.mem.Allocator,
) !void {
    if (!structured_output) {
        try out.print("Upgrading bz: {s} -> {s}\n", .{ VERSION, target_version });
    }

    const version_tag = blk: {
        if (target_version.len > 0 and target_version[0] != 'v') {
            break :blk try std.fmt.allocPrint(allocator, "v{s}", .{target_version});
        }
        break :blk try allocator.dupe(u8, target_version);
    };
    defer allocator.free(version_tag);

    const binary_name = blk: {
        if (std.mem.eql(u8, target_platform, "windows-x86_64")) {
            break :blk try std.fmt.allocPrint(allocator, "bz-{s}.exe", .{target_platform});
        }
        break :blk try std.fmt.allocPrint(allocator, "bz-{s}", .{target_platform});
    };
    defer allocator.free(binary_name);

    const binary_url = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ GITHUB_DOWNLOAD_URL, version_tag, binary_name });
    defer allocator.free(binary_url);

    const checksum_url = try std.fmt.allocPrint(allocator, "{s}.sha256", .{binary_url});
    defer allocator.free(checksum_url);

    if (verbose and !structured_output) {
        try out.info("Binary URL: {s}", .{binary_url});
        try out.info("Checksum URL: {s}", .{checksum_url});
    }

    if (!structured_output) {
        try out.print("Downloading binary...\n", .{});
    }
    const binary_data = downloadFile(allocator, binary_url) catch {
        const msg = "Failed to download binary (network error)";
        if (structured_output) {
            try out.printJson(UpgradeResult{
                .success = false,
                .current_version = VERSION,
                .latest_version = target_version,
                .message = msg,
            });
        } else {
            try out.err("{s}", .{msg});
            try out.info("Download URL: {s}", .{binary_url});
        }
        return UpgradeError.DownloadFailed;
    };
    defer allocator.free(binary_data);

    if (verbose and !structured_output) {
        try out.info("Downloaded {d} bytes", .{binary_data.len});
    }

    var checksum_verified = false;
    if (verify_checksum) {
        if (!structured_output) {
            try out.print("Verifying checksum...\n", .{});
        }

        const checksum_data = downloadFile(allocator, checksum_url) catch {
            if (structured_output) {
                try out.printJson(UpgradeResult{
                    .success = false,
                    .current_version = VERSION,
                    .latest_version = target_version,
                    .message = "Checksum file not available",
                });
            } else {
                try out.err("Checksum file not available", .{});
                try out.info("Use --no-verify to skip checksum verification", .{});
            }
            return UpgradeError.ChecksumUnavailable;
        };
        defer allocator.free(checksum_data);

        const expected_checksum = parseChecksum(checksum_data);
        if (expected_checksum == null) {
            if (structured_output) {
                try out.printJson(UpgradeResult{
                    .success = false,
                    .current_version = VERSION,
                    .latest_version = target_version,
                    .message = "Invalid checksum format",
                });
            } else {
                try out.err("Invalid checksum format", .{});
            }
            return UpgradeError.ParseError;
        }

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(binary_data);
        var actual_hash: [32]u8 = undefined;
        hasher.final(&actual_hash);
        const actual_hex = std.fmt.bytesToHex(actual_hash, .lower);

        if (verbose and !structured_output) {
            try out.info("Expected: {s}", .{expected_checksum.?});
            try out.info("Actual:   {s}", .{actual_hex});
        }

        if (!std.mem.eql(u8, &actual_hex, expected_checksum.?)) {
            if (structured_output) {
                try out.printJson(UpgradeResult{
                    .success = false,
                    .current_version = VERSION,
                    .latest_version = target_version,
                    .message = "Checksum mismatch - download may be corrupted",
                });
            } else {
                try out.err("Checksum mismatch!", .{});
                try out.info("Expected: {s}", .{expected_checksum.?});
                try out.info("Got:      {s}", .{actual_hex});
                try out.info("The download may be corrupted. Please try again.", .{});
            }
            return UpgradeError.ChecksumMismatch;
        }

        checksum_verified = true;
        if (!structured_output) {
            try out.success("Checksum verified", .{});
        }
    } else if (!structured_output) {
        try out.warn("Skipping checksum verification (--no-verify)", .{});
    }

    if (!structured_output) {
        try out.print("Installing binary...\n", .{});
    }
    installBinary(binary_data, verbose, out, structured_output, allocator) catch |err| {
        const msg = switch (err) {
            error.PermissionDenied => "Permission denied - try running with sudo or moving the binary to a writable location",
            error.SelfPathError => "Could not determine current binary path",
            else => "Failed to install binary",
        };
        if (structured_output) {
            try out.printJson(UpgradeResult{
                .success = false,
                .current_version = VERSION,
                .latest_version = target_version,
                .message = msg,
            });
        } else {
            try out.err("{s}", .{msg});
        }
        return UpgradeError.InstallFailed;
    };

    if (structured_output) {
        try out.printJson(UpgradeResult{
            .success = true,
            .current_version = VERSION,
            .latest_version = target_version,
            .update_available = true,
            .upgraded = true,
            .checksum_verified = checksum_verified,
        });
    } else {
        try out.success("Upgraded to version {s}", .{target_version});
        try out.info("Restart your shell or run 'hash -r' to use the new version", .{});
    }
}

fn parseChecksum(data: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const hash = it.first();
    if (hash.len == 64) {
        for (hash) |c| {
            if (!std.ascii.isHex(c)) return null;
        }
        return hash;
    }
    return null;
}

fn downloadFile(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-fsSL",
            "--connect-timeout",
            "30",
            "--max-time",
            "300",
            "-o",
            "-",
            url,
        },
    }) catch {
        return error.NetworkError;
    };
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.NetworkError;
    }

    return result.stdout;
}

fn installBinary(
    binary_data: []const u8,
    verbose: bool,
    out: *output.Output,
    structured_output: bool,
    allocator: std.mem.Allocator,
) !void {
    const self_path = getSelfPath(allocator) catch {
        return error.SelfPathError;
    };
    defer allocator.free(self_path);

    if (verbose and !structured_output) {
        try out.info("Installing to: {s}", .{self_path});
    }

    if (builtin.target.os.tag == .windows) {
        try installBinaryWindows(binary_data, self_path, allocator);
    } else {
        try installBinaryPosix(binary_data, self_path);
    }
}

fn installBinaryPosix(binary_data: []const u8, target_path: []const u8) !void {
    const tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_path: []const u8 = undefined;

    const dir_path = std.fs.path.dirname(target_path) orelse ".";
    const basename = std.fs.path.basename(target_path);

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();
    var suffix: [8]u8 = undefined;
    for (&suffix) |*c| {
        c.* = "abcdefghijklmnopqrstuvwxyz0123456789"[random.intRangeAtMost(u8, 0, 35)];
    }

    var path_buf = tmp_path_buf;
    tmp_path = std.fmt.bufPrint(&path_buf, "{s}/.{s}.tmp.{s}", .{ dir_path, basename, suffix }) catch {
        return error.WriteError;
    };

    const dir = std.fs.cwd().openDir(dir_path, .{}) catch |err| {
        if (err == error.AccessDenied) return error.PermissionDenied;
        return error.WriteError;
    };

    const tmp_file = dir.createFile(std.fs.path.basename(tmp_path), .{ .mode = 0o755 }) catch |err| {
        if (err == error.AccessDenied) return error.PermissionDenied;
        return error.WriteError;
    };
    errdefer {
        tmp_file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    tmp_file.writeAll(binary_data) catch {
        tmp_file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return error.WriteError;
    };

    tmp_file.sync() catch {};
    tmp_file.close();

    std.fs.cwd().rename(tmp_path, target_path) catch |err| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        if (err == error.AccessDenied) return error.PermissionDenied;
        return error.WriteError;
    };
}

fn installBinaryWindows(binary_data: []const u8, target_path: []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;
    const dir_path = std.fs.path.dirname(target_path) orelse ".";
    const basename = std.fs.path.basename(target_path);

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();
    var suffix: [8]u8 = undefined;
    for (&suffix) |*c| {
        c.* = "abcdefghijklmnopqrstuvwxyz0123456789"[random.intRangeAtMost(u8, 0, 35)];
    }

    const tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf = tmp_path_buf;
    const tmp_path = std.fmt.bufPrint(&path_buf, "{s}/.{s}.tmp.{s}", .{ dir_path, basename, suffix }) catch {
        return error.WriteError;
    };

    const old_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var old_buf = old_path_buf;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}/{s}.old.{s}", .{ dir_path, basename, suffix }) catch {
        return error.WriteError;
    };

    const dir = std.fs.cwd().openDir(dir_path, .{}) catch |err| {
        if (err == error.AccessDenied) return error.PermissionDenied;
        return error.WriteError;
    };

    const tmp_file = dir.createFile(std.fs.path.basename(tmp_path), .{ .mode = 0o755 }) catch |err| {
        if (err == error.AccessDenied) return error.PermissionDenied;
        return error.WriteError;
    };
    errdefer {
        tmp_file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    tmp_file.writeAll(binary_data) catch {
        tmp_file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return error.WriteError;
    };
    tmp_file.close();

    std.fs.cwd().rename(target_path, old_path) catch |err| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        if (err == error.AccessDenied) return error.PermissionDenied;
        return error.WriteError;
    };

    std.fs.cwd().rename(tmp_path, target_path) catch |err| {
        std.fs.cwd().rename(old_path, target_path) catch {};
        if (err == error.AccessDenied) return error.PermissionDenied;
        return error.WriteError;
    };

    std.fs.cwd().deleteFile(old_path) catch {};
}

fn getSelfPath(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fs.selfExePath(&buf) catch {
        return error.SelfPathError;
    };
    return try allocator.dupe(u8, path);
}

fn fetchLatestVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "-fsSL",
            "--connect-timeout",
            "10",
            "--max-time",
            "30",
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

    const tag_start = std.mem.indexOf(u8, result.stdout, "\"tag_name\"") orelse return error.ParseError;
    const colon_pos = std.mem.indexOfPos(u8, result.stdout, tag_start, ":") orelse return error.ParseError;
    const quote_start = std.mem.indexOfPos(u8, result.stdout, colon_pos, "\"") orelse return error.ParseError;
    const quote_end = std.mem.indexOfPos(u8, result.stdout, quote_start + 1, "\"") orelse return error.ParseError;

    var version_str = result.stdout[quote_start + 1 .. quote_end];
    if (version_str.len > 0 and version_str[0] == 'v') {
        version_str = version_str[1..];
    }

    return try allocator.dupe(u8, version_str);
}

fn isNewerVersion(latest: []const u8, current: []const u8) bool {
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
    _ = getTargetPlatform();
}

test "parseChecksum parses valid checksum" {
    const valid = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  bz-linux-x86_64";
    const result = parseChecksum(valid);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", result.?);
}

test "parseChecksum parses hash-only format" {
    const valid = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n";
    const result = parseChecksum(valid);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", result.?);
}

test "parseChecksum rejects invalid checksums" {
    try std.testing.expect(parseChecksum("tooshort") == null);
    try std.testing.expect(parseChecksum("zzzz0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == null);
}
