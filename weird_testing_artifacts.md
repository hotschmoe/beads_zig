# Weird Testing Artifacts - beads_zig

## Problem Summary

`zig test src/root.zig` passes all 343 tests consistently, but `zig build test` hangs indefinitely or crashes.

## Environment

- Zig version: `/opt/zig/zig` (appears to be 0.14.x based on API)
- Platform: Linux 6.8.0-90-generic
- Date: 2026-01-30

## Symptoms

### Working: Direct zig test
```bash
$ timeout 120 zig test src/root.zig
# ... runs 343 tests ...
All 343 tests passed.
```

### Failing: zig build test
```bash
$ timeout 90 zig build test
# Hangs indefinitely, no output, eventually times out or crashes
```

### Crash output (with minimal build.zig):
```
/opt/zig/lib/std/start.zig:627:37: 0x11bbc69 in posixCallMainAndExit (std.zig)
            const result = root.main() catch |err| {
                                    ^
/opt/zig/lib/std/start.zig:232:5: 0x119a351 in _start (std.zig)
    asm volatile (switch (native_arch) {
    ^
???:?:?: 0x0 in ??? (???)
error: the following build command crashed:
.zig-cache/o/.../build /opt/zig/zig ... test
```

## Investigation Timeline

1. **Initial hypothesis**: tmpDir deadlock in output/mod.zig tests
   - Removed all 9 tmpDir-based tests, replaced with direct unit tests
   - Result: `zig test src/root.zig` still works, `zig build test` still hangs

2. **Second hypothesis**: exe_tests duplicating mod_tests
   - Removed exe_tests from build.zig (it imports beads_zig which runs refAllDecls again)
   - Result: Still hangs

3. **Third hypothesis**: Build system caching
   - Cleared `.zig-cache` and `zig-out`
   - Result: Still hangs/crashes

4. **Minimal reproduction**: Created minimal build.zig with just mod_tests
   - Result: Crashes with stack trace above

## Key Observations

1. **Direct zig test works perfectly** - 343 tests, consistent passes
2. **zig build (no test) works** - Compiles bz binary successfully
3. **zig build test hangs/crashes** - Even with minimal build.zig
4. **No tmpDir usage remaining** - All file-based tests removed
5. **Tests are deterministic** - Multiple runs of `zig test src/root.zig` all pass

## Current build.zig (simplified)

```zig
// Tests - run root.zig which uses refAllDecls to test all modules
const mod_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }),
});

const run_mod_tests = b.addRunArtifact(mod_tests);

const test_step = b.step("test", "Run tests");
test_step.dependOn(&run_mod_tests.step);
```

## Workaround

Use direct zig test instead of build system:
```bash
timeout 120 zig test src/root.zig 2>&1
```

## Fixes Applied (unrelated to build hang)

### 1. Flaky ID Test (src/id/generator.zig)
- Used deterministic seed and longer hash length
- Test now stable

### 2. Memory Leak (src/cli/args.zig, src/main.zig)
- Added `ParseResult.deinit()` method
- Called via defer in main.zig

### 3. tmpDir Tests (src/output/mod.zig)
- Replaced 9 file-based tests with direct unit tests
- No more tmpDir usage in codebase

## Possible Causes

1. **Zig version bug** - Build system test runner may have issues in this version
2. **refAllDecls + build system interaction** - Something about how build.zig compiles tests differs from direct `zig test`
3. **Resource limits** - Build system may be hitting some system limit
4. **Parallel compilation issue** - Even with `-j1`, build system may have internal parallelism issues
