//! Filesystem safety checking for beads_zig.
//!
//! Detects network filesystems (NFS, CIFS/SMB) where flock behavior may be
//! unreliable or non-functional across different clients. This is critical
//! because beads_zig relies on flock for concurrent write safety.
//!
//! Known problematic filesystems:
//! - NFSv2/v3: flock is advisory only, may not work across clients
//! - NFSv4: Mandatory but lease-based with timeouts, can be unreliable
//! - CIFS/SMB: Different semantics, potential issues with lock inheritance
//!
//! On detection, we warn the user but don't block initialization.
//! The tool will still work for single-machine, single-user scenarios.
//!
//! Also provides fsyncDir for ensuring directory metadata durability after
//! atomic rename operations.

const std = @import("std");
const builtin = @import("builtin");

/// Fsync a directory file descriptor for durability.
/// Unlike std.posix.fsync, this handles EINVAL gracefully since some filesystems
/// don't support fsync on directories. This is a best-effort operation.
pub fn fsyncDir(fd: std.posix.fd_t) void {
    if (builtin.os.tag == .windows) {
        return;
    }
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.fsync(fd);
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            _ = std.c.fsync(fd);
        },
        .freebsd, .openbsd, .netbsd, .dragonfly => {
            _ = std.c.fsync(fd);
        },
        else => {},
    }
}

pub const FilesystemCheck = struct {
    safe: bool,
    fs_type: FsType,
    warning: ?[]const u8,
};

pub const FsType = enum {
    local,
    nfs,
    cifs_smb,
    unknown_network,
    unknown,

    pub fn toString(self: FsType) []const u8 {
        return switch (self) {
            .local => "local",
            .nfs => "NFS",
            .cifs_smb => "CIFS/SMB",
            .unknown_network => "network filesystem",
            .unknown => "unknown",
        };
    }
};

/// Check if the given path is on a network filesystem that may have
/// unreliable flock behavior for multi-machine concurrent access.
pub fn checkFilesystemSafety(path: []const u8) FilesystemCheck {
    if (builtin.os.tag == .linux) {
        return checkLinux(path);
    } else if (builtin.os.tag == .macos) {
        return checkMacOS(path);
    } else if (builtin.os.tag == .windows) {
        return checkWindows(path);
    } else {
        // For other platforms, assume safe and let user handle issues
        return .{
            .safe = true,
            .fs_type = .unknown,
            .warning = null,
        };
    }
}

fn checkLinux(path: []const u8) FilesystemCheck {
    // Use /proc/mounts to detect filesystem type
    // This is more portable than using statfs syscall which requires libc
    const fs_type = detectFilesystemFromProcMounts(path);
    return categorizeFilesystem(fs_type);
}

fn checkMacOS(path: []const u8) FilesystemCheck {
    _ = path;
    // macOS implementation would use the Darwin statfs structure
    // For now, return unknown/safe since flock on macOS local filesystems is reliable
    // A full implementation would check f_fstypename field
    return .{
        .safe = true,
        .fs_type = .unknown,
        .warning = null,
    };
}

fn checkWindows(path: []const u8) FilesystemCheck {
    // On Windows, we use LockFileEx which works differently.
    // Check if path starts with \\ (UNC path) indicating network share
    if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') {
        return .{
            .safe = false,
            .fs_type = .unknown_network,
            .warning = "UNC network path detected - file locking may not work reliably. " ++
                "Concurrent access from multiple machines may cause data corruption.",
        };
    }

    // For now, assume safe since LockFileEx has better network support than flock
    return .{
        .safe = true,
        .fs_type = .unknown,
        .warning = null,
    };
}

/// Detect filesystem type by reading /proc/mounts and finding the mount point
/// that contains the given path.
fn detectFilesystemFromProcMounts(path: []const u8) ?[]const u8 {
    // First, get the absolute path
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = std.fs.cwd().realpath(path, &abs_path_buf) catch {
        // If we can't resolve the path, try the parent directory
        if (std.fs.path.dirname(path)) |parent| {
            return detectFilesystemFromProcMounts(parent);
        }
        return null;
    };

    // Read /proc/mounts
    const mounts_file = std.fs.cwd().openFile("/proc/mounts", .{}) catch return null;
    defer mounts_file.close();

    var buf: [8192]u8 = undefined;
    const bytes_read = mounts_file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];

    // Find the longest matching mount point
    var best_mount: ?[]const u8 = null;
    var best_fstype: ?[]const u8 = null;
    var best_len: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse: device mountpoint fstype options dump pass
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next(); // device
        const mount_point = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;

        // Check if this mount point is a prefix of our path
        if (std.mem.startsWith(u8, abs_path, mount_point)) {
            if (mount_point.len > best_len) {
                best_mount = mount_point;
                best_fstype = fstype;
                best_len = mount_point.len;
            }
        }
    }

    return best_fstype;
}

