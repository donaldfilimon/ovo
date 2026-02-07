//! ovo doc command
//!
//! Generate documentation for the project.
//! Usage: ovo doc

const std = @import("std");
const commands = @import("commands.zig");
const manifest = @import("manifest.zig");

const Context = commands.Context;
const TermWriter = commands.TermWriter;

/// Print help for doc command
fn printHelp(writer: *TermWriter) !void {
    try writer.bold("ovo doc", .{});
    try writer.print(" - Generate documentation\n\n", .{});

    try writer.bold("USAGE:\n", .{});
    try writer.print("    ovo doc [options]\n\n", .{});

    try writer.bold("OPTIONS:\n", .{});
    try writer.print("    --open            Open documentation in browser after generation\n", .{});
    try writer.print("    -o, --output <dir> Output directory (default: docs/)\n", .{});
    try writer.print("    --format <fmt>     Format: doxygen, clang-doc (default: auto)\n", .{});
    try writer.print("    -h, --help         Show this help message\n", .{});

    try writer.print("\n", .{});
    try writer.bold("EXAMPLES:\n", .{});
    try writer.dim("    ovo doc                 # Generate docs to docs/\n", .{});
    try writer.dim("    ovo doc --open           # Generate and open in browser\n", .{});
    try writer.dim("    ovo doc -o html/         # Output to html/\n", .{});
}

/// Execute the doc command
pub fn execute(ctx: *Context, args: []const []const u8) !u8 {
    if (commands.hasHelpFlag(args)) {
        try printHelp(ctx.stdout);
        return 0;
    }

    const manifest_exists = blk: {
        ctx.cwd.access(manifest.manifest_filename, .{}) catch break :blk false;
        break :blk true;
    };

    if (!manifest_exists) {
        try ctx.stderr.err("error: ", .{});
        try ctx.stderr.print("no {s} found in current directory\n", .{manifest.manifest_filename});
        return 1;
    }

    try ctx.stdout.bold("Documentation", .{});
    try ctx.stdout.print(" generation: coming soon\n", .{});
    try ctx.stdout.dim("  Run doxygen or clang-doc manually for now.\n", .{});
    return 0;
}
