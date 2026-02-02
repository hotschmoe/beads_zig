const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // External dependencies
    const toon_zig = b.dependency("toon_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // Core library module
    const mod = b.addModule("beads_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "toon_zig", .module = toon_zig.module("toon_zig") },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "bz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "beads_zig", .module = mod },
            },
        }),
    });

    // Strip in release builds
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run bz");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Tests - run root.zig which uses refAllDecls to test all modules
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toon_zig", .module = toon_zig.module("toon_zig") },
            },
        }),
    });

    // Create run step manually to avoid IPC protocol hang (zig 0.15.x bug)
    // See: https://github.com/ziglang/zig/issues/18111
    const run_mod_tests = std.Build.Step.Run.create(b, "run test");
    run_mod_tests.addArtifactArg(mod_tests);
    run_mod_tests.stdio = .inherit;

    const test_step = b.step("test", "Run tests");
    // CLI tests require the binary to be built first
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_mod_tests.step);

    // Format step
    const fmt_step = b.step("fmt", "Format source files");
    const fmt = b.addFmt(.{
        .paths = &.{"src"},
    });
    fmt_step.dependOn(&fmt.step);

    // Benchmark: bz-only workflow
    const bench_bz = b.addExecutable(.{
        .name = "bz-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bz_only.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(bench_bz);

    const bench_step = b.step("bench", "Run bz workflow benchmark");
    const bench_run = b.addRunArtifact(bench_bz);
    bench_run.step.dependOn(b.getInstallStep());
    bench_step.dependOn(&bench_run.step);

    // Benchmark: bz vs br comparison
    const bench_compare = b.addExecutable(.{
        .name = "bz-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bz_vs_br.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(bench_compare);

    const bench_compare_step = b.step("bench-compare", "Run bz vs br comparison benchmark");
    const bench_compare_run = b.addRunArtifact(bench_compare);
    bench_compare_run.step.dependOn(b.getInstallStep());
    bench_compare_step.dependOn(&bench_compare_run.step);
}
