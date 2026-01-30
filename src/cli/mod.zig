//! CLI command implementations for beads_zig.
//!
//! This module handles argument parsing and dispatches to the appropriate
//! command handlers (create, list, show, update, close, sync, etc.).
//!
//! All commands support --json output for machine-readable responses.

const std = @import("std");

pub const args = @import("args.zig");
pub const init = @import("init.zig");

pub const ArgParser = args.ArgParser;
pub const ParseResult = args.ParseResult;
pub const ParseError = args.ParseError;
pub const GlobalOptions = args.GlobalOptions;
pub const Command = args.Command;
pub const InitArgs = args.InitArgs;

pub const InitError = init.InitError;
pub const InitResult = init.InitResult;
pub const runInit = init.run;

test {
    std.testing.refAllDecls(@This());
}
