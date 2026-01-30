# Sandbox Directory

This directory is for manual testing of beads_zig (`bz`).

## Purpose

The project root may contain a `.beads/` directory for tracking development
with beads_rust. Running `bz` in the project root during development could
interfere with that data. This sandbox provides an isolated environment.

## Usage

```bash
# From project root
cd sandbox
../zig-out/bin/bz init
../zig-out/bin/bz create "Test issue"
../zig-out/bin/bz list

# Or use the build step (once implemented)
zig build run-sandbox -- init
zig build run-sandbox -- create "Test issue"
```

## Contents

Everything in this directory except `.gitkeep` and `README.md` is gitignored.
Feel free to:

- Run `bz init` to create a test `.beads/` directory
- Create, modify, and delete test issues
- Experiment with sync, import/export
- Break things without consequence

## Cleanup

To reset the sandbox:

```bash
rm -rf .beads/
```

Or delete everything except the structural files:

```bash
find . -mindepth 1 ! -name '.gitkeep' ! -name 'README.md' -exec rm -rf {} +
```
