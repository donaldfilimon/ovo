//! Compile Database Exporter - -> compile_commands.json
//!
//! Generates compile_commands.json for IDE/LSP integration:
//! - clangd, ccls, and other language servers
//! - IDE code completion and navigation
//! - Static analysis tools
//!
//! Format: JSON array of compilation commands per source file

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Target = engine.Target;
const TargetKind = engine.TargetKind;
const TranslationOptions = engine.TranslationOptions;

/// Compilation database entry
const CompileCommand = struct {
    /// Working directory for the compilation
    directory: []const u8,
    /// Source file being compiled
    file: []const u8,
    /// Full compilation command
    command: ?[]const u8 = null,
    /// Command as argument array (preferred over command)
    arguments: ?[]const []const u8 = null,
    /// Output file (optional)
    output: ?[]const u8 = null,
};

/// Generate compile_commands.json from Project
pub fn generate(allocator: Allocator, project: *const Project, output_path: []const u8, options: TranslationOptions) !void {
    _ = options;

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var writer = file.writer();

    // Collect all compile commands
    var commands = std.ArrayList(CompileCommand).init(allocator);
    defer {
        for (commands.items) |cmd| {
            if (cmd.arguments) |args| {
                allocator.free(args);
            }
            if (cmd.command) |c| {
                allocator.free(c);
            }
        }
        commands.deinit();
    }

    // Generate commands for each target's sources
    for (project.targets.items) |target| {
        for (target.sources.items) |src| {
            const cmd = try generateCommand(allocator, &target, src, project.source_root);
            try commands.append(cmd);
        }
    }

    // Write JSON
    try writer.writeAll("[\n");

    for (commands.items, 0..) |cmd, idx| {
        try writer.writeAll("  {\n");
        try writer.print("    \"directory\": \"{s}\",\n", .{escapeJson(cmd.directory)});
        try writer.print("    \"file\": \"{s}\"", .{escapeJson(cmd.file)});

        if (cmd.arguments) |args| {
            try writer.writeAll(",\n    \"arguments\": [\n");
            for (args, 0..) |arg, arg_idx| {
                try writer.print("      \"{s}\"", .{escapeJson(arg)});
                if (arg_idx < args.len - 1) {
                    try writer.writeAll(",");
                }
                try writer.writeAll("\n");
            }
            try writer.writeAll("    ]");
        } else if (cmd.command) |command| {
            try writer.print(",\n    \"command\": \"{s}\"", .{escapeJson(command)});
        }

        if (cmd.output) |output| {
            try writer.print(",\n    \"output\": \"{s}\"", .{escapeJson(output)});
        }

        try writer.writeAll("\n  }");

        if (idx < commands.items.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("]\n");
}

fn generateCommand(allocator: Allocator, target: *const Target, source: []const u8, project_root: []const u8) !CompileCommand {
    // Build arguments array
    var args = std.ArrayList([]const u8).init(allocator);
    errdefer args.deinit();

    // Compiler
    const compiler: []const u8 = if (isCppSource(source)) "c++" else "cc";
    try args.append(compiler);

    // Language standard
    if (isCppSource(source)) {
        try args.append("-std=c++17");
    } else {
        try args.append("-std=c11");
    }

    // Warning flags (common set)
    try args.append("-Wall");
    try args.append("-Wextra");

    // Defines
    for (target.flags.defines.items) |def| {
        const arg = try std.fmt.allocPrint(allocator, "-D{s}", .{def});
        try args.append(arg);
    }

    // Include paths
    for (target.flags.include_paths.items) |inc| {
        try args.append("-I");
        try args.append(inc);
    }

    // System include paths
    for (target.flags.system_include_paths.items) |inc| {
        try args.append("-isystem");
        try args.append(inc);
    }

    // Additional compile flags
    for (target.flags.compile_flags.items) |flag| {
        try args.append(flag);
    }

    // Compile only
    try args.append("-c");

    // Source file
    try args.append(source);

    // Output (derive from source)
    const basename = std.fs.path.basename(source);
    const stem = std.fs.path.stem(basename);
    const output = try std.fmt.allocPrint(allocator, "{s}.o", .{stem});
    try args.append("-o");
    try args.append(output);

    return CompileCommand{
        .directory = project_root,
        .file = source,
        .arguments = try args.toOwnedSlice(),
        .output = output,
    };
}

fn isCppSource(path: []const u8) bool {
    const cpp_extensions = [_][]const u8{ ".cpp", ".cc", ".cxx", ".c++", ".C", ".mm" };
    for (cpp_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

fn escapeJson(s: []const u8) []const u8 {
    // Simple escape - in production would handle all special chars
    // For now, just return as-is since paths shouldn't have special chars
    return s;
}

/// Merge multiple compile_commands.json files
pub fn merge(allocator: Allocator, input_paths: []const []const u8, output_path: []const u8) !void {
    var all_entries = std.ArrayList(std.json.Value).init(allocator);
    defer all_entries.deinit();

    // Read and parse each input file
    for (input_paths) |path| {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value == .array) {
            for (parsed.value.array.items) |item| {
                try all_entries.append(item);
            }
        }
    }

    // Write merged output
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();

    var writer = out_file.writer();
    try writer.writeAll("[\n");

    for (all_entries.items, 0..) |entry, idx| {
        if (entry == .object) {
            try writeJsonObject(&writer, entry.object);
        }

        if (idx < all_entries.items.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("]\n");
}

fn writeJsonObject(writer: anytype, obj: std.json.ObjectMap) !void {
    try writer.writeAll("  {\n");

    var iter = obj.iterator();
    var first = true;

    while (iter.next()) |entry| {
        if (!first) {
            try writer.writeAll(",\n");
        }
        first = false;

        try writer.print("    \"{s}\": ", .{entry.key_ptr.*});

        switch (entry.value_ptr.*) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .array => |arr| {
                try writer.writeAll("[\n");
                for (arr.items, 0..) |item, i| {
                    if (item == .string) {
                        try writer.print("      \"{s}\"", .{item.string});
                    }
                    if (i < arr.items.len - 1) {
                        try writer.writeAll(",");
                    }
                    try writer.writeAll("\n");
                }
                try writer.writeAll("    ]");
            },
            else => try writer.writeAll("null"),
        }
    }

    try writer.writeAll("\n  }");
}

/// Update compile_commands.json with additional flags (e.g., from .clangd)
pub fn augment(allocator: Allocator, db_path: []const u8, additional_flags: []const []const u8) !void {
    const file = try std.fs.cwd().openFile(db_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return;

    // Rewrite with augmented flags
    const out_file = try std.fs.cwd().createFile(db_path, .{});
    defer out_file.close();

    var writer = out_file.writer();
    try writer.writeAll("[\n");

    for (parsed.value.array.items, 0..) |entry, idx| {
        if (entry != .object) continue;

        try writer.writeAll("  {\n");

        var obj_iter = entry.object.iterator();
        var first = true;

        while (obj_iter.next()) |kv| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            try writer.print("    \"{s}\": ", .{kv.key_ptr.*});

            if (std.mem.eql(u8, kv.key_ptr.*, "arguments") and kv.value_ptr.* == .array) {
                // Augment arguments
                try writer.writeAll("[\n");

                for (kv.value_ptr.array.items, 0..) |arg, i| {
                    if (arg == .string) {
                        try writer.print("      \"{s}\"", .{arg.string});
                    }
                    if (i < kv.value_ptr.array.items.len - 1 or additional_flags.len > 0) {
                        try writer.writeAll(",");
                    }
                    try writer.writeAll("\n");
                }

                // Add additional flags
                for (additional_flags, 0..) |flag, i| {
                    try writer.print("      \"{s}\"", .{flag});
                    if (i < additional_flags.len - 1) {
                        try writer.writeAll(",");
                    }
                    try writer.writeAll("\n");
                }

                try writer.writeAll("    ]");
            } else {
                // Copy as-is
                switch (kv.value_ptr.*) {
                    .string => |s| try writer.print("\"{s}\"", .{s}),
                    else => try writer.writeAll("null"),
                }
            }
        }

        try writer.writeAll("\n  }");
        if (idx < parsed.value.array.items.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("]\n");
}

// Tests
test "isCppSource" {
    try std.testing.expect(!isCppSource("main.c"));
    try std.testing.expect(isCppSource("main.cpp"));
    try std.testing.expect(isCppSource("main.cc"));
    try std.testing.expect(isCppSource("main.cxx"));
    try std.testing.expect(isCppSource("main.mm"));
}

test "generateCommand" {
    const allocator = std.testing.allocator;

    var target = Target.init(allocator, "test", .executable);
    defer target.deinit();

    try target.flags.defines.append("DEBUG");
    try target.flags.include_paths.append("/usr/include");

    const cmd = try generateCommand(allocator, &target, "/project/main.cpp", "/project");

    // Verify some expected arguments
    try std.testing.expect(cmd.arguments != null);
    const args = cmd.arguments.?;

    var has_compiler = false;
    var has_std = false;
    var has_define = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "c++")) has_compiler = true;
        if (std.mem.eql(u8, arg, "-std=c++17")) has_std = true;
        if (std.mem.eql(u8, arg, "-DDEBUG")) has_define = true;
    }

    try std.testing.expect(has_compiler);
    try std.testing.expect(has_std);
    try std.testing.expect(has_define);

    // Clean up allocated strings
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-D") and arg.len > 2) {
            allocator.free(arg);
        }
    }
    if (cmd.output) |o| allocator.free(o);
    allocator.free(args);
}
