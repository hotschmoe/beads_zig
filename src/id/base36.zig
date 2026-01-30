//! Base36 encoding and decoding for issue ID hash generation.
//!
//! Base36 uses digits 0-9 and lowercase letters a-z, producing
//! compact alphanumeric strings suitable for human-readable IDs.

const std = @import("std");

/// Character set for Base36: 0-9, a-z (lowercase)
const CHARSET = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Maximum encoded length for a u64 value in Base36 (ceiling of log36(2^64))
pub const MAX_U64_ENCODED_LEN = 13;

/// Encode a u64 value to Base36 string.
/// Returns slice of buffer containing result.
/// Buffer must be at least MAX_U64_ENCODED_LEN bytes.
pub fn encode(value: u64, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= MAX_U64_ENCODED_LEN);

    if (value == 0) {
        buffer[0] = '0';
        return buffer[0..1];
    }

    var v = value;
    var i: usize = buffer.len;
    while (v > 0) {
        i -= 1;
        buffer[i] = CHARSET[@intCast(v % 36)];
        v /= 36;
    }
    return buffer[i..];
}

/// Encode to heap-allocated string.
pub fn encodeAlloc(allocator: std.mem.Allocator, value: u64) ![]u8 {
    var buf: [MAX_U64_ENCODED_LEN]u8 = undefined;
    const result = encode(value, &buf);
    return allocator.dupe(u8, result);
}

/// Decode Base36 string to u64.
/// Case-insensitive: accepts both uppercase and lowercase.
/// Returns error for invalid characters, empty input, or overflow.
pub fn decode(s: []const u8) !u64 {
    if (s.len == 0) return error.EmptyInput;

    var result: u64 = 0;
    for (s) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            else => return error.InvalidCharacter,
        };
        result = std.math.mul(u64, result, 36) catch return error.Overflow;
        result = std.math.add(u64, result, digit) catch return error.Overflow;
    }
    return result;
}

/// Calculate the encoded length for a given value without encoding.
pub fn encodedLength(value: u64) usize {
    if (value == 0) return 1;
    var v = value;
    var len: usize = 0;
    while (v > 0) {
        len += 1;
        v /= 36;
    }
    return len;
}

test "encode zero" {
    var buf: [MAX_U64_ENCODED_LEN]u8 = undefined;
    const result = encode(0, &buf);
    try std.testing.expectEqualStrings("0", result);
}

test "encode produces lowercase" {
    var buf: [MAX_U64_ENCODED_LEN]u8 = undefined;

    // 10 = 'a', 35 = 'z'
    try std.testing.expectEqualStrings("a", encode(10, &buf));
    try std.testing.expectEqualStrings("z", encode(35, &buf));

    // 36 = "10", 37 = "11", etc.
    try std.testing.expectEqualStrings("10", encode(36, &buf));

    // Larger value with letters
    try std.testing.expectEqualStrings("rs", encode(1000, &buf));
}

test "encode max u64" {
    var buf: [MAX_U64_ENCODED_LEN]u8 = undefined;
    const result = encode(std.math.maxInt(u64), &buf);
    // max u64 = 18446744073709551615 = "3w5e11264sgsf" in base36
    try std.testing.expectEqualStrings("3w5e11264sgsf", result);
    try std.testing.expectEqual(@as(usize, 13), result.len);
}

test "decode accepts lowercase" {
    try std.testing.expectEqual(@as(u64, 10), try decode("a"));
    try std.testing.expectEqual(@as(u64, 35), try decode("z"));
    try std.testing.expectEqual(@as(u64, 1000), try decode("rs"));
}

test "decode accepts uppercase" {
    try std.testing.expectEqual(@as(u64, 10), try decode("A"));
    try std.testing.expectEqual(@as(u64, 35), try decode("Z"));
    try std.testing.expectEqual(@as(u64, 1000), try decode("RS"));
}

test "decode accepts mixed case" {
    try std.testing.expectEqual(@as(u64, 1000), try decode("Rs"));
    try std.testing.expectEqual(@as(u64, 1000), try decode("rS"));
}

test "decode error on empty input" {
    try std.testing.expectError(error.EmptyInput, decode(""));
}

test "decode error on invalid character" {
    try std.testing.expectError(error.InvalidCharacter, decode("!"));
    try std.testing.expectError(error.InvalidCharacter, decode("abc!def"));
    try std.testing.expectError(error.InvalidCharacter, decode(" "));
    try std.testing.expectError(error.InvalidCharacter, decode("abc def"));
}

test "decode overflow" {
    // String that would overflow u64: "zzzzzzzzzzzzzzz" (15 z's)
    try std.testing.expectError(error.Overflow, decode("zzzzzzzzzzzzzzz"));
}

test "encode decode roundtrip" {
    const allocator = std.testing.allocator;
    const values = [_]u64{
        0,
        1,
        9,
        10,
        35,
        36,
        100,
        1000,
        10000,
        100000,
        1000000,
        std.math.maxInt(u32),
        std.math.maxInt(u64),
    };
    for (values) |v| {
        const encoded = try encodeAlloc(allocator, v);
        defer allocator.free(encoded);
        const decoded = try decode(encoded);
        try std.testing.expectEqual(v, decoded);
    }
}

test "encodedLength" {
    try std.testing.expectEqual(@as(usize, 1), encodedLength(0));
    try std.testing.expectEqual(@as(usize, 1), encodedLength(1));
    try std.testing.expectEqual(@as(usize, 1), encodedLength(35));
    try std.testing.expectEqual(@as(usize, 2), encodedLength(36));
    try std.testing.expectEqual(@as(usize, 2), encodedLength(1000));
    try std.testing.expectEqual(@as(usize, 3), encodedLength(36 * 36));
    try std.testing.expectEqual(@as(usize, 13), encodedLength(std.math.maxInt(u64)));
}

test "encodedLength matches actual encoded length" {
    const allocator = std.testing.allocator;
    const values = [_]u64{ 0, 1, 35, 36, 1000, 10000, std.math.maxInt(u64) };
    for (values) |v| {
        const encoded = try encodeAlloc(allocator, v);
        defer allocator.free(encoded);
        try std.testing.expectEqual(encoded.len, encodedLength(v));
    }
}
