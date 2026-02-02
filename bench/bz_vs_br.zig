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
    try stdout.writeAll("[1/4] Initializing repositories...\n");

    try stdout.writeAll("  bz init: ");
    const bz_init_ms = (try bench.runCommand(allocator, &.{bz_path, "init"}, bz_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{bz_init_ms});

    try stdout.writeAll("  br init: ");
    const br_init_ms = (try bench.runCommand(allocator, &.{br_path, "init"}, br_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{br_init_ms});

    // Step 2: Create 10 beads
    try stdout.writeAll("[2/4] Creating 10 beads (sequential)...\n");

    try stdout.writeAll("  bz create x10: ");
    const bz_create_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "q", "TestBead", "--quiet" }, bz_temp.path, 10);
    try bench.print(allocator, "{d}ms (avg: {d}ms per bead)\n", .{ bz_create_ms, @divTrunc(bz_create_ms, 10) });

    try stdout.writeAll("  br create x10: ");
    const br_create_ms = try bench.runCommandLoop(allocator, &.{ br_path, "q", "TestBead", "--quiet" }, br_temp.path, 10);
    try bench.print(allocator, "{d}ms (avg: {d}ms per bead)\n", .{ br_create_ms, @divTrunc(br_create_ms, 10) });

    // Step 3: List all beads
    try stdout.writeAll("[3/4] Listing all beads...\n");

    try stdout.writeAll("  bz list: ");
    const bz_list_ms = (try bench.runCommand(allocator, &.{ bz_path, "list", "--all" }, bz_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{bz_list_ms});

    try stdout.writeAll("  br list: ");
    const br_list_ms = (try bench.runCommand(allocator, &.{ br_path, "list", "--all" }, br_temp.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{br_list_ms});

    // Step 4: Cleanup
    try stdout.writeAll("[4/4] Cleaning up...\n  Done\n\n");

    // Summary table
    try stdout.writeAll("=== Summary ===\n");
    try bench.print(allocator, "{s: <20} {s: >10} {s: >10}\n", .{ "Operation", "bz (Zig)", "br (Rust)" });
    try bench.print(allocator, "{s: <20} {s: >10} {s: >10}\n", .{ "---------", "--------", "---------" });
    try bench.printCompareRow(allocator, "init", bz_init_ms, br_init_ms);
    try bench.printCompareRow(allocator, "create x10", bz_create_ms, br_create_ms);
    try bench.printCompareRow(allocator, "list", bz_list_ms, br_list_ms);
    try stdout.writeAll("\nDone.\n");
}
