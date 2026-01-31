//! Unified error types and helpers for beads_zig.
//!
//! This module provides a unified error handling strategy across the codebase,
//! with structured error codes for machine-readable output.

const std = @import("std");

/// Error category for structured error reporting.
pub const ErrorCategory = enum {
    workspace,
    issue,
    storage,
    config,
    dependency,
    validation,
    network,
    internal,

    pub fn toString(self: ErrorCategory) []const u8 {
        return switch (self) {
            .workspace => "WORKSPACE",
            .issue => "ISSUE",
            .storage => "STORAGE",
            .config => "CONFIG",
            .dependency => "DEPENDENCY",
            .validation => "VALIDATION",
            .network => "NETWORK",
            .internal => "INTERNAL",
        };
    }
};

/// Unified error representation for structured output.
pub const BeadsError = struct {
    code: []const u8,
    category: ErrorCategory,
    message: []const u8,
    details: ?[]const u8 = null,
    issue_id: ?[]const u8 = null,

    const Self = @This();

    /// Create a workspace error.
    pub fn workspaceNotInitialized() Self {
        return .{
            .code = "E001",
            .category = .workspace,
            .message = "Workspace not initialized",
            .details = "Run 'bz init' to initialize a new workspace",
        };
    }

    pub fn workspaceAlreadyInitialized() Self {
        return .{
            .code = "E002",
            .category = .workspace,
            .message = "Workspace already initialized",
        };
    }

    /// Create an issue error.
    pub fn issueNotFound(id: []const u8) Self {
        return .{
            .code = "E101",
            .category = .issue,
            .message = "Issue not found",
            .issue_id = id,
        };
    }

    pub fn issueDuplicate(id: []const u8) Self {
        return .{
            .code = "E102",
            .category = .issue,
            .message = "Duplicate issue ID",
            .issue_id = id,
        };
    }

    pub fn issueInvalidTitle(reason: []const u8) Self {
        return .{
            .code = "E103",
            .category = .validation,
            .message = "Invalid issue title",
            .details = reason,
        };
    }

    /// Create a dependency error.
    pub fn dependencySelfReference(id: []const u8) Self {
        return .{
            .code = "E201",
            .category = .dependency,
            .message = "Cannot create self-dependency",
            .issue_id = id,
        };
    }

    pub fn dependencyCycle(ids: []const u8) Self {
        return .{
            .code = "E202",
            .category = .dependency,
            .message = "Dependency cycle detected",
            .details = ids,
        };
    }

    pub fn dependencyNotFound(id: []const u8) Self {
        return .{
            .code = "E203",
            .category = .dependency,
            .message = "Dependency not found",
            .issue_id = id,
        };
    }

    /// Create a storage error.
    pub fn storageReadFailed(path: []const u8) Self {
        return .{
            .code = "E301",
            .category = .storage,
            .message = "Failed to read file",
            .details = path,
        };
    }

    pub fn storageWriteFailed(path: []const u8) Self {
        return .{
            .code = "E302",
            .category = .storage,
            .message = "Failed to write file",
            .details = path,
        };
    }

    pub fn storageLockFailed() Self {
        return .{
            .code = "E303",
            .category = .storage,
            .message = "Failed to acquire lock",
            .details = "Another process may be holding the lock",
        };
    }

    pub fn storageLockTimeout() Self {
        return .{
            .code = "E304",
            .category = .storage,
            .message = "Lock acquisition timed out",
        };
    }

    pub fn storageCorrupted(reason: []const u8) Self {
        return .{
            .code = "E305",
            .category = .storage,
            .message = "Storage file corrupted",
            .details = reason,
        };
    }

    /// Create a config error.
    pub fn configNotFound(key: []const u8) Self {
        return .{
            .code = "E401",
            .category = .config,
            .message = "Configuration key not found",
            .details = key,
        };
    }

    pub fn configInvalidValue(reason: []const u8) Self {
        return .{
            .code = "E402",
            .category = .config,
            .message = "Invalid configuration value",
            .details = reason,
        };
    }

    /// Create a validation error.
    pub fn validationFailed(reason: []const u8) Self {
        return .{
            .code = "E501",
            .category = .validation,
            .message = "Validation failed",
            .details = reason,
        };
    }

    /// Create an internal error.
    pub fn internal(reason: []const u8) Self {
        return .{
            .code = "E999",
            .category = .internal,
            .message = "Internal error",
            .details = reason,
        };
    }

    /// Format error as human-readable message.
    /// Caller owns the returned memory and must free it.
    pub fn format(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        if (self.issue_id != null and self.details != null) {
            return std.fmt.allocPrint(allocator, "{s} (issue: {s}): {s}", .{
                self.message,
                self.issue_id.?,
                self.details.?,
            });
        } else if (self.issue_id) |id| {
            return std.fmt.allocPrint(allocator, "{s} (issue: {s})", .{
                self.message,
                id,
            });
        } else if (self.details) |details| {
            return std.fmt.allocPrint(allocator, "{s}: {s}", .{
                self.message,
                details,
            });
        } else {
            return allocator.dupe(u8, self.message);
        }
    }

    /// JSON serialization for structured output.
    pub fn jsonStringify(self: Self, jws: anytype) !void {
        try jws.beginObject();

        try jws.objectField("code");
        try jws.write(self.code);

        try jws.objectField("category");
        try jws.write(self.category.toString());

        try jws.objectField("message");
        try jws.write(self.message);

        if (self.details) |d| {
            try jws.objectField("details");
            try jws.write(d);
        }

        if (self.issue_id) |id| {
            try jws.objectField("issue_id");
            try jws.write(id);
        }

        try jws.endObject();
    }
};

