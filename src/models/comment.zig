//! Comment struct for issue comments.
//!
//! Comments provide a way to add discussion, notes, and updates to issues.
//! Each comment is associated with an issue and tracked with author and timestamp.

const std = @import("std");

/// Validation errors for Comment.
pub const CommentError = error{
    EmptyCommentText,
    EmptyAuthor,
    EmptyIssueId,
};

/// A comment attached to an issue.
pub const Comment = struct {
    id: i64, // Unique identifier, 0 for new comments before insert
    issue_id: []const u8, // Parent issue ID
    author: []const u8, // Who wrote the comment
    text: []const u8, // Comment content
    created_at: i64, // Unix timestamp

    const Self = @This();

    /// Validate that the comment has all required fields populated.
    pub fn validate(self: Self) CommentError!void {
        if (self.text.len == 0) return CommentError.EmptyCommentText;
        if (self.author.len == 0) return CommentError.EmptyAuthor;
        if (self.issue_id.len == 0) return CommentError.EmptyIssueId;
    }

    /// Check deep equality between two Comments.
    pub fn eql(a: Self, b: Self) bool {
        return a.id == b.id and
            a.created_at == b.created_at and
            std.mem.eql(u8, a.issue_id, b.issue_id) and
            std.mem.eql(u8, a.author, b.author) and
            std.mem.eql(u8, a.text, b.text);
    }
};

// --- Comment Tests ---

test "Comment.validate accepts valid comment" {
    const comment = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "This is a valid comment.",
        .created_at = 1706540000,
    };

    try comment.validate();
}

test "Comment.validate rejects empty body" {
    const comment = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "",
        .created_at = 1706540000,
    };

    try std.testing.expectError(CommentError.EmptyCommentText, comment.validate());
}

test "Comment.validate rejects empty author" {
    const comment = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "",
        .text = "This is a comment.",
        .created_at = 1706540000,
    };

    try std.testing.expectError(CommentError.EmptyAuthor, comment.validate());
}

test "Comment.validate rejects empty issue_id" {
    const comment = Comment{
        .id = 1,
        .issue_id = "",
        .author = "alice@example.com",
        .text = "This is a comment.",
        .created_at = 1706540000,
    };

    try std.testing.expectError(CommentError.EmptyIssueId, comment.validate());
}

test "Comment.validate with id=0 for new comment" {
    const comment = Comment{
        .id = 0,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "New comment before insert.",
        .created_at = 1706540000,
    };

    try comment.validate();
}

test "Comment.eql compares all fields" {
    const comment1 = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "Test comment",
        .created_at = 1706540000,
    };

    const comment2 = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "Test comment",
        .created_at = 1706540000,
    };

    try std.testing.expect(Comment.eql(comment1, comment2));
}

test "Comment.eql detects id difference" {
    const comment1 = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "Test comment",
        .created_at = 1706540000,
    };

    const comment2 = Comment{
        .id = 2,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "Test comment",
        .created_at = 1706540000,
    };

    try std.testing.expect(!Comment.eql(comment1, comment2));
}

test "Comment.eql detects body difference" {
    const comment1 = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "First comment",
        .created_at = 1706540000,
    };

    const comment2 = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "Second comment",
        .created_at = 1706540000,
    };

    try std.testing.expect(!Comment.eql(comment1, comment2));
}

test "Comment.eql detects author difference" {
    const comment1 = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "Test comment",
        .created_at = 1706540000,
    };

    const comment2 = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "bob@example.com",
        .text = "Test comment",
        .created_at = 1706540000,
    };

    try std.testing.expect(!Comment.eql(comment1, comment2));
}

test "Comment JSON serialization roundtrip" {
    const allocator = std.testing.allocator;

    const comment = Comment{
        .id = 42,
        .issue_id = "bd-abc123",
        .author = "alice@example.com",
        .text = "This is a test comment.",
        .created_at = 1706540000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(comment, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Comment, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Comment.eql(comment, parsed.value));
}

test "Comment JSON serialization with multiline body" {
    const allocator = std.testing.allocator;

    const comment = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "developer@example.com",
        .text = "Line 1\nLine 2\nLine 3\n\nWith empty line above.",
        .created_at = 1706540000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(comment, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Comment, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Comment.eql(comment, parsed.value));
    try std.testing.expectEqualStrings(comment.text, parsed.value.text);
}

test "Comment JSON serialization with unicode body" {
    const allocator = std.testing.allocator;

    const comment = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "user@example.com",
        .text = "Unicode test: Hello World! Chinese: \u{4F60}\u{597D} Japanese: \u{3053}\u{3093}\u{306B}\u{3061}\u{306F}",
        .created_at = 1706540000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(comment, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Comment, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Comment.eql(comment, parsed.value));
    try std.testing.expectEqualStrings(comment.text, parsed.value.text);
}

test "Comment JSON contains expected fields" {
    const allocator = std.testing.allocator;

    const comment = Comment{
        .id = 99,
        .issue_id = "bd-test",
        .author = "tester",
        .text = "Test body",
        .created_at = 1234567890,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(comment, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"issue_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"author\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"created_at\"") != null);
}

test "Comment JSON serialization with special characters in body" {
    const allocator = std.testing.allocator;

    const comment = Comment{
        .id = 1,
        .issue_id = "bd-abc123",
        .author = "dev@example.com",
        .text = "Special chars: \"quotes\" and \\backslash\\ and \ttab and /slashes/",
        .created_at = 1706540000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(comment, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Comment, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Comment.eql(comment, parsed.value));
    try std.testing.expectEqualStrings(comment.text, parsed.value.text);
}

test "Comment with id=0 JSON roundtrip" {
    const allocator = std.testing.allocator;

    const comment = Comment{
        .id = 0,
        .issue_id = "bd-new",
        .author = "creator@example.com",
        .text = "New comment awaiting insert.",
        .created_at = 1706550000,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(comment, .{}, &aw.writer);
    const json_str = aw.written();

    const parsed = try std.json.parseFromSlice(Comment, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(Comment.eql(comment, parsed.value));
    try std.testing.expectEqual(@as(i64, 0), parsed.value.id);
}
