//! JSONL import/export synchronization for beads_zig.
//!
//! Handles:
//! - Export (flush): memory -> issues.jsonl
//! - Import: issues.jsonl -> memory
//! - Merge conflict detection
//! - Content hash deduplication
//! - Atomic file writes

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
