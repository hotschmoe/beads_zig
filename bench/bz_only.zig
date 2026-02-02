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

    // Create temp directory
    var temp_dir = try bench.TempDir.create(allocator, "bz_bench");
    defer temp_dir.cleanup();

    try bench.print(allocator, stdout_file, "=== Beads Benchmark: bz (Zig) ===\n", .{});
    try bench.print(allocator, stdout_file, "Directory: {s}\n", .{temp_dir.path});
    try bench.print(allocator, stdout_file, "\n", .{});

    // Step 1: Init
    try bench.print(allocator, stdout_file, "[1/5] Init: ", .{});
    const init_result = try bench.runCommand(allocator, &.{bz_path, "init"}, temp_dir.path);
    try bench.print(allocator, stdout_file, "{d}ms\n", .{init_result.elapsed_ms});
    const init_ms = init_result.elapsed_ms;

    // Step 2: Create 10 beads
    try bench.print(allocator, stdout_file, "[2/5] Create 10 beads: ", .{});
    const create_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "q", "TestBead", "--quiet" }, temp_dir.path, 10);
    try bench.print(allocator, stdout_file, "{d}ms (avg: {d}ms per bead)\n", .{ create_ms, @divTrunc(create_ms, 10) });

    // Step 3: List all
    try bench.print(allocator, stdout_file, "[3/5] List all: ", .{});
    const list_result = try bench.runCommand(allocator, &.{ bz_path, "list", "--all" }, temp_dir.path);
    try bench.print(allocator, stdout_file, "{d}ms\n", .{list_result.elapsed_ms});
    const list_ms = list_result.elapsed_ms;

    // Step 4: Ready 10 beads
    try bench.print(allocator, stdout_file, "[4/5] Ready 10 beads: ", .{});
    const ready_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "ready", "--next", "--quiet" }, temp_dir.path, 10);
    try bench.print(allocator, stdout_file, "{d}ms (avg: {d}ms per bead)\n", .{ ready_ms, @divTrunc(ready_ms, 10) });

    // Step 5: Claim 10 beads
    try bench.print(allocator, stdout_file, "[5/5] Claim 10 beads: ", .{});
    const claim_ms = try bench.runCommandLoop(allocator, &.{ bz_path, "claim", "--quiet" }, temp_dir.path, 10);
    try bench.print(allocator, stdout_file, "{d}ms (avg: {d}ms per bead)\n", .{ claim_ms, @divTrunc(claim_ms, 10) });

    // Cleanup message
    try bench.print(allocator, stdout_file, "\n", .{});
    try bench.print(allocator, stdout_file, "Cleaning up...\n", .{});
    // cleanup happens via defer
    try bench.print(allocator, stdout_file, "Done\n", .{});

    // Summary
    try bench.print(allocator, stdout_file, "\n", .{});
    try bench.print(allocator, stdout_file, "=== Summary ===\n", .{});
    try bench.print(allocator, stdout_file, "{s: <20} {s: >10}\n", .{ "Operation", "Time" });
    try bench.print(allocator, stdout_file, "{s: <20} {s: >10}\n", .{ "---------", "----" });
    try bench.printRow(allocator, stdout_file, "init", init_ms);
    try bench.printRow(allocator, stdout_file, "create x10", create_ms);
    try bench.printRow(allocator, stdout_file, "list", list_ms);
    try bench.printRow(allocator, stdout_file, "ready x10", ready_ms);
    try bench.printRow(allocator, stdout_file, "claim x10", claim_ms);
    try bench.print(allocator, stdout_file, "\n", .{});
}
