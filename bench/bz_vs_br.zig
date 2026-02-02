const std = @import("std");
const bench = @import("main.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.fs.File.stdout();

    // Find bz binary
    const bz_path = bench.findBz(allocator) catch {
        try stdout_file.writeAll("Error: bz binary not found\n");
        try stdout_file.writeAll("Run: zig build\n");
        std.process.exit(1);
    };
    defer allocator.free(bz_path);

    // Find br binary
    const br_path = bench.findBr(allocator) catch {
        try stdout_file.writeAll("Error: br binary not found\n");
        try stdout_file.writeAll("Set BR_PATH or ensure 'br' is in PATH\n");
        std.process.exit(1);
    };
    defer allocator.free(br_path);

    // Create temp directories
    var bz_temp = try bench.TempDir.create(allocator, "bz_temp");
    defer bz_temp.cleanup();

    var br_temp = try bench.TempDir.create(allocator, "br_temp");
    defer br_temp.cleanup();

    try bench.print(allocator, stdout_file, "=== Beads Benchmark: bz (Zig) vs br (Rust) ===\n", .{});
    try bench.print(allocator, stdout_file, "\n", .{});
    try bench.print(allocator, stdout_file, "Directories:\n", .{});
    try bench.print(allocator, stdout_file, "  bz: {s}\n", .{bz_temp.path});
    try bench.print(allocator, stdout_file, "  br: {s}\n", .{br_temp.path});
    try bench.print(allocator, stdout_file, "\n", .{});

    // Step 1: Init
    try bench.print(allocator, stdout_file, "[1/4] Initializing repositories...\n", .{});

    try bench.print(allocator, stdout_file, "  bz init: ", .{});
    const bz_init = try bench.runCommand(allocator, &.{bz_path, "init"}, bz_temp.path);
    try bench.print(allocator, stdout_file, "{d}ms\n", .{bz_init.elapsed_ms});
    const bz_init_ms = bz_init.elapsed_ms;

    try bench.print(allocator, stdout_file, "  br init: ", .{});
    const br_init = try bench.runCommand(allocator, &.{br_path, "init"}, br_temp.path);
    try bench.print(allocator, stdout_file, "{d}ms\n", .{br_init.elapsed_ms});
    const br_init_ms = br_init.elapsed_ms;

    // Step 2: Create 10 beads
    try bench.print(allocator, stdout_file, "[2/4] Creating 10 beads (sequential)...\n", .{});

    try bench.print(allocator, stdout_file, "  bz create x10: ", .{});
    const bz_create_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "q", "TestBead", "--quiet" }, bz_temp.path, 10);
    try bench.print(allocator, stdout_file, "{d}ms (avg: {d}ms per bead)\n", .{ bz_create_ms, @divTrunc(bz_create_ms, 10) });

    try bench.print(allocator, stdout_file, "  br create x10: ", .{});
    const br_create_ms = try bench.runCommandLoop(allocator, &.{ br_path, "q", "TestBead", "--quiet" }, br_temp.path, 10);
    try bench.print(allocator, stdout_file, "{d}ms (avg: {d}ms per bead)\n", .{ br_create_ms, @divTrunc(br_create_ms, 10) });

    // Step 3: List all beads
    try bench.print(allocator, stdout_file, "[3/4] Listing all beads...\n", .{});

    try bench.print(allocator, stdout_file, "  bz list: ", .{});
    const bz_list = try bench.runCommand(allocator, &.{ bz_path, "list", "--all" }, bz_temp.path);
    try bench.print(allocator, stdout_file, "{d}ms\n", .{bz_list.elapsed_ms});
    const bz_list_ms = bz_list.elapsed_ms;

    try bench.print(allocator, stdout_file, "  br list: ", .{});
    const br_list = try bench.runCommand(allocator, &.{ br_path, "list", "--all" }, br_temp.path);
    try bench.print(allocator, stdout_file, "{d}ms\n", .{br_list.elapsed_ms});
    const br_list_ms = br_list.elapsed_ms;

    // Step 4: Cleanup
    try bench.print(allocator, stdout_file, "[4/4] Cleaning up...\n", .{});
    // cleanup happens via defer
    try bench.print(allocator, stdout_file, "  Done\n", .{});

    // Summary
    try bench.print(allocator, stdout_file, "\n", .{});
    try bench.print(allocator, stdout_file, "=== Summary ===\n", .{});
    try bench.print(allocator, stdout_file, "{s: <20} {s: >10} {s: >10}\n", .{ "Operation", "bz (Zig)", "br (Rust)" });
    try bench.print(allocator, stdout_file, "{s: <20} {s: >10} {s: >10}\n", .{ "---------", "--------", "---------" });
    try bench.printCompareRow(allocator, stdout_file, "init", bz_init_ms, br_init_ms);
    try bench.printCompareRow(allocator, stdout_file, "create x10", bz_create_ms, br_create_ms);
    try bench.printCompareRow(allocator, stdout_file, "list", bz_list_ms, br_list_ms);
    try bench.print(allocator, stdout_file, "\n", .{});
    try bench.print(allocator, stdout_file, "Done.\n", .{});
}
