//! Command-line interface for the ovo package manager.
//!
//! Provides commands for building, running, testing, package management,
//! and project translation.
//!
//! ## Available Commands
//!
//! **Build Commands:**
//! - `build` - Build the project
//! - `run` - Build and run the project
//! - `test` - Run tests
//! - `clean` - Clean build artifacts
//! - `install` - Install to system
//!
//! **Project Commands:**
//! - `new` - Create a new project
//! - `init` - Initialize in current directory
//! - `info` - Show project information
//!
//! **Dependency Commands:**
//! - `add` - Add a dependency
//! - `remove` - Remove a dependency
//! - `fetch` - Download dependencies
//! - `deps` - Show dependency tree
//!
//! **Translation Commands:**
//! - `import` - Import from other build systems
//! - `export` - Export to other formats
//!
//! **Code Quality Commands:**
//! - `fmt` - Format source code
//! - `lint` - Run static analysis
//!
//! ## Usage
//! ```zig
//! const cli = @import("cli");
//! const exit_code = cli.dispatch(allocator, args);
//! ```

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Command Dispatcher (primary entry point)
// ═══════════════════════════════════════════════════════════════════════════

pub const commands = @import("commands.zig");

/// Parse and dispatch CLI commands. Returns exit code (0 = success).
pub const dispatch = commands.dispatch;

/// Context passed to all command handlers.
pub const Context = commands.Context;

/// Command execution errors.
pub const CommandError = commands.CommandError;

/// Metadata about available commands.
pub const CommandDescriptor = commands.CommandDescriptor;

/// List of all registered commands.
pub const command_list = commands.command_list;

// Helper functions for command implementations
pub const printHelp = commands.printHelp;
pub const printVersion = commands.printVersion;
pub const hasHelpFlag = commands.hasHelpFlag;
pub const hasVerboseFlag = commands.hasVerboseFlag;

// ═══════════════════════════════════════════════════════════════════════════
// Individual Command Modules
// ═══════════════════════════════════════════════════════════════════════════
// These are exposed for direct access if needed, but most consumers should
// use `dispatch()` which routes to the appropriate command automatically.

/// Manifest file (build.zon) handling.
pub const manifest = @import("manifest.zig");

// Build commands
pub const build_cmd = @import("build_cmd.zig");
pub const run_cmd = @import("run_cmd.zig");
pub const test_cmd = @import("test_cmd.zig");
pub const clean_cmd = @import("clean_cmd.zig");
pub const install_cmd = @import("install_cmd.zig");

// Project commands
pub const new_cmd = @import("new_cmd.zig");
pub const init_cmd = @import("init_cmd.zig");
pub const info_cmd = @import("info_cmd.zig");

// Dependency commands
pub const add_cmd = @import("add_cmd.zig");
pub const remove_cmd = @import("remove_cmd.zig");
pub const fetch_cmd = @import("fetch_cmd.zig");
pub const deps_cmd = @import("deps_cmd.zig");

// Translation commands
pub const import_cmd = @import("import_cmd.zig");
pub const export_cmd = @import("export_cmd.zig");

// Code quality commands
pub const fmt_cmd = @import("fmt_cmd.zig");
pub const lint_cmd = @import("lint_cmd.zig");

// ═══════════════════════════════════════════════════════════════════════════
// Internal Types (exposed for command implementations)
// ═══════════════════════════════════════════════════════════════════════════
// Note: For rich terminal output (colors, progress bars, spinners),
// prefer using `util.terminal` directly for new code.

pub const Color = commands.Color;
pub const TermWriter = commands.TermWriter;
pub const ProgressBar = commands.ProgressBar;
pub const DirHandle = commands.DirHandle;

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test {
    std.testing.refAllDecls(@This());
}

test "command list is populated" {
    try std.testing.expect(command_list.len > 0);
}

test "dispatch handles empty args" {
    // Empty args should show help and return 0
    const exit_code = dispatch(std.testing.allocator, &[_][]const u8{}) catch 1;
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}
