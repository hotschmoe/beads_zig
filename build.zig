const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SQLite bundling option
    const bundle_sqlite = b.option(
        bool,
        "bundle-sqlite",
        "Bundle SQLite instead of linking system library",
    ) orelse false;

    // Core library module
    const mod = b.addModule("beads_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
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

    // Link SQLite
    if (bundle_sqlite) {
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
        exe.linkSystemLibrary("sqlite3");
    }
    exe.linkLibC();

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

    // Tests - create fresh modules to avoid sharing C sources with exe
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "beads_zig", .module = mod },
            },
        }),
    });

    // Link SQLite for tests
    if (bundle_sqlite) {
        inline for (.{ mod_tests, exe_tests }) |t| {
            t.addCSourceFile(.{
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
            t.addIncludePath(b.path("vendor"));
        }
    } else {
        mod_tests.linkSystemLibrary("sqlite3");
        exe_tests.linkSystemLibrary("sqlite3");
    }
    mod_tests.linkLibC();
    exe_tests.linkLibC();

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Format step
    const fmt_step = b.step("fmt", "Format source files");
    const fmt = b.addFmt(.{
        .paths = &.{"src"},
    });
    fmt_step.dependOn(&fmt.step);
}
