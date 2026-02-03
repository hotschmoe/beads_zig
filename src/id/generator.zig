//! Issue ID generation with adaptive length.
//!
//! Generates unique issue IDs in the format: <prefix>-<hash>
//! - prefix: Configurable, default "bd"
//! - hash: Base36 encoded, adaptive length (3-8 chars)
//!
//! The hash length adapts based on issue count to maintain
//! low collision probability while keeping IDs short.

const std = @import("std");
const base36 = @import("base36.zig");

pub const IdGenerator = struct {
    prefix: []const u8,
    min_length: u8,
    max_length: u8,
    prng: std.Random.DefaultPrng,

    pub fn init(prefix: []const u8) IdGenerator {
        const timestamp = std.time.nanoTimestamp();
        const seed: u64 = @truncate(@as(u128, @bitCast(timestamp)));
        return .{
            .prefix = prefix,
            .min_length = 3,
            .max_length = 8,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn initWithSeed(prefix: []const u8, seed: u64) IdGenerator {
        return .{
            .prefix = prefix,
            .min_length = 3,
            .max_length = 8,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Generate a new issue ID.
    /// Format: <prefix>-<base36_hash>
    /// Example: "bd-a3f8k2"
    pub fn generate(self: *IdGenerator, allocator: std.mem.Allocator, issue_count: usize) ![]u8 {
        // 1. Generate 16 random bytes
        var random_bytes: [16]u8 = undefined;
        self.prng.random().bytes(&random_bytes);

        // 2. Mix with nanosecond timestamp
        const timestamp_i128 = std.time.nanoTimestamp();
        const timestamp: u64 = @truncate(@as(u128, @bitCast(timestamp_i128)));
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&random_bytes);
        hasher.update(std.mem.asBytes(&timestamp));
        const digest = hasher.finalResult();

        // 3. Take first 8 bytes as u64 for base36 encoding
        const hash_value = std.mem.readInt(u64, digest[0..8], .big);

        // 4. Encode as base36
        var hash_buf: [base36.MAX_U64_ENCODED_LEN]u8 = undefined;
        const hash_str = base36.encode(hash_value, &hash_buf);

        // 5. Truncate to adaptive length
        const hash_length = self.adaptiveLength(issue_count);
        const final_len = @min(hash_str.len, hash_length);
        const final_hash = hash_str[0..final_len];

        // 6. Format: prefix-hash
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ self.prefix, final_hash });
    }

    /// Adaptive hash length based on issue count.
    /// Uses birthday problem approximation for collision resistance.
    ///
    /// Target: <0.1% collision probability per generation.
    /// Formula: P(collision) ~ n^2 / (2 * S) where S = 36^length
    ///
    /// Thresholds chosen conservatively:
    /// - 3 chars (46,656 space): safe for <100 issues (P < 0.1%)
    /// - 4 chars (1.68M space): safe for <1,000 issues (P < 0.03%)
    /// - 5 chars (60.5M space): safe for <10,000 issues (P < 0.008%)
    /// - 6 chars (2.18B space): safe for <100,000 issues
    /// - 7 chars (78.4B space): safe for <1,000,000 issues
    /// - 8 chars (2.82T space): safe for any practical count
    fn adaptiveLength(self: IdGenerator, count: usize) u8 {
        if (count < 100) return @max(self.min_length, 3);
        if (count < 1000) return @max(self.min_length, 4);
        if (count < 10000) return @max(self.min_length, 5);
        if (count < 100000) return @max(self.min_length, 6);
        if (count < 1000000) return @max(self.min_length, 7);
        return @min(self.max_length, 8);
    }

    /// Generate a unique issue ID with collision checking.
    /// Retries up to max_retries times if ID already exists.
    /// Returns error.CollisionLimitExceeded if all retries fail.
    pub fn generateUnique(
        self: *IdGenerator,
        allocator: std.mem.Allocator,
        issue_count: usize,
        existing_ids: anytype,
    ) ![]u8 {
        const max_retries = 10;
        var attempts: usize = 0;

        while (attempts < max_retries) : (attempts += 1) {
            const id = try self.generate(allocator, issue_count);

            // Check if ID already exists
            if (!existing_ids.contains(id)) {
                return id;
            }

            // ID collision - free and retry
            allocator.free(id);
        }

        return error.CollisionLimitExceeded;
    }

    /// Generate child ID for hierarchical issues.
    /// Example: "bd-abc123" -> "bd-abc123.1"
    /// Maximum 3 levels per SPEC (parent, child, grandchild).
    pub fn generateChild(
        _: *IdGenerator,
        allocator: std.mem.Allocator,
        parent_id: []const u8,
        child_index: u32,
    ) ![]u8 {
        // Validate depth (max 3 levels per SPEC)
        const depth = std.mem.count(u8, parent_id, ".");
        if (depth >= 2) return error.MaxHierarchyDepthExceeded;

        return std.fmt.allocPrint(allocator, "{s}.{d}", .{ parent_id, child_index });
    }
};

/// Parsed components of an issue ID.
pub const ParsedId = struct {
    prefix: []const u8,
    hash: []const u8,
    child_path: ?[]const u8,
};

/// Parse an ID into its components.
pub fn parseId(id: []const u8) !ParsedId {
    // Find prefix-hash boundary
    const dash_idx = std.mem.indexOf(u8, id, "-") orelse return error.InvalidIssueId;
    if (dash_idx == 0) return error.InvalidIssueId;

    const prefix = id[0..dash_idx];
    const rest = id[dash_idx + 1 ..];
    if (rest.len == 0) return error.InvalidIssueId;

    // Find hash-child boundary
    if (std.mem.indexOf(u8, rest, ".")) |dot_idx| {
        if (dot_idx == 0) return error.InvalidIssueId;
        const child = rest[dot_idx + 1 ..];
        if (child.len == 0) return error.InvalidIssueId;
        return .{
            .prefix = prefix,
            .hash = rest[0..dot_idx],
            .child_path = child,
        };
    }

    return .{
        .prefix = prefix,
        .hash = rest,
        .child_path = null,
    };
}

/// Validate ID format.
pub fn validateId(id: []const u8) bool {
    const parsed = parseId(id) catch return false;
    _ = base36.decode(parsed.hash) catch return false;
    return true;
}

// --- Tests ---

test "IdGenerator.init creates generator with defaults" {
    const gen = IdGenerator.init("bd");
    try std.testing.expectEqualStrings("bd", gen.prefix);
    try std.testing.expectEqual(@as(u8, 3), gen.min_length);
    try std.testing.expectEqual(@as(u8, 8), gen.max_length);
}

test "IdGenerator.generate produces valid format" {
    const allocator = std.testing.allocator;
    var gen = IdGenerator.initWithSeed("bd", 12345);

    const id = try gen.generate(allocator, 0);
    defer allocator.free(id);

    // Should start with prefix
    try std.testing.expect(std.mem.startsWith(u8, id, "bd-"));

    // Should be valid
    try std.testing.expect(validateId(id));
}

test "IdGenerator.generate adaptive length increases with count" {
    const allocator = std.testing.allocator;
    var gen = IdGenerator.initWithSeed("bd", 12345);

    // With 0 issues, should use minimum length (3)
    const id_small = try gen.generate(allocator, 0);
    defer allocator.free(id_small);
    const parsed_small = try parseId(id_small);
    try std.testing.expect(parsed_small.hash.len >= 3);

    // With 1000 issues, should use 5-char hashes (new threshold)
    var gen2 = IdGenerator.initWithSeed("bd", 12345);
    const id_medium = try gen2.generate(allocator, 1000);
    defer allocator.free(id_medium);
    const parsed_medium = try parseId(id_medium);
    try std.testing.expect(parsed_medium.hash.len >= 5);

    // With 1000000 issues, should use 8-char hashes (max)
    var gen3 = IdGenerator.initWithSeed("bd", 12345);
    const id_large = try gen3.generate(allocator, 1000000);
    defer allocator.free(id_large);
    const parsed_large = try parseId(id_large);
    try std.testing.expect(parsed_large.hash.len >= 8);
}

test "IdGenerator.generateChild creates hierarchical ID" {
    const allocator = std.testing.allocator;
    var gen = IdGenerator.init("bd");

    const child = try gen.generateChild(allocator, "bd-abc123", 1);
    defer allocator.free(child);
    try std.testing.expectEqualStrings("bd-abc123.1", child);

    const grandchild = try gen.generateChild(allocator, "bd-abc123.1", 2);
    defer allocator.free(grandchild);
    try std.testing.expectEqualStrings("bd-abc123.1.2", grandchild);
}

test "IdGenerator.generateChild rejects too deep hierarchy" {
    const allocator = std.testing.allocator;
    var gen = IdGenerator.init("bd");

    // bd-abc123.1.2 already has 2 dots, can't go deeper
    try std.testing.expectError(
        error.MaxHierarchyDepthExceeded,
        gen.generateChild(allocator, "bd-abc123.1.2", 3),
    );
}

test "parseId extracts components" {
    const parsed = try parseId("bd-abc123");
    try std.testing.expectEqualStrings("bd", parsed.prefix);
    try std.testing.expectEqualStrings("abc123", parsed.hash);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.child_path);
}