/// Helper to convert Zig errors to BeadsError.
pub fn fromError(err: anyerror) BeadsError {
    return switch (err) {
        error.FileNotFound => BeadsError.storageReadFailed("File not found"),
        error.AccessDenied => BeadsError.storageReadFailed("Access denied"),
        error.OutOfMemory => BeadsError.internal("Out of memory"),
        error.WouldBlock => BeadsError.storageLockFailed(),
        else => BeadsError.internal(@errorName(err)),
    };
}

/// Result type that can hold either a value or a BeadsError.
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: BeadsError,

        const Self = @This();

        pub fn isOk(self: Self) bool {
            return self == .ok;
        }

        pub fn isErr(self: Self) bool {
            return self == .err;
        }

        pub fn unwrap(self: Self) T {
            return switch (self) {
                .ok => |v| v,
                .err => unreachable,
            };
        }

        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self) {
                .ok => |v| v,
                .err => default,
            };
        }

        pub fn unwrapErr(self: Self) BeadsError {
            return switch (self) {
                .ok => unreachable,
                .err => |e| e,
            };
        }
    };
}

// --- Tests ---

test "ErrorCategory.toString returns correct strings" {
    try std.testing.expectEqualStrings("WORKSPACE", ErrorCategory.workspace.toString());
    try std.testing.expectEqualStrings("ISSUE", ErrorCategory.issue.toString());
    try std.testing.expectEqualStrings("STORAGE", ErrorCategory.storage.toString());
    try std.testing.expectEqualStrings("CONFIG", ErrorCategory.config.toString());
    try std.testing.expectEqualStrings("DEPENDENCY", ErrorCategory.dependency.toString());
    try std.testing.expectEqualStrings("VALIDATION", ErrorCategory.validation.toString());
    try std.testing.expectEqualStrings("NETWORK", ErrorCategory.network.toString());
    try std.testing.expectEqualStrings("INTERNAL", ErrorCategory.internal.toString());
}

test "BeadsError.workspaceNotInitialized" {
    const err = BeadsError.workspaceNotInitialized();
    try std.testing.expectEqualStrings("E001", err.code);
    try std.testing.expectEqual(ErrorCategory.workspace, err.category);
    try std.testing.expect(err.details != null);
}

test "BeadsError.issueNotFound" {
    const err = BeadsError.issueNotFound("bd-001");
    try std.testing.expectEqualStrings("E101", err.code);
    try std.testing.expectEqualStrings("bd-001", err.issue_id.?);
}

test "BeadsError.dependencyCycle" {
    const err = BeadsError.dependencyCycle("A -> B -> A");
    try std.testing.expectEqualStrings("E202", err.code);
    try std.testing.expectEqual(ErrorCategory.dependency, err.category);
}

test "BeadsError.format" {
    const allocator = std.testing.allocator;

    const err = BeadsError.issueNotFound("bd-001");
    const formatted = try err.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "bd-001") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "not found") != null);
}

test "BeadsError.format with details" {
    const allocator = std.testing.allocator;

    const err = BeadsError.storageCorrupted("Invalid JSON at line 5");
    const formatted = try err.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "line 5") != null);
}

test "fromError converts common errors" {
    const err1 = fromError(error.FileNotFound);
    try std.testing.expectEqual(ErrorCategory.storage, err1.category);

    const err2 = fromError(error.OutOfMemory);
    try std.testing.expectEqual(ErrorCategory.internal, err2.category);
}

test "Result type works for success" {
    const result: Result(u32) = .{ .ok = 42 };
    try std.testing.expect(result.isOk());
    try std.testing.expect(!result.isErr());
    try std.testing.expectEqual(@as(u32, 42), result.unwrap());
}

test "Result type works for error" {
    const result: Result(u32) = .{ .err = BeadsError.issueNotFound("test") };
    try std.testing.expect(!result.isOk());
    try std.testing.expect(result.isErr());
    try std.testing.expectEqualStrings("E101", result.unwrapErr().code);
}

test "Result.unwrapOr returns default on error" {
    const result: Result(u32) = .{ .err = BeadsError.internal("oops") };
    try std.testing.expectEqual(@as(u32, 99), result.unwrapOr(99));
}

test "BeadsError JSON serialization" {
    const allocator = std.testing.allocator;

    const err = BeadsError.issueNotFound("bd-123");

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(err, .{}, &aw.writer);
    const json_str = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, json_str, "E101") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "ISSUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "bd-123") != null);
}
