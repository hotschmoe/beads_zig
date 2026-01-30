# Path to Cross-Platform Builds

This document tracks what's needed to enable cross-platform compilation for beads_zig.

**Current Status:** Cross-platform builds are WORKING after running `scripts/setup-vendor.sh`.

---

## Target Platforms

| Platform | Architecture | Status | Notes |
|----------|--------------|--------|-------|
| Linux | x86_64 | WORKING | Native dev machine, system SQLite |
| Linux | aarch64 | WORKING | Requires bundled SQLite |
| macOS | x86_64 | WORKING | Requires bundled SQLite |
| macOS | aarch64 (Apple Silicon) | WORKING | Requires bundled SQLite |
| Windows | x86_64 | WORKING | Requires bundled SQLite |
| WASM | wasm32-wasi | UNTESTED | May need additional work |

---

## Setup for Cross-Platform Builds

### One-time setup

Run the vendor setup script to download SQLite:

```bash
./scripts/setup-vendor.sh
```

This downloads the SQLite amalgamation (~2.7MB zip) and extracts `sqlite3.c` and `sqlite3.h` to `vendor/`.

The script will install `unzip` if not present (supports apt, dnf, pacman).

### Building for other platforms

```bash
# Linux ARM64
zig build -Dbundle-sqlite=true -Dtarget=aarch64-linux

# macOS Intel
zig build -Dbundle-sqlite=true -Dtarget=x86_64-macos

# macOS Apple Silicon
zig build -Dbundle-sqlite=true -Dtarget=aarch64-macos

# Windows
zig build -Dbundle-sqlite=true -Dtarget=x86_64-windows
```

### Running tests with bundled SQLite

```bash
zig build -Dbundle-sqlite=true test
```

---

## Design Decisions

### vendor/ is gitignored

The `vendor/` directory is not committed to git. Reasons:
- Avoids including third-party licensed code in our repository
- SQLite amalgamation is ~250KB of C code
- Easy to download on demand via setup script

Developers must run `scripts/setup-vendor.sh` before cross-platform builds.

### SQLite Compile Flags

The build system configures these optimizations for bundled SQLite:
- `SQLITE_DQS=0` - Disable double-quoted string literals
- `SQLITE_THREADSAFE=2` - Multi-thread mode (single connection per thread)
- `SQLITE_DEFAULT_MEMSTATUS=0` - Disable memory allocation tracking
- `SQLITE_DEFAULT_WAL_SYNCHRONOUS=1` - Normal sync for WAL mode
- `SQLITE_LIKE_DOESNT_MATCH_BLOBS` - Optimization for LIKE operator
- `SQLITE_OMIT_DEPRECATED` - Remove deprecated features
- `SQLITE_OMIT_PROGRESS_CALLBACK` - Remove progress callback
- `SQLITE_OMIT_SHARED_CACHE` - Remove shared cache mode
- `SQLITE_USE_ALLOCA` - Use stack allocation where possible
- `SQLITE_ENABLE_FTS5` - Full-text search
- `SQLITE_ENABLE_JSON1` - JSON functions

---

## Remaining Work

1. [ ] Test WASM target (wasm32-wasi) - may need filesystem shim
2. [ ] Test actual execution on target platforms (not just cross-compilation)
3. [ ] Consider CI/CD pipeline for multi-platform builds
4. [ ] Code signing for macOS distribution (if distributing binaries)

---

## References

- SQLite Download: https://sqlite.org/download.html
- SQLite Compile Options: https://sqlite.org/compile.html
- Zig Cross-Compilation: https://ziglang.org/learn/overview/#cross-compiling
