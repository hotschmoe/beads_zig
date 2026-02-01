//! SIMD-accelerated utilities for beads_zig.
//!
//! Provides vectorized operations for:
//! - Newline scanning (16 bytes at a time)
//! - Pattern matching
//!
//! Falls back to scalar operations when SIMD is not available or beneficial.

const std = @import("std");

/// SIMD vector size for scanning operations.
/// 16 bytes (128-bit) is widely supported across architectures.
pub const VECTOR_SIZE = 16;

/// A newline scanner that uses SIMD to find newline positions efficiently.
/// Scans 16 bytes at a time, falling back to scalar for remainder.
pub const NewlineScanner = struct {
    const Self = @This();

    /// Iterator over newline positions in a byte slice.
    /// Returns byte offsets of each '\n' character.
    pub const Iterator = struct {
        data: []const u8,
        pos: usize,

        /// Get the next newline position, or null if none remain.
        pub fn next(self: *Iterator) ?usize {
            if (self.pos >= self.data.len) return null;

            // Use SIMD scanning when there's enough data
            while (self.pos + VECTOR_SIZE <= self.data.len) {
                const matches = findNewlinesSimd(self.data[self.pos..][0..VECTOR_SIZE]);
                if (matches != 0) {
                    // Found at least one newline in this chunk
                    const bit_offset: u5 = @intCast(@ctz(matches));
                    const result = self.pos + bit_offset;
                    self.pos = result + 1;
                    return result;
                }
                self.pos += VECTOR_SIZE;
            }

            // Scalar scan for remainder
            while (self.pos < self.data.len) {
                if (self.data[self.pos] == '\n') {
                    const result = self.pos;
                    self.pos += 1;
                    return result;
                }
                self.pos += 1;
            }

            return null;
        }
    };

    /// Create an iterator over newline positions.
    pub fn iterate(data: []const u8) Iterator {
        return .{ .data = data, .pos = 0 };
    }

    /// Find the next newline starting from a given position.
    /// Returns the position, or null if not found.
    pub fn findNext(data: []const u8, start: usize) ?usize {
        var it = Iterator{ .data = data, .pos = start };
        return it.next();
    }

    /// Count the number of newlines in the data.
    pub fn count(data: []const u8) usize {
        var n: usize = 0;
        var it = iterate(data);
        while (it.next()) |_| {
            n += 1;
        }
        return n;
    }

    /// Collect all newline positions into an array.
    /// Caller owns the returned slice.
    pub fn positions(allocator: std.mem.Allocator, data: []const u8) ![]usize {
        var result: std.ArrayListUnmanaged(usize) = .{};
        errdefer result.deinit(allocator);

        var it = iterate(data);
        while (it.next()) |pos| {
            try result.append(allocator, pos);
        }

        return result.toOwnedSlice(allocator);
    }
};

/// SIMD newline detection for a 16-byte chunk.
/// Returns a bitmask where bit N is set if byte N is a newline.
fn findNewlinesSimd(chunk: *const [VECTOR_SIZE]u8) u16 {
    // Load the chunk into a SIMD vector
    const data: @Vector(VECTOR_SIZE, u8) = chunk.*;

    // Create a vector of newline characters
    const needle: @Vector(VECTOR_SIZE, u8) = @splat('\n');

    // Compare: true where data[i] == '\n'
    const matches = data == needle;

    // Convert bool vector to integer bitmask
    return @bitCast(matches);
}

/// Scalar newline detection (for reference and fallback).
/// Returns the position of the first newline, or null.
pub fn findNewlineScalar(data: []const u8) ?usize {
    for (data, 0..) |c, i| {
        if (c == '\n') return i;
    }
    return null;
}

// --- Line Iterator ---

/// Iterator that yields slices between newlines.
/// More convenient than position-based iteration for parsing.
pub const LineIterator = struct {
    data: []const u8,
    pos: usize,
    scanner: NewlineScanner.Iterator,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{
            .data = data,
            .pos = 0,
            .scanner = NewlineScanner.iterate(data),
        };
    }

    /// Get the next line (excluding the newline character).
    /// Returns null when all lines have been consumed.
    pub fn next(self: *Self) ?[]const u8 {
        if (self.pos >= self.data.len) return null;

        // Find next newline
        if (self.scanner.next()) |nl_pos| {
            const line = self.data[self.pos..nl_pos];
            self.pos = nl_pos + 1;
            return line;
        }

        // No more newlines - return remaining data if any
        if (self.pos < self.data.len) {
            const line = self.data[self.pos..];
            self.pos = self.data.len;
            return line;
        }

        return null;
    }

    /// Skip empty lines and return the next non-empty line.
    pub fn nextNonEmpty(self: *Self) ?[]const u8 {
        while (self.next()) |line| {
            if (line.len > 0) return line;
        }
        return null;
    }
};

