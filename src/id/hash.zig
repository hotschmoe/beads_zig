//! Content hash generation for issue deduplication.
//!
//! Generates SHA256 content hashes for issues to detect duplicates during sync.
//! Hash includes all content-relevant fields separated by null bytes for
//! unambiguous parsing and stable ordering.

const std = @import("std");
const Issue = @import("../models/issue.zig").Issue;

/// Generate SHA256 content hash for an issue.
/// Returns a 64-character lowercase hex string.
///
/// Fields included (in order):
/// - title, description, design, acceptance_criteria, notes
/// - status, priority, issue_type
/// - assignee, owner, created_by
/// - external_ref, source_system
/// - pinned, is_template
///
/// Fields are separated by null bytes for stability.
/// Optional fields contribute empty string if null.
pub fn contentHash(issue: Issue) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Content fields
    hasher.update(issue.title);
    hasher.update("\x00");

    if (issue.description) |d| hasher.update(d);
    hasher.update("\x00");

    if (issue.design) |d| hasher.update(d);
    hasher.update("\x00");

    if (issue.acceptance_criteria) |a| hasher.update(a);
    hasher.update("\x00");

    if (issue.notes) |n| hasher.update(n);
    hasher.update("\x00");

    // Classification
    hasher.update(issue.status.toString());
    hasher.update("\x00");

    hasher.update(issue.priority.toString());
    hasher.update("\x00");

    hasher.update(issue.issue_type.toString());
    hasher.update("\x00");

    // Assignment
    if (issue.assignee) |a| hasher.update(a);
    hasher.update("\x00");

    if (issue.owner) |o| hasher.update(o);
    hasher.update("\x00");

    if (issue.created_by) |c| hasher.update(c);
    hasher.update("\x00");

    // External references
    if (issue.external_ref) |e| hasher.update(e);
    hasher.update("\x00");

    if (issue.source_system) |s| hasher.update(s);
    hasher.update("\x00");

    // Flags
    hasher.update(if (issue.pinned) "true" else "false");
    hasher.update("\x00");

    hasher.update(if (issue.is_template) "true" else "false");

    const digest = hasher.finalResult();

    // Convert to hex string
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        const chars = "0123456789abcdef";
        hex[i * 2] = chars[byte >> 4];
        hex[i * 2 + 1] = chars[byte & 0x0f];
    }
    return hex;
}

/// Generate content hash as heap-allocated string.
pub fn contentHashAlloc(allocator: std.mem.Allocator, issue: Issue) ![]u8 {
    const hash = contentHash(issue);
    return allocator.dupe(u8, &hash);
}

// --- Tests ---

test "contentHash deterministic" {
    const issue1 = Issue.init("bd-abc123", "Test issue", 1706540000);
    const issue2 = Issue.init("bd-abc123", "Test issue", 1706540000);

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expectEqualStrings(&hash1, &hash2);
}

test "contentHash different for different title" {
    const issue1 = Issue.init("bd-abc123", "First title", 1706540000);
    const issue2 = Issue.init("bd-abc123", "Second title", 1706540000);

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash different for different description" {
    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.description = "Description A";
    issue2.description = "Description B";

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash different for different status" {
    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.status = .open;
    issue2.status = .closed;

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash different for different priority" {
    const Priority = @import("../models/priority.zig").Priority;

    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.priority = Priority.HIGH;
    issue2.priority = Priority.LOW;

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash different for different issue_type" {
    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.issue_type = .task;
    issue2.issue_type = .bug;

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash different for different assignee" {
    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.assignee = "alice@example.com";
    issue2.assignee = "bob@example.com";

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash different for different flags" {
    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.pinned = true;
    issue2.pinned = false;

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash handles null optional fields" {
    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);

    // Should not crash when all optional fields are null
    const hash = contentHash(issue);
    try std.testing.expectEqual(@as(usize, 64), hash.len);
}

test "contentHash produces 64 hex characters" {
    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);
    const hash = contentHash(issue);

    try std.testing.expectEqual(@as(usize, 64), hash.len);

    // Verify all characters are lowercase hex
    for (hash) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "contentHash is lowercase" {
    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);
    const hash = contentHash(issue);

    // No uppercase characters
    for (hash) |c| {
        try std.testing.expect(c < 'A' or c > 'F');
    }
}

test "contentHashAlloc returns heap-allocated copy" {
    const allocator = std.testing.allocator;
    const issue = Issue.init("bd-abc123", "Test issue", 1706540000);

    const hash_stack = contentHash(issue);
    const hash_heap = try contentHashAlloc(allocator, issue);
    defer allocator.free(hash_heap);

    try std.testing.expectEqualStrings(&hash_stack, hash_heap);
    try std.testing.expect(hash_heap.ptr != &hash_stack);
}

test "contentHash ignores id field" {
    const issue1 = Issue.init("bd-abc123", "Same content", 1706540000);
    const issue2 = Issue.init("bd-xyz789", "Same content", 1706540000);

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    // Different IDs should produce the same content hash
    try std.testing.expectEqualStrings(&hash1, &hash2);
}

test "contentHash ignores timestamps" {
    const issue1 = Issue.init("bd-abc123", "Same content", 1000000000);
    const issue2 = Issue.init("bd-abc123", "Same content", 2000000000);

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    // Different timestamps should produce the same content hash
    try std.testing.expectEqualStrings(&hash1, &hash2);
}

test "contentHash with custom status" {
    const Status = @import("../models/status.zig").Status;

    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.status = Status{ .custom = "my_status" };
    issue2.status = Status{ .custom = "other_status" };

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "contentHash with custom issue_type" {
    const IssueType = @import("../models/issue_type.zig").IssueType;

    var issue1 = Issue.init("bd-abc123", "Same title", 1706540000);
    var issue2 = Issue.init("bd-abc123", "Same title", 1706540000);

    issue1.issue_type = IssueType{ .custom = "my_type" };
    issue2.issue_type = IssueType{ .custom = "other_type" };

    const hash1 = contentHash(issue1);
    const hash2 = contentHash(issue2);

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}
