//! Metrics command for beads_zig.
//!
//! `bz metrics` - Show lock contention and performance metrics
//!
//! Reports process-local lock statistics useful for debugging
//! concurrency issues in multi-agent scenarios.

const std = @import("std");
const common = @import("common.zig");
const args = @import("args.zig");
const storage = @import("../storage/mod.zig");

pub const MetricsError = error{
    WriteError,
    OutOfMemory,
};

pub const MetricsResult = struct {
    success: bool,
    metrics: ?storage.metrics.JsonMetrics = null,
    message: ?[]const u8 = null,
};

pub fn run(
    metrics_args: args.MetricsArgs,
    global: args.GlobalOptions,
    allocator: std.mem.Allocator,
) MetricsError!void {
    var output = common.initOutput(allocator, global);

    // Get current metrics
    const lock_metrics = storage.getMetrics();

    // Handle reset flag
    if (metrics_args.reset) {
        storage.resetMetrics();
        if (global.isStructuredOutput()) {
            output.printJson(MetricsResult{
                .success = true,
                .message = "Metrics reset successfully",
            }) catch return MetricsError.WriteError;
        } else if (!global.quiet) {
            output.print("Metrics reset successfully.\n", .{}) catch return MetricsError.WriteError;
        }
        return;
    }

    // Output metrics
    if (global.isStructuredOutput()) {
        output.printJson(MetricsResult{
            .success = true,
            .metrics = lock_metrics.toJson(),
        }) catch return MetricsError.WriteError;
    } else if (!global.quiet) {
        const formatted = lock_metrics.format(allocator) catch return MetricsError.OutOfMemory;
        defer allocator.free(formatted);
        output.print("{s}\n", .{formatted}) catch return MetricsError.WriteError;
    }
}

// --- Tests ---

test "MetricsError enum exists" {
    const err: MetricsError = MetricsError.WriteError;
    try std.testing.expect(err == MetricsError.WriteError);
}

test "MetricsResult struct works" {
    const result = MetricsResult{
        .success = true,
        .message = "test",
    };
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("test", result.message.?);
}