// --- Tests ---

test "findNewlinesSimd finds single newline" {
    const chunk = "Hello World!\n   ".*;
    const mask = findNewlinesSimd(&chunk);
    // Newline is at position 12
    try std.testing.expectEqual(@as(u16, 1 << 12), mask);
}

test "findNewlinesSimd finds multiple newlines" {
    const chunk = "Hi\nWorld\nTest!\n ".*;
    const mask = findNewlinesSimd(&chunk);
    // Newlines at positions 2, 8, 14
    try std.testing.expectEqual(@as(u16, (1 << 2) | (1 << 8) | (1 << 14)), mask);
}

test "findNewlinesSimd no newlines returns zero" {
    const chunk = "Hello World!    ".*;
    const mask = findNewlinesSimd(&chunk);
    try std.testing.expectEqual(@as(u16, 0), mask);
}

test "NewlineScanner.iterate finds all newlines" {
    const data = "line1\nline2\nline3\n";
    var it = NewlineScanner.iterate(data);

    try std.testing.expectEqual(@as(?usize, 5), it.next());
    try std.testing.expectEqual(@as(?usize, 11), it.next());
    try std.testing.expectEqual(@as(?usize, 17), it.next());
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "NewlineScanner.iterate handles no trailing newline" {
    const data = "line1\nline2";
    var it = NewlineScanner.iterate(data);

    try std.testing.expectEqual(@as(?usize, 5), it.next());
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "NewlineScanner.iterate handles empty string" {
    const data = "";
    var it = NewlineScanner.iterate(data);
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "NewlineScanner.iterate handles large data" {
    // Create data larger than VECTOR_SIZE with newlines
    var buf: [100]u8 = undefined;
    @memset(&buf, 'A');
    buf[15] = '\n'; // In first SIMD chunk
    buf[32] = '\n'; // In second SIMD chunk
    buf[99] = '\n'; // Near end

    var it = NewlineScanner.iterate(&buf);
    try std.testing.expectEqual(@as(?usize, 15), it.next());
    try std.testing.expectEqual(@as(?usize, 32), it.next());
    try std.testing.expectEqual(@as(?usize, 99), it.next());
    try std.testing.expectEqual(@as(?usize, null), it.next());
}

test "NewlineScanner.count" {
    try std.testing.expectEqual(@as(usize, 3), NewlineScanner.count("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 0), NewlineScanner.count("no newlines"));
    try std.testing.expectEqual(@as(usize, 1), NewlineScanner.count("\n"));
}

test "NewlineScanner.positions" {
    const allocator = std.testing.allocator;
    const data = "line1\nline2\nline3\n";
    const pos = try NewlineScanner.positions(allocator, data);
    defer allocator.free(pos);

    try std.testing.expectEqual(@as(usize, 3), pos.len);
    try std.testing.expectEqual(@as(usize, 5), pos[0]);
    try std.testing.expectEqual(@as(usize, 11), pos[1]);
    try std.testing.expectEqual(@as(usize, 17), pos[2]);
}

test "LineIterator yields correct lines" {
    const data = "line1\nline2\nline3";
    var it = LineIterator.init(data);

    try std.testing.expectEqualStrings("line1", it.next().?);
    try std.testing.expectEqualStrings("line2", it.next().?);
    try std.testing.expectEqualStrings("line3", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "LineIterator handles empty lines" {
    const data = "line1\n\nline3\n";
    var it = LineIterator.init(data);

    try std.testing.expectEqualStrings("line1", it.next().?);
    try std.testing.expectEqualStrings("", it.next().?);
    try std.testing.expectEqualStrings("line3", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "LineIterator.nextNonEmpty skips empty lines" {
    const data = "\n\nline1\n\nline2\n\n";
    var it = LineIterator.init(data);

    try std.testing.expectEqualStrings("line1", it.nextNonEmpty().?);
    try std.testing.expectEqualStrings("line2", it.nextNonEmpty().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.nextNonEmpty());
}

test "LineIterator handles data larger than VECTOR_SIZE" {
    // Create a line longer than VECTOR_SIZE
    const line1 = "A" ** 20;
    const line2 = "B" ** 30;
    const data = line1 ++ "\n" ++ line2 ++ "\n";

    var it = LineIterator.init(data);

    try std.testing.expectEqualStrings(line1, it.next().?);
    try std.testing.expectEqualStrings(line2, it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}