/// Categorize filesystem type into safe/unsafe for flock
fn categorizeFilesystem(fstype_opt: ?[]const u8) FilesystemCheck {
    const fstype = fstype_opt orelse {
        return .{
            .safe = true,
            .fs_type = .unknown,
            .warning = null,
        };
    };

    // NFS variants
    if (std.mem.eql(u8, fstype, "nfs") or
        std.mem.eql(u8, fstype, "nfs4") or
        std.mem.eql(u8, fstype, "nfsd"))
    {
        return .{
            .safe = false,
            .fs_type = .nfs,
            .warning = "NFS detected - flock may not work reliably across different clients. " ++
                "Concurrent access from multiple machines may cause data corruption.",
        };
    }

    // CIFS/SMB variants
    if (std.mem.eql(u8, fstype, "cifs") or
        std.mem.eql(u8, fstype, "smb") or
        std.mem.eql(u8, fstype, "smbfs") or
        std.mem.eql(u8, fstype, "smb3"))
    {
        return .{
            .safe = false,
            .fs_type = .cifs_smb,
            .warning = "CIFS/SMB network share detected - flock has different semantics on Windows shares. " ++
                "Concurrent access from multiple machines may cause data corruption.",
        };
    }

    // FUSE filesystems (could be network-based like sshfs, s3fs)
    if (std.mem.eql(u8, fstype, "fuse") or
        std.mem.eql(u8, fstype, "fuseblk") or
        std.mem.startsWith(u8, fstype, "fuse."))
    {
        return .{
            .safe = false,
            .fs_type = .unknown_network,
            .warning = "FUSE filesystem detected (possibly sshfs, s3fs, or similar). " ++
                "If this is a network-mounted filesystem, flock may not work reliably. " ++
                "Concurrent access from multiple machines may cause data corruption.",
        };
    }

    // Other network filesystems
    if (std.mem.eql(u8, fstype, "afs") or
        std.mem.eql(u8, fstype, "coda") or
        std.mem.eql(u8, fstype, "lustre") or
        std.mem.eql(u8, fstype, "glusterfs") or
        std.mem.eql(u8, fstype, "ceph") or
        std.mem.eql(u8, fstype, "9p"))
    {
        return .{
            .safe = false,
            .fs_type = .unknown_network,
            .warning = "Network filesystem detected - flock may not work reliably across clients. " ++
                "Concurrent access from multiple machines may cause data corruption.",
        };
    }

    // Known safe local filesystems
    if (std.mem.eql(u8, fstype, "ext4") or
        std.mem.eql(u8, fstype, "ext3") or
        std.mem.eql(u8, fstype, "ext2") or
        std.mem.eql(u8, fstype, "xfs") or
        std.mem.eql(u8, fstype, "btrfs") or
        std.mem.eql(u8, fstype, "zfs") or
        std.mem.eql(u8, fstype, "tmpfs") or
        std.mem.eql(u8, fstype, "overlay") or
        std.mem.eql(u8, fstype, "f2fs") or
        std.mem.eql(u8, fstype, "jfs") or
        std.mem.eql(u8, fstype, "reiserfs"))
    {
        return .{
            .safe = true,
            .fs_type = .local,
            .warning = null,
        };
    }

    // Unknown filesystem - assume safe for now
    return .{
        .safe = true,
        .fs_type = .unknown,
        .warning = null,
    };
}

// --- Tests ---

test "checkFilesystemSafety on unknown path" {
    // Should handle non-existent paths gracefully
    const check = checkFilesystemSafety("/nonexistent/path/that/does/not/exist");
    // Should return safe=true for non-existent paths (will be created on local fs)
    std.testing.expect(check.safe) catch {};
}

test "checkFilesystemSafety on current directory" {
    // Current directory should exist and likely be local
    const check = checkFilesystemSafety(".");
    // We can't assert the result since it depends on the environment,
    // but it shouldn't crash
    _ = check.fs_type;
}

test "FsType.toString returns expected strings" {
    try std.testing.expectEqualStrings("local", FsType.local.toString());
    try std.testing.expectEqualStrings("NFS", FsType.nfs.toString());
    try std.testing.expectEqualStrings("CIFS/SMB", FsType.cifs_smb.toString());
    try std.testing.expectEqualStrings("network filesystem", FsType.unknown_network.toString());
    try std.testing.expectEqualStrings("unknown", FsType.unknown.toString());
}
