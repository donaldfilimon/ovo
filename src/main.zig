//! ovo - Modern C/C++ Package Manager
//!
//! Entry point for the ovo CLI tool. Dispatches to command handlers
//! based on user input.
//!
//! Usage: ovo <command> [options]
//!
//! Commands:
//!   build     Build the project
//!   run       Build and run the project
//!   test      Run tests
//!   new       Create a new project
//!   init      Initialize project in current directory
//!   add       Add a dependency
//!   remove    Remove a dependency
//!   fetch     Download dependencies
//!   clean     Clean build artifacts
//!   install   Install to system
//!   import    Import from other build systems
//!   export    Export to other formats
//!   info      Show project information
//!   deps      Show dependency tree
//!   fmt       Format source code
//!   lint      Run static analysis
//!

const std = @import("std");
const builtin = @import("builtin");

// CLI command system (imported via module)
const cli = @import("cli");
const commands = cli.commands;

// Neural network library (original ovo functionality)
const ovo = @import("ovo");

/// Application version
pub const version = "0.2.0";

/// Main entry point using Zig 0.16's new Init API
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    // Get command line arguments using the new Zig 0.16 API
    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |arg| {
            allocator.free(arg);
        }
        args_list.deinit(allocator);
    }

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    // Collect all arguments
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, try allocator.dupe(u8, arg));
    }

    const args = args_list.items;

    // Skip program name
    const cmd_args = if (args.len > 1) args[1..] else args[0..0];

    // Dispatch to CLI command system
    return commands.dispatch(allocator, cmd_args);
}

// Tests
test "main module loads" {
    // Basic smoke test
    _ = cli;
    _ = ovo;
}
