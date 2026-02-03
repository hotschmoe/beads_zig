# Path to Cross-Platform Builds

This document tracks cross-platform compilation status for beads_zig.

**Current Status:** Cross-platform builds are WORKING. Pure Zig, no external dependencies.

---

## Target Platforms

| Platform | Architecture | Status | Notes |
|----------|--------------|--------|-------|
| Linux | x86_64 | WORKING | Native dev machine |
| Linux | aarch64 | WORKING | Cross-compiles cleanly |
| macOS | x86_64 | WORKING | Cross-compiles cleanly |
| macOS | aarch64 (Apple Silicon) | WORKING | Cross-compiles cleanly |
| Windows | x86_64 | WORKING | Cross-compiles cleanly |
| WASM | wasm32-wasi | UNTESTED | May need additional work |

---

## Building for Other Platforms

No setup required. Pure Zig with no C dependencies.

```bash
# Linux ARM64
zig build -Dtarget=aarch64-linux-gnu

# macOS Intel
zig build -Dtarget=x86_64-macos

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos

# Windows
zig build -Dtarget=x86_64-windows-gnu

# Release build (smallest binary)
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-gnu
```

---

## Binary Sizes

| Build Mode | Size |
|------------|------|
| Debug | ~7 MB |
| ReleaseSmall | ~12 KB |
| ReleaseFast | ~50 KB |

---

## Architecture

beads_zig uses pure Zig storage with no external dependencies:

- **JSONL file I/O** - `std.fs`, `std.json`
- **In-memory indexing** - `std.ArrayList`, `std.StringHashMap`
- **Atomic writes** - temp file + fsync + rename

No SQLite. No C FFI. No libc linking required.

---

## Status

Cross-platform builds are working. The release workflow builds binaries for all major platforms.

### Future Enhancements

1. [ ] WASM target (wasm32-wasi) - may need filesystem shim
2. [ ] Code signing for macOS distribution (if distributing binaries)

---

## References

- Zig Cross-Compilation: https://ziglang.org/learn/overview/#cross-compiling
