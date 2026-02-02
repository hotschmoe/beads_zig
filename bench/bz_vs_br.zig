const std = @import("std");
const bench = @import("main.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout();

    const bz_path = bench.findBz(allocator) catch {
        try stdout.writeAll("Error: bz binary not found\nRun: zig build\n");
        std.process.exit(1);
    };
    defer allocator.free(bz_path);

    const br_path = bench.findBr(allocator) catch {
        try stdout.writeAll("Error: br binary not found\nSet BR_PATH or ensure 'br' is in PATH\n");
        std.process.exit(1);
    };
    defer allocator.free(br_path);

    var bz_temp = try bench.TempDir.create(allocator, "bz_temp");
    defer bz_temp.cleanup();

    var br_temp = try bench.TempDir.create(allocator, "br_temp");
    defer br_temp.cleanup();

    try stdout.writeAll("=== Beads Benchmark: bz (Zig) vs br (Rust) ===\n\n");
    try bench.print(allocator, "Directories:\n  bz: {s}\n  br: {s}\n\n", .{ bz_temp.path, br_temp.path });

    // Step 1: Init
    try stdout.writeAll("[1/8] Initializing repositories...\n");

    try stdout.writeAll("  bz init: ");
    const bz_init_ms = (try bench.runCommand(allocator, &.{bz_path, "init"}, bz_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{bz_init_ms});

    try stdout.writeAll("  br init: ");
    const br_init_ms = (try bench.runCommand(allocator, &.{br_path, "init"}, br_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{br_init_ms});

    // Step 2: Create 10 beads and capture one ID for later tests
    try stdout.writeAll("[2/8] Creating 10 beads (sequential)...\n");

    try stdout.writeAll("  bz create x10: ");
    const bz_create_result = try bench.runCommandLoopCapture(allocator, &.{ bz_path, "q", "TestBead" }, bz_temp.path, 10);
    const bz_create_ms = bz_create_result.elapsed_ms;
    const bz_issue_id = bz_create_result.last_output;
    defer if (bz_issue_id) |id| allocator.free(id);
    try bench.print(allocator, "{d}ms (avg: {d}ms per bead)\n", .{ bz_create_ms, @divTrunc(bz_create_ms, 10) });

    try stdout.writeAll("  br create x10: ");
    const br_create_result = try bench.runCommandLoopCapture(allocator, &.{ br_path, "q", "TestBead" }, br_temp.path, 10);
    const br_create_ms = br_create_result.elapsed_ms;
    const br_issue_id = br_create_result.last_output;
    defer if (br_issue_id) |id| allocator.free(id);
    try bench.print(allocator, "{d}ms (avg: {d}ms per bead)\n", .{ br_create_ms, @divTrunc(br_create_ms, 10) });

    // Step 3: Show issue details
    try stdout.writeAll("[3/8] Showing issue details...\n");

    var bz_show_ms: i64 = 0;
    var br_show_ms: i64 = 0;

    if (bz_issue_id) |id| {
        try stdout.writeAll("  bz show: ");
        bz_show_ms = (try bench.runCommand(allocator, &.{ bz_path, "show", id }, bz_temp.path)).elapsed_ms;
        try bench.print(allocator, "{d}ms\n", .{bz_show_ms});
    } else {
        try stdout.writeAll("  bz show: skipped (no issue ID)\n");
    }

    if (br_issue_id) |id| {
        try stdout.writeAll("  br show: ");
        br_show_ms = (try bench.runCommand(allocator, &.{ br_path, "show", id }, br_temp.path)).elapsed_ms;
        try bench.print(allocator, "{d}ms\n", .{br_show_ms});
    } else {
        try stdout.writeAll("  br show: skipped (no issue ID)\n");
    }

    // Step 4: Update issue
    try stdout.writeAll("[4/8] Updating issue...\n");

    var bz_update_ms: i64 = 0;
    var br_update_ms: i64 = 0;

    if (bz_issue_id) |id| {
        try stdout.writeAll("  bz update: ");
        bz_update_ms = (try bench.runCommand(allocator, &.{ bz_path, "update", id, "--priority", "high" }, bz_temp.path)).elapsed_ms;
        try bench.print(allocator, "{d}ms\n", .{bz_update_ms});
    } else {
        try stdout.writeAll("  bz update: skipped (no issue ID)\n");
    }

    if (br_issue_id) |id| {
        try stdout.writeAll("  br update: ");
        br_update_ms = (try bench.runCommand(allocator, &.{ br_path, "update", id, "--priority", "high" }, br_temp.path)).elapsed_ms;
        try bench.print(allocator, "{d}ms\n", .{br_update_ms});
    } else {
        try stdout.writeAll("  br update: skipped (no issue ID)\n");
    }

    // Step 5: Search issues
    try stdout.writeAll("[5/8] Searching issues...\n");

    try stdout.writeAll("  bz search: ");
    const bz_search_ms = (try bench.runCommand(allocator, &.{ bz_path, "search", "TestBead" }, bz_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{bz_search_ms});

    try stdout.writeAll("  br search: ");
    const br_search_ms = (try bench.runCommand(allocator, &.{ br_path, "search", "TestBead" }, br_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{br_search_ms});

    // Step 6: List all beads
    try stdout.writeAll("[6/8] Listing all beads...\n");

    try stdout.writeAll("  bz list: ");
    const bz_list_ms = (try bench.runCommand(allocator, &.{ bz_path, "list", "--all" }, bz_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{bz_list_ms});

    try stdout.writeAll("  br list: ");
    const br_list_ms = (try bench.runCommand(allocator, &.{ br_path, "list", "--all" }, br_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{br_list_ms});

    // Step 7: Count and stats
    try stdout.writeAll("[7/8] Count and stats...\n");

    try stdout.writeAll("  bz count: ");
    const bz_count_ms = (try bench.runCommand(allocator, &.{ bz_path, "count" }, bz_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{bz_count_ms});

    try stdout.writeAll("  br count: ");
    const br_count_ms = (try bench.runCommand(allocator, &.{ br_path, "count" }, br_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{br_count_ms});

    try stdout.writeAll("  bz stats: ");
    const bz_stats_ms = (try bench.runCommand(allocator, &.{ bz_path, "stats" }, bz_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{bz_stats_ms});

    try stdout.writeAll("  br stats: ");
    const br_stats_ms = (try bench.runCommand(allocator, &.{ br_path, "stats" }, br_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{br_stats_ms});

    // Step 8: Close issue
    try stdout.writeAll("[8/8] Closing issue...\n");

    var bz_close_ms: i64 = 0;
    var br_close_ms: i64 = 0;

    if (bz_issue_id) |id| {
        try stdout.writeAll("  bz close: ");
        bz_close_ms = (try bench.runCommand(allocator, &.{ bz_path, "close", id }, bz_temp.path)).elapsed_ms;
        try bench.print(allocator, "{d}ms\n", .{bz_close_ms});
    } else {
        try stdout.writeAll("  bz close: skipped (no issue ID)\n");
    }

    if (br_issue_id) |id| {
        try stdout.writeAll("  br close: ");
        br_close_ms = (try bench.runCommand(allocator, &.{ br_path, "close", id }, br_temp.path)).elapsed_ms;
        try bench.print(allocator, "{d}ms\n", .{br_close_ms});
    } else {
        try stdout.writeAll("  br close: skipped (no issue ID)\n");
    }

    try stdout.writeAll("\nCleaning up... Done\n\n");

    // Summary table
    try stdout.writeAll("=== Summary ===\n");
    try bench.print(allocator, "{s: <20} {s: >10} {s: >10}\n", .{ "Operation", "bz (Zig)", "br (Rust)" });
    try bench.print(allocator, "{s: <20} {s: >10} {s: >10}\n", .{ "---------", "--------", "---------" });
    try bench.printCompareRow(allocator, "init", bz_init_ms, br_init_ms);
    try bench.printCompareRow(allocator, "create x10", bz_create_ms, br_create_ms);
    try bench.printCompareRow(allocator, "show", bz_show_ms, br_show_ms);
    try bench.printCompareRow(allocator, "update", bz_update_ms, br_update_ms);
    try bench.printCompareRow(allocator, "search", bz_search_ms, br_search_ms);
    try bench.printCompareRow(allocator, "list", bz_list_ms, br_list_ms);
    try bench.printCompareRow(allocator, "count", bz_count_ms, br_count_ms);
    try bench.printCompareRow(allocator, "stats", bz_stats_ms, br_stats_ms);
    try bench.printCompareRow(allocator, "close", bz_close_ms, br_close_ms);
    try stdout.writeAll("\nDone.\n");
}
