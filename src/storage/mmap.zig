//! Memory-mapped file reading for beads_zig.
//!
//! Provides zero-copy file reading via mmap:
//! - Efficient for large files (OS handles caching)
//! - No allocation for file contents
//! - Cross-platform support (POSIX, Windows)
//!
//! Usage:
//!   const mapping = try MappedFile.open("file.txt");
//!   defer mapping.close();
//!   const data = mapping.data();  // Zero-copy slice

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Page size used for mmap alignment.
const page_size = std.heap.page_size_min;

pub const MmapError = error{
    FileNotFound,
    AccessDenied,
    MmapFailed,
    InvalidFile,
    OutOfMemory,
    Unexpected,
};

/// A memory-mapped file for zero-copy reading.
/// On close, the mapping is unmapped automatically.
pub const MappedFile = struct {
    /// The mapped memory region (slice of mapped bytes).
    mapped_slice: ?[]align(page_size) u8,
    /// File handle (kept open for the duration of the mapping).
    file: std.fs.File,

    const Self = @This();

    /// Open and memory-map a file for reading.
    /// Returns empty mapping for empty files.
    /// Returns FileNotFound if the file doesn't exist.
    pub fn open(path: []const u8) MmapError!Self {
        return openFromDir(std.fs.cwd(), path);
    }

    /// Open and memory-map a file from a specific directory.
    pub fn openFromDir(dir: std.fs.Dir, path: []const u8) MmapError!Self {
        const file = dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return MmapError.FileNotFound,
            error.AccessDenied => return MmapError.AccessDenied,
            else => return MmapError.Unexpected,
        };
        errdefer file.close();

        const stat = file.stat() catch return MmapError.InvalidFile;
        const size = stat.size;

        if (size == 0) {
            // Empty file - return valid empty mapping
            return Self{
                .mapped_slice = null,
                .file = file,
            };
        }

        const mapped = mapFile(file, size) catch return MmapError.MmapFailed;

        return Self{
            .mapped_slice = mapped,
            .file = file,
        };
    }

    /// Get the mapped data as a slice.
    /// Returns empty slice for empty files.
    pub fn data(self: Self) []const u8 {
        if (self.mapped_slice) |slice| {
            return slice;
        }
        return &[_]u8{};
    }

    /// Get the length of the mapped region.
    pub fn len(self: Self) usize {
        if (self.mapped_slice) |slice| {
            return slice.len;
        }
        return 0;
    }

    /// Close the mapping and file.
    pub fn close(self: *Self) void {
        if (self.mapped_slice) |slice| {
            unmapFile(slice);
        }
        self.file.close();
        self.* = undefined;
    }

    /// Platform-specific mmap implementation.
    fn mapFile(file: std.fs.File, size: usize) ![]align(page_size) u8 {
        if (builtin.os.tag == .windows) {
            return mapFileWindows(file, size);
        } else {
            return mapFilePosix(file, size);
        }
    }

    /// POSIX mmap implementation.
    fn mapFilePosix(file: std.fs.File, size: usize) ![]align(page_size) u8 {
        return posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
    }

    /// Windows memory mapping implementation.
    fn mapFileWindows(file: std.fs.File, size: usize) ![]align(page_size) u8 {
        _ = file;
        _ = size;
        // Windows implementation would use CreateFileMappingW and MapViewOfFile
        // For now, return error - Windows support can be added later
        return error.MemoryMappingNotSupported;
    }

    /// Platform-specific unmap implementation.
    fn unmapFile(slice: []align(page_size) u8) void {
        if (builtin.os.tag == .windows) {
            unmapFileWindows(slice);
        } else {
            unmapFilePosix(slice);
        }
    }

    /// POSIX munmap implementation.
    fn unmapFilePosix(slice: []align(page_size) u8) void {
        posix.munmap(slice);
    }

    /// Windows unmap implementation.
    fn unmapFileWindows(slice: []align(page_size) u8) void {
        _ = slice;
        // Windows implementation would use UnmapViewOfFile
    }
};

// --- Tests ---

const test_util = @import("../test_util.zig");

test "MappedFile.open returns FileNotFound for missing file" {
    const result = MappedFile.open("/nonexistent/path/file.txt");
    try std.testing.expectError(MmapError.FileNotFound, result);
}

test "MappedFile.open handles empty file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "mmap_empty");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "empty.txt" });
    defer allocator.free(test_path);

    // Create empty file
    const file = try std.fs.cwd().createFile(test_path, .{});
    file.close();

    // Open with mmap
    var mapping = try MappedFile.open(test_path);
    defer mapping.close();

    try std.testing.expectEqual(@as(usize, 0), mapping.data().len);
}

test "MappedFile roundtrip" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "mmap_roundtrip");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "test.txt" });
    defer allocator.free(test_path);

    // Write test content
    const content = "Hello, mmap world!\nLine 2\nLine 3\n";
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    // Read with mmap
    var mapping = try MappedFile.open(test_path);
    defer mapping.close();

    try std.testing.expectEqualStrings(content, mapping.data());
}

test "MappedFile large file" {
    const allocator = std.testing.allocator;
    const test_dir = try test_util.createTestDir(allocator, "mmap_large");
    defer allocator.free(test_dir);
    defer test_util.cleanupTestDir(test_dir);

    const test_path = try std.fs.path.join(allocator, &.{ test_dir, "large.txt" });
    defer allocator.free(test_path);

    // Write a larger file (1MB)
    const size: usize = 1024 * 1024;
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        @memset(&buf, 'A');

        var written: usize = 0;
        while (written < size) {
            const to_write = @min(buf.len, size - written);
            try file.writeAll(buf[0..to_write]);
            written += to_write;
        }
    }

    // Read with mmap
    var mapping = try MappedFile.open(test_path);
    defer mapping.close();

    try std.testing.expectEqual(size, mapping.data().len);

    // Verify content
    for (mapping.data()) |byte| {
        try std.testing.expectEqual(@as(u8, 'A'), byte);
    }
}