test "parseId extracts child path" {
    const parsed = try parseId("bd-abc123.1.2");
    try std.testing.expectEqualStrings("bd", parsed.prefix);
    try std.testing.expectEqualStrings("abc123", parsed.hash);
    try std.testing.expectEqualStrings("1.2", parsed.child_path.?);
}

test "parseId rejects invalid formats" {
    try std.testing.expectError(error.InvalidIssueId, parseId("invalid"));
    try std.testing.expectError(error.InvalidIssueId, parseId("-abc"));
    try std.testing.expectError(error.InvalidIssueId, parseId("bd-"));
    try std.testing.expectError(error.InvalidIssueId, parseId("bd-.1"));
}

test "validateId accepts valid IDs" {
    try std.testing.expect(validateId("bd-abc"));
    try std.testing.expect(validateId("bd-a3f8k2"));
    try std.testing.expect(validateId("custom-xyz789"));
    try std.testing.expect(validateId("bd-abc123.1"));
    try std.testing.expect(validateId("bd-abc123.1.2"));
}

test "validateId rejects invalid IDs" {
    try std.testing.expect(!validateId("invalid"));
    try std.testing.expect(!validateId("-abc"));
    try std.testing.expect(!validateId("bd-"));
    try std.testing.expect(!validateId(""));
    try std.testing.expect(!validateId("bd-!!!"));
}

