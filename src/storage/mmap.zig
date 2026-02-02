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
const windows = std.os.windows;

/// Page size used for mmap alignment.
const page_size = std.heap.page_size_min;

/// Windows API declarations for memory mapping.
const windows_mmap = struct {
    extern "kernel32" fn CreateFileMappingW(
        hFile: windows.HANDLE,
        lpFileMappingAttributes: ?*anyopaque,
        flProtect: windows.DWORD,
        dwMaximumSizeHigh: windows.DWORD,
        dwMaximumSizeLow: windows.DWORD,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;

    extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: windows.HANDLE,
        dwDesiredAccess: windows.DWORD,
        dwFileOffsetHigh: windows.DWORD,
        dwFileOffsetLow: windows.DWORD,
        dwNumberOfBytesToMap: usize,
    ) callconv(.winapi) ?[*]align(page_size) u8;

    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: [*]const u8) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
};

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
    /// Windows file mapping handle (null on POSIX).
    mapping_handle: if (builtin.os.tag == .windows) ?windows.HANDLE else void,

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
                .mapping_handle = if (builtin.os.tag == .windows) null else {},
            };
        }

        const map_result = mapFile(file, size) catch return MmapError.MmapFailed;

        return Self{
            .mapped_slice = map_result.slice,
            .file = file,
            .mapping_handle = if (builtin.os.tag == .windows) map_result.handle else {},
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
            if (builtin.os.tag == .windows) {
                unmapFileWindows(slice, self.mapping_handle);
            } else {
                unmapFilePosix(slice);
            }
        }
        self.file.close();
        self.* = undefined;
    }

    /// Result of mapping a file.
    const MapResult = struct {
        slice: []align(page_size) u8,
        handle: if (builtin.os.tag == .windows) ?windows.HANDLE else void,
    };

    /// Platform-specific mmap implementation.
    fn mapFile(file: std.fs.File, size: usize) !MapResult {
        if (builtin.os.tag == .windows) {
            return mapFileWindows(file, size);
        } else {
            return mapFilePosix(file, size);
        }
    }

    /// POSIX mmap implementation.
    fn mapFilePosix(file: std.fs.File, size: usize) !MapResult {
        const slice = try posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        return .{ .slice = slice, .handle = {} };
    }

    /// Windows memory mapping implementation using CreateFileMappingW and MapViewOfFile.
    fn mapFileWindows(file: std.fs.File, size: usize) !MapResult {
        const PAGE_READONLY: windows.DWORD = 0x02;
        const FILE_MAP_READ: windows.DWORD = 0x0004;

        const mapping_handle = windows_mmap.CreateFileMappingW(
            file.handle,
            null,
            PAGE_READONLY,
            0,
            0,
            null,
        ) orelse return error.MmapFailed;
        errdefer _ = windows_mmap.CloseHandle(mapping_handle);

        const ptr = windows_mmap.MapViewOfFile(
            mapping_handle,
            FILE_MAP_READ,
            0,
            0,
            size,
        ) orelse return error.MmapFailed;

        return .{
            .slice = ptr[0..size],
            .handle = mapping_handle,
        };
    }

    /// POSIX munmap implementation.
    fn unmapFilePosix(slice: []align(page_size) u8) void {
        posix.munmap(slice);
    }

    /// Windows unmap implementation using UnmapViewOfFile.
    fn unmapFileWindows(slice: []align(page_size) u8, mapping_handle: ?windows.HANDLE) void {
        _ = windows_mmap.UnmapViewOfFile(slice.ptr);
        if (mapping_handle) |handle| {
            _ = windows_mmap.CloseHandle(handle);
        }
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
