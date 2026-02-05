//! Command-line interface for the ovo package manager.
//!
//! Provides commands for building, running, testing, package management,
//! and project translation.

pub const commands = @import("commands.zig");
pub const build_cmd = @import("build_cmd.zig");
pub const run_cmd = @import("run_cmd.zig");
pub const test_cmd = @import("test_cmd.zig");
pub const new_cmd = @import("new_cmd.zig");
pub const init_cmd = @import("init_cmd.zig");
pub const add_cmd = @import("add_cmd.zig");
pub const remove_cmd = @import("remove_cmd.zig");
pub const fetch_cmd = @import("fetch_cmd.zig");
pub const clean_cmd = @import("clean_cmd.zig");

// Re-export the main command dispatcher
pub const CommandDispatcher = commands.CommandDispatcher;
pub const Command = commands.Command;
pub const runCommand = commands.runCommand;

test {
    @import("std").testing.refAllDecls(@This());
}
