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

    var temp_dir = try bench.TempDir.create(allocator, "bz_bench");
    defer temp_dir.cleanup();

    try bench.print(allocator, "=== Beads Benchmark: bz (Zig) ===\n", .{});
    try bench.print(allocator, "Directory: {s}\n\n", .{temp_dir.path});

    // Step 1: Init
    try stdout.writeAll("[1/5] Init: ");
    const init_ms = (try bench.runCommand(allocator, &.{bz_path, "init"}, temp_dir.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{init_ms});

    // Step 2: Create 10 beads
    try stdout.writeAll("[2/5] Create 10 beads: ");
    const create_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "q", "TestBead", "--quiet" }, temp_dir.path, 10);
    try bench.print(allocator, "{d}ms (avg: {d}ms per bead)\n", .{ create_ms, @divTrunc(create_ms, 10) });

    // Step 3: List all
    try stdout.writeAll("[3/5] List all: ");
    const list_ms = (try bench.runCommand(allocator, &.{ bz_path, "list", "--all" }, temp_dir.path)).elapsed_ms;
    try bench.print(allocator, "{d}ms\n", .{list_ms});

    // Step 4: Ready 10 beads
    try stdout.writeAll("[4/5] Ready 10 beads: ");
    const ready_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "ready", "--next", "--quiet" }, temp_dir.path, 10);
    try bench.print(allocator, "{d}ms (avg: {d}ms per bead)\n", .{ ready_ms, @divTrunc(ready_ms, 10) });

    // Step 5: Claim 10 beads
    try stdout.writeAll("[5/5] Claim 10 beads: ");
    const claim_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "claim", "--quiet" }, temp_dir.path, 10);
    try bench.print(allocator, "{d}ms (avg: {d}ms per bead)\n", .{ claim_ms, @divTrunc(claim_ms, 10) });

    try stdout.writeAll("\nCleaning up...\nDone\n\n");

    // Summary table
    try stdout.writeAll("=== Summary ===\n");
    try bench.print(allocator, "{s: <20} {s: >10}\n", .{ "Operation", "Time" });
    try bench.print(allocator, "{s: <20} {s: >10}\n", .{ "---------", "----" });
    try bench.printRow(allocator, "init", init_ms);
    try bench.printRow(allocator, "create x10", create_ms);
    try bench.printRow(allocator, "list", list_ms);
    try bench.printRow(allocator, "ready x10", ready_ms);
    try bench.printRow(allocator, "claim x10", claim_ms);
    try stdout.writeAll("\n");
}