test "generated IDs are unique" {
    const allocator = std.testing.allocator;
    var gen = IdGenerator.initWithSeed("bd", 42);

    var ids = std.StringHashMap(void).init(allocator);
    defer {
        var iter = ids.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        ids.deinit();
    }

    // Generate IDs and check for collisions.
    // Pass issue_count=10000 to use 6-char hashes (36^6 = 2.18B space).
    // With 50 IDs, birthday collision probability is negligible.
    const count = 50;
    const base_count = 10000; // Force 6-char hashes for better uniqueness
    for (0..count) |i| {
        const id = try gen.generate(allocator, base_count + i);
        errdefer allocator.free(id);

        if (ids.contains(id)) {
            std.debug.print("Collision detected: {s}\n", .{id});
            try std.testing.expect(false);
        }

        try ids.put(id, {});
    }

    try std.testing.expectEqual(count, ids.count());
}

test "custom prefix works" {
    const allocator = std.testing.allocator;
    var gen = IdGenerator.initWithSeed("myapp", 12345);

    const id = try gen.generate(allocator, 0);
    defer allocator.free(id);

    try std.testing.expect(std.mem.startsWith(u8, id, "myapp-"));
    try std.testing.expect(validateId(id));
}

test "generateUnique avoids collisions" {
    const allocator = std.testing.allocator;
    var gen = IdGenerator.initWithSeed("bd", 42);

    // Create a set with one pre-existing ID
    var existing = std.StringHashMap(void).init(allocator);
    defer existing.deinit();

    // Generate first ID
    const id1 = try gen.generate(allocator, 0);
    defer allocator.free(id1);
    try existing.put(id1, {});

    // generateUnique should return a different ID
    const id2 = try gen.generateUnique(allocator, 0, existing);
    defer allocator.free(id2);

    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    try std.testing.expect(!existing.contains(id2));
}
