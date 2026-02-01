//! Storage layer for beads_zig.
//!
//! Handles all persistence operations including:
//! - JSONL file I/O (read/write issues)
//! - In-memory issue storage with indexing
//! - Dependency graph management
//! - Dirty tracking for sync
//! - Write-Ahead Log (WAL) for concurrent writes
//! - WAL compaction for merging WAL into main file

const std = @import("std");

pub const jsonl = @import("jsonl.zig");
pub const store = @import("store.zig");
pub const graph = @import("graph.zig");
pub const issues = @import("issues.zig");
pub const dependencies = @import("dependencies.zig");
pub const lock = @import("lock.zig");
pub const wal = @import("wal.zig");
pub const compact = @import("compact.zig");

pub const JsonlFile = jsonl.JsonlFile;
pub const JsonlError = jsonl.JsonlError;

pub const IssueStore = store.IssueStore;
pub const IssueStoreError = store.IssueStoreError;

pub const DependencyGraph = graph.DependencyGraph;
pub const DependencyGraphError = graph.DependencyGraphError;

pub const DependencyStore = dependencies.DependencyStore;
pub const DependencyStoreError = dependencies.DependencyStoreError;

pub const BeadsLock = lock.BeadsLock;
pub const LockError = lock.LockError;
pub const withLock = lock.withLock;
pub const withLockContext = lock.withLockContext;

pub const Wal = wal.Wal;
pub const WalEntry = wal.WalEntry;
pub const WalOp = wal.WalOp;
pub const WalError = wal.WalError;

pub const Compactor = compact.Compactor;
pub const CompactError = compact.CompactError;
pub const WalStats = compact.WalStats;
pub const CompactionThresholds = compact.CompactionThresholds;

test {
    std.testing.refAllDecls(@This());
}
