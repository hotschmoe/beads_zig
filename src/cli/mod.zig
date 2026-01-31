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
pub const list = @import("list.zig");
pub const show = @import("show.zig");
pub const update = @import("update.zig");
pub const close = @import("close.zig");
pub const ready = @import("ready.zig");
pub const dep = @import("dep.zig");

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

pub const ListError = list.ListError;
pub const ListResult = list.ListResult;
pub const runList = list.run;

pub const ShowError = show.ShowError;
pub const ShowResult = show.ShowResult;
pub const runShow = show.run;

pub const UpdateError = update.UpdateError;
pub const UpdateResult = update.UpdateResult;
pub const runUpdate = update.run;

pub const CloseError = close.CloseError;
pub const CloseResult = close.CloseResult;
pub const runClose = close.run;
pub const runReopen = close.runReopen;

pub const ReadyError = ready.ReadyError;
pub const ReadyResult = ready.ReadyResult;
pub const runReady = ready.run;
pub const runBlocked = ready.runBlocked;

pub const DepError = dep.DepError;
pub const DepResult = dep.DepResult;
pub const runDep = dep.run;

test {
    std.testing.refAllDecls(@This());
}
