# Postmortem: Zig Build Test Hang

**Date**: 2026-01-31
**Severity**: Medium (CI/CD blocker)
**Status**: Resolved

## Summary

`zig build test` would hang indefinitely after all tests passed, requiring manual termination. This blocked CI/CD pipelines from completing normally.

## Timeline

- Tests would run to completion (all 375 passing)
- Process would hang instead of exiting
- Required `timeout` wrapper or manual `pkill` to terminate
- Direct `zig test src/root.zig` worked, but failed after adding `toon_zig` dependency (module not available without build system)

## Root Cause

The Zig 0.15.x build system uses an IPC (Inter-Process Communication) protocol for test execution. When `b.addRunArtifact()` is called on a test binary, it internally calls `enableTestRunnerMode()` which:

1. Sets `stdio = .zig_test` (IPC mode)
2. Adds `--listen=-` flag to the test binary arguments
3. Establishes stdin/stdout pipe communication between build runner and test runner

The IPC protocol enables features like parallel test execution and progress reporting. However, **after all tests complete, the build system fails to properly close the IPC connection**, causing the parent process to wait indefinitely for EOF on the pipe.

### Process Tree During Hang

```
zig(parent)
  └── build(runner)
        └── test(binary) --listen=-
```

The `test` binary completes and exits, but `build` never detects this and continues waiting.

### Why Direct `zig test` Worked

Running `zig test src/root.zig` bypasses the build system entirely - no IPC protocol, no `--listen=-` flag. The test binary runs directly with inherited stdio and exits normally.

### Why `toon_zig` Masked the Issue

Before adding `toon_zig`, developers could use `zig test src/root.zig` as a workaround. After adding `toon_zig` as an external dependency, direct `zig test` fails because the module is only available through the build system. This forced reliance on `zig build test`, exposing the pre-existing hang.

## Solution

Instead of using `b.addRunArtifact()` which automatically enables IPC mode, we manually create the Run step with inherited stdio:

```zig
// BEFORE (causes hang):
const run_mod_tests = b.addRunArtifact(mod_tests);

// AFTER (works correctly):
const run_mod_tests = std.Build.Step.Run.create(b, "run test");
run_mod_tests.addArtifactArg(mod_tests);
run_mod_tests.stdio = .inherit;
```

This bypasses the IPC protocol entirely. The test binary runs with terminal-inherited stdio, outputs directly to stdout, and exits cleanly.

## Technical Details

### Zig Build System Internals

In `/opt/zig/lib/std/Build.zig` line 960-961:

```zig
const test_server_mode = if (exe.test_runner) |r| r.mode == .server else true;
if (test_server_mode) run_step.enableTestRunnerMode();
```

When `test_runner` is null (default), server mode is assumed. `enableTestRunnerMode()` in `Step/Run.zig` line 209-216:

```zig
pub fn enableTestRunnerMode(run: *Run) void {
    const b = run.step.owner;
    run.stdio = .zig_test;
    run.addPrefixedDirectoryArg("--cache-dir=", ...);
    run.addArgs(&.{
        b.fmt("--seed=0x{x}", .{b.graph.random_seed}),
        "--listen=-",  // <-- This enables IPC protocol
    });
}
```

### StdIo Union Options

```zig
pub const StdIo = union(enum) {
    infer_from_args,  // Default, infers from arguments
    inherit,          // Inherited stdio (what we use)
    check: ...,       // For output validation
    zig_test,         // IPC protocol (causes hang)
};
```

## Files Changed

1. **build.zig** - Manual Run step creation
2. **CLAUDE.md** - Updated testing documentation

## Verification

```bash
$ zig build test
1/375 root.test_0...OK
...
375/375 id.hash.test.contentHash with custom issue_type...OK
All 375 tests passed.
$ echo $?
0
```

## Lessons Learned

1. **External dependencies can expose latent bugs** - The `toon_zig` dependency didn't cause the hang, but it removed the workaround that masked it.

2. **Build system abstractions have trade-offs** - `addRunArtifact()` is convenient but makes assumptions (IPC mode for tests) that may not be appropriate.

3. **Zig's IPC protocol is powerful but fragile** - It enables parallel test execution and progress reporting, but edge cases in protocol termination can cause hangs.

## References

- [Zig Issue #18111](https://github.com/ziglang/zig/issues/18111) - Test hangs if stdout included
- [Zig Issue #20016](https://github.com/ziglang/zig/issues/20016) - Test hangs on panic
- [Zig Issue #21984](https://github.com/ziglang/zig/issues/21984) - bw.flush() causes hang
- [Zig Build/Step/Run.zig](https://github.com/ziglang/zig/blob/master/lib/std/Build/Step/Run.zig) - StdIo implementation
