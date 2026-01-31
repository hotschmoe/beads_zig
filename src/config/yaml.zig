//! Minimal YAML subset parser for beads_zig configuration.
//!
//! Supports a limited subset of YAML:
//! - Key-value pairs: `key: value`
//! - Comments: `# comment`
//! - Nested keys via dot notation in output: `parent.child`
//! - Basic indentation-based nesting (2 spaces)
//!
//! This is NOT a full YAML parser. For full YAML, consider using a C binding.

const std = @import("std");

pub const YamlError = error{
    InvalidSyntax,
    UnexpectedIndent,
    OutOfMemory,
    InvalidUtf8,
};

pub const YamlValue = union(enum) {
    string: []const u8,
    map: std.StringHashMapUnmanaged(YamlValue),

    pub fn deinit(self: *YamlValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .map => |*m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit(allocator);
                }
                m.deinit(allocator);
            },
        }
    }

    /// Get a value by dot-separated path (e.g., "id.prefix").
    /// Supports both nested structures and flattened key format.
    pub fn get(self: YamlValue, path: []const u8) ?[]const u8 {
        switch (self) {
            .string => return null,
            .map => |m| {
                // First try direct lookup (flattened format)
                if (m.get(path)) |val| {
                    return switch (val) {
                        .string => |s| s,
                        .map => null,
                    };
                }

                // Try nested traversal
                var current = self;
                var parts = std.mem.splitScalar(u8, path, '.');

                while (parts.next()) |part| {
                    switch (current) {
                        .map => |cm| {
                            const next = cm.get(part) orelse return null;
                            current = next;
                        },
                        .string => return null,
                    }
                }

                return switch (current) {
                    .string => |s| s,
                    .map => null,
                };
            },
        }
    }
};

/// Parse YAML content into a value tree.
/// Uses a simpler two-pass approach for stability.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) YamlError!YamlValue {
    var root = YamlValue{ .map = .{} };
    errdefer root.deinit(allocator);

    // Track current path for nested keys
    var path_stack: [32][]const u8 = undefined;
    var indent_stack: [32]usize = undefined;
    var stack_depth: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        // Remove trailing CR for Windows line endings
        const line = std.mem.trimRight(u8, raw_line, "\r");

        // Skip empty lines and comments
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Calculate indentation (number of leading spaces)
        const indent = line.len - trimmed.len;

        // Pop stack until we find lower indent
        while (stack_depth > 0 and indent_stack[stack_depth - 1] >= indent) {
            allocator.free(path_stack[stack_depth - 1]);
            stack_depth -= 1;
        }

        // Parse key: value
        const colon_pos = std.mem.indexOf(u8, trimmed, ":") orelse continue;

        const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
        if (key.len == 0) continue;

        const after_colon = trimmed[colon_pos + 1 ..];
        const value_str = std.mem.trim(u8, after_colon, " \t");

        // Build full path
        var full_key: []const u8 = undefined;
        if (stack_depth > 0) {
            // Concatenate parent path with current key
            var parts: std.ArrayListUnmanaged([]const u8) = .{};
            defer parts.deinit(allocator);
            for (0..stack_depth) |i| {
                try parts.append(allocator, path_stack[i]);
            }
            try parts.append(allocator, key);
            full_key = try std.mem.join(allocator, ".", parts.items);
        } else {
            full_key = try allocator.dupe(u8, key);
        }
        errdefer allocator.free(full_key);

        if (value_str.len == 0) {
            // This is a parent key - push to stack for children
            const key_copy = try allocator.dupe(u8, key);
            if (stack_depth < path_stack.len) {
                path_stack[stack_depth] = key_copy;
                indent_stack[stack_depth] = indent;
                stack_depth += 1;
            }
            allocator.free(full_key);
        } else {
            // Simple value - strip quotes if present
            var final_value = value_str;
            if (final_value.len >= 2) {
                if ((final_value[0] == '"' and final_value[final_value.len - 1] == '"') or
                    (final_value[0] == '\'' and final_value[final_value.len - 1] == '\''))
                {
                    final_value = final_value[1 .. final_value.len - 1];
                }
            }

            const value_copy = try allocator.dupe(u8, final_value);
            errdefer allocator.free(value_copy);

            try root.map.put(allocator, full_key, YamlValue{ .string = value_copy });
        }
    }

    // Clean up remaining stack
    for (0..stack_depth) |i| {
        allocator.free(path_stack[i]);
    }

    return root;
}

/// Flatten a YAML value tree into dot-separated key-value pairs.
pub fn flatten(
    allocator: std.mem.Allocator,
    value: YamlValue,
) ![]const struct { key: []const u8, value: []const u8 } {
    var result: std.ArrayListUnmanaged(struct { key: []const u8, value: []const u8 }) = .{};
    errdefer {
        for (result.items) |item| {
            allocator.free(item.key);
        }
        result.deinit(allocator);
    }

    try flattenInner(allocator, value, "", &result);

    return result.toOwnedSlice(allocator);
}

fn flattenInner(
    allocator: std.mem.Allocator,
    value: YamlValue,
    prefix: []const u8,
    result: *std.ArrayListUnmanaged(struct { key: []const u8, value: []const u8 }),
) !void {
    switch (value) {
        .string => |s| {
            const key = try allocator.dupe(u8, prefix);
            try result.append(allocator, .{ .key = key, .value = s });
        },
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                const new_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* })
                else
                    try allocator.dupe(u8, entry.key_ptr.*);
                defer if (prefix.len > 0) allocator.free(new_prefix);

                try flattenInner(allocator, entry.value_ptr.*, new_prefix, result);
            }
        },
    }
}

// --- Tests ---

test "parse simple key-value" {
    const allocator = std.testing.allocator;

    const content = "name: test\nversion: 1.0";
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("test", value.get("name").?);
    try std.testing.expectEqualStrings("1.0", value.get("version").?);
}

test "parse with comments" {
    const allocator = std.testing.allocator;

    const content = "# This is a comment\nkey: value\n# Another comment";
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("value", value.get("key").?);
}

test "parse nested structure" {
    const allocator = std.testing.allocator;

    const content =
        \\id:
        \\  prefix: bd
        \\  length: 4
        \\output:
        \\  color: auto
    ;
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("bd", value.get("id.prefix").?);
    try std.testing.expectEqualStrings("4", value.get("id.length").?);
    try std.testing.expectEqualStrings("auto", value.get("output.color").?);
}

test "parse quoted values" {
    const allocator = std.testing.allocator;

    const content = "single: 'hello'\ndouble: \"world\"";
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("hello", value.get("single").?);
    try std.testing.expectEqualStrings("world", value.get("double").?);
}

test "parse empty value" {
    const allocator = std.testing.allocator;

    const content = "empty:";
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    // Empty value creates a map, not a string
    try std.testing.expect(value.get("empty") == null);
}

test "get returns null for missing key" {
    const allocator = std.testing.allocator;

    const content = "key: value";
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    try std.testing.expect(value.get("missing") == null);
    try std.testing.expect(value.get("key.nested") == null);
}

test "parse handles Windows line endings" {
    const allocator = std.testing.allocator;

    const content = "key1: value1\r\nkey2: value2\r\n";
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("value1", value.get("key1").?);
    try std.testing.expectEqualStrings("value2", value.get("key2").?);
}

test "parse ignores blank lines" {
    const allocator = std.testing.allocator;

    const content = "key1: value1\n\n\nkey2: value2";
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    try std.testing.expectEqualStrings("value1", value.get("key1").?);
    try std.testing.expectEqualStrings("value2", value.get("key2").?);
}
