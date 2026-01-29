const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "bz",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link SQLite - can use system library or bundled
    if (b.option(bool, "bundle-sqlite", "Bundle SQLite instead of linking system library") orelse false) {
        // Bundled SQLite
        exe.addCSourceFile(.{
            .file = b.path("vendor/sqlite3.c"),
            .flags = &.{
                "-DSQLITE_DQS=0",
                "-DSQLITE_THREADSAFE=2",
                "-DSQLITE_DEFAULT_MEMSTATUS=0",
                "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
                "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
                "-DSQLITE_OMIT_DEPRECATED",
                "-DSQLITE_OMIT_PROGRESS_CALLBACK",
                "-DSQLITE_OMIT_SHARED_CACHE",
                "-DSQLITE_USE_ALLOCA",
                "-DSQLITE_ENABLE_FTS5",
                "-DSQLITE_ENABLE_JSON1",
            },
        });
        exe.addIncludePath(b.path("vendor"));
    } else {
        // System SQLite
        exe.linkSystemLibrary("sqlite3");
    }

    exe.linkLibC();

    // Strip in release builds for smaller binary
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run bz");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link SQLite for tests too
    if (b.option(bool, "bundle-sqlite", "Bundle SQLite instead of linking system library") orelse false) {
        unit_tests.addCSourceFile(.{
            .file = b.path("vendor/sqlite3.c"),
            .flags = &.{"-DSQLITE_ENABLE_FTS5"},
        });
        unit_tests.addIncludePath(b.path("vendor"));
    } else {
        unit_tests.linkSystemLibrary("sqlite3");
    }
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Format check
    const fmt_step = b.step("fmt", "Format source files");
    const fmt = b.addFmt(.{
        .paths = &.{"src"},
    });
    fmt_step.dependOn(&fmt.step);
}
