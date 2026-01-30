//! CLI command implementations for beads_zig.
//!
//! This module handles argument parsing and dispatches to the appropriate
//! command handlers (create, list, show, update, close, sync, etc.).
//!
//! All commands support --json output for machine-readable responses.

const std = @import("std");

pub const args = @import("args.zig");
pub const init = @import("init.zig");
pub const create = @import("create.zig");

pub const ArgParser = args.ArgParser;
pub const ParseResult = args.ParseResult;
pub const ParseError = args.ParseError;
pub const GlobalOptions = args.GlobalOptions;
pub const Command = args.Command;
pub const InitArgs = args.InitArgs;
pub const CreateArgs = args.CreateArgs;
pub const QuickArgs = args.QuickArgs;

pub const InitError = init.InitError;
pub const InitResult = init.InitResult;
pub const runInit = init.run;

pub const CreateError = create.CreateError;
pub const CreateResult = create.CreateResult;
pub const runCreate = create.run;
pub const runQuick = create.runQuick;

test {
    std.testing.refAllDecls(@This());
}
