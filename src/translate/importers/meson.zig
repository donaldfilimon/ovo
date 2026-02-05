//! Meson Importer - meson.build -> build.zon
//!
//! Parses Meson build files and extracts:
//! - project() declaration
//! - executable(), library(), shared_library(), static_library() targets
//! - dependency() calls
//! - include_directories(), subdir() calls

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../engine.zig");
const Project = engine.Project;
const Target = engine.Target;
const TargetKind = engine.TargetKind;
const Dependency = engine.Dependency;
const TranslationWarning = engine.TranslationWarning;
const WarningSeverity = engine.WarningSeverity;
const TranslationOptions = engine.TranslationOptions;

/// Meson token types
const TokenType = enum {
    identifier,
    string,
    number,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    colon,
    equals,
    plus,
    minus,
    dot,
    newline,
    eof,
};

const Token = struct {
    kind: TokenType,
    text: []const u8,
    line: usize,
};

/// Meson value types
const MesonValue = union(enum) {
    string: []const u8,
    number: i64,
    boolean: bool,
    array: []const MesonValue,
    dict: std.StringHashMap(MesonValue),
    identifier: []const u8,
    call: struct {
        name: []const u8,
        args: []const MesonValue,
        kwargs: std.StringHashMap(MesonValue),
    },
    method_call: struct {
        object: *const MesonValue,
        method: []const u8,
        args: []const MesonValue,
    },
};

/// Lexer state
const Lexer = struct {
    allocator: Allocator,
    content: []const u8,
    pos: usize = 0,
    line: usize = 1,

    fn init(allocator: Allocator, content: []const u8) Lexer {
        return .{
            .allocator = allocator,
            .content = content,
        };
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.content.len) return null;
        return self.content[self.pos];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.content.len) return null;
        const c = self.content[self.pos];
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    fn skipWhitespaceExceptNewline(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                _ = self.advance();
            } else if (c == '#') {
                // Comment - skip to end of line
                while (self.peek()) |cc| {
                    if (cc == '\n') break;
                    _ = self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn nextToken(self: *Lexer) Token {
        self.skipWhitespaceExceptNewline();

        const c = self.peek() orelse return .{ .kind = .eof, .text = "", .line = self.line };

        // Single character tokens
        const single_tokens = .{
            .{ '(', TokenType.lparen },
            .{ ')', TokenType.rparen },
            .{ '[', TokenType.lbracket },
            .{ ']', TokenType.rbracket },
            .{ '{', TokenType.lbrace },
            .{ '}', TokenType.rbrace },
            .{ ',', TokenType.comma },
            .{ ':', TokenType.colon },
            .{ '=', TokenType.equals },
            .{ '+', TokenType.plus },
            .{ '-', TokenType.minus },
            .{ '.', TokenType.dot },
            .{ '\n', TokenType.newline },
        };

        inline for (single_tokens) |pair| {
            if (c == pair[0]) {
                const start = self.pos;
                _ = self.advance();
                return .{ .kind = pair[1], .text = self.content[start..self.pos], .line = self.line };
            }
        }

        // String literals
        if (c == '\'' or c == '"') {
            return self.readString(c);
        }

        // Multi-line string (triple quotes)
        if (c == '\'' and self.pos + 2 < self.content.len and
            self.content[self.pos + 1] == '\'' and self.content[self.pos + 2] == '\'')
        {
            return self.readMultilineString();
        }

        // Numbers
        if (std.ascii.isDigit(c)) {
            return self.readNumber();
        }

        // Identifiers
        if (std.ascii.isAlphabetic(c) or c == '_') {
            return self.readIdentifier();
        }

        // Unknown - skip
        _ = self.advance();
        return self.nextToken();
    }

    fn readString(self: *Lexer, quote: u8) Token {
        const line = self.line;
        _ = self.advance(); // opening quote
        const start = self.pos;

        while (self.peek()) |c| {
            if (c == quote) {
                const text = self.content[start..self.pos];
                _ = self.advance();
                return .{ .kind = .string, .text = text, .line = line };
            }
            if (c == '\\' and self.pos + 1 < self.content.len) {
                _ = self.advance();
            }
            _ = self.advance();
        }

        return .{ .kind = .string, .text = self.content[start..self.pos], .line = line };
    }

    fn readMultilineString(self: *Lexer) Token {
        const line = self.line;
        self.pos += 3; // opening '''
        const start = self.pos;

        while (self.pos + 2 < self.content.len) {
            if (self.content[self.pos] == '\'' and
                self.content[self.pos + 1] == '\'' and
                self.content[self.pos + 2] == '\'')
            {
                const text = self.content[start..self.pos];
                self.pos += 3;
                return .{ .kind = .string, .text = text, .line = line };
            }
            if (self.content[self.pos] == '\n') self.line += 1;
            self.pos += 1;
        }

        return .{ .kind = .string, .text = self.content[start..self.pos], .line = line };
    }

    fn readNumber(self: *Lexer) Token {
        const line = self.line;
        const start = self.pos;

        while (self.peek()) |c| {
            if (std.ascii.isDigit(c) or c == '_' or c == 'x' or c == 'X' or
                (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))
            {
                _ = self.advance();
            } else {
                break;
            }
        }

        return .{ .kind = .number, .text = self.content[start..self.pos], .line = line };
    }

    fn readIdentifier(self: *Lexer) Token {
        const line = self.line;
        const start = self.pos;

        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                _ = self.advance();
            } else {
                break;
            }
        }

        return .{ .kind = .identifier, .text = self.content[start..self.pos], .line = line };
    }
};

/// Parser state
const ParserState = struct {
    allocator: Allocator,
    lexer: Lexer,
    current: Token,
    project: *Project,
    current_dir: []const u8,
    variables: std.StringHashMap(MesonValue),
    options: TranslationOptions,

    fn init(allocator: Allocator, content: []const u8, project: *Project, dir: []const u8, options: TranslationOptions) ParserState {
        var state = ParserState{
            .allocator = allocator,
            .lexer = Lexer.init(allocator, content),
            .current = undefined,
            .project = project,
            .current_dir = dir,
            .variables = std.StringHashMap(MesonValue).init(allocator),
            .options = options,
        };
        state.current = state.lexer.nextToken();
        return state;
    }

    fn deinit(self: *ParserState) void {
        self.variables.deinit();
    }

    fn advance(self: *ParserState) Token {
        const prev = self.current;
        self.current = self.lexer.nextToken();
        return prev;
    }

    fn expect(self: *ParserState, kind: TokenType) !Token {
        if (self.current.kind != kind) {
            return error.UnexpectedToken;
        }
        return self.advance();
    }

    fn skipNewlines(self: *ParserState) void {
        while (self.current.kind == .newline) {
            _ = self.advance();
        }
    }
};

/// Parse meson.build and return Project
pub fn parse(allocator: Allocator, path: []const u8, options: TranslationOptions) !Project {
    const dir = std.fs.path.dirname(path) orelse ".";

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var project = Project.init(allocator, "meson_project", dir);
    errdefer project.deinit();

    var state = ParserState.init(allocator, content, &project, dir, options);
    defer state.deinit();

    try parseStatements(&state);

    return project;
}

fn parseStatements(state: *ParserState) !void {
    while (state.current.kind != .eof) {
        state.skipNewlines();
        if (state.current.kind == .eof) break;

        try parseStatement(state);
    }
}

fn parseStatement(state: *ParserState) !void {
    if (state.current.kind != .identifier) {
        _ = state.advance();
        return;
    }

    const name = state.current.text;
    _ = state.advance();

    // Check for assignment
    if (state.current.kind == .equals) {
        _ = state.advance();
        const value = try parseExpression(state);
        try state.variables.put(name, value);
        return;
    }

    // Check for function call
    if (state.current.kind == .lparen) {
        try handleFunctionCall(state, name);
        return;
    }

    // Method call chain
    if (state.current.kind == .dot) {
        _ = state.advance();
        if (state.current.kind == .identifier) {
            const method = state.current.text;
            _ = state.advance();
            if (state.current.kind == .lparen) {
                // Variable method call - we track certain patterns
                try handleMethodCall(state, name, method);
            }
        }
    }
}

fn parseExpression(state: *ParserState) !MesonValue {
    return switch (state.current.kind) {
        .string => blk: {
            const text = state.current.text;
            _ = state.advance();
            break :blk .{ .string = text };
        },
        .number => blk: {
            const text = state.current.text;
            _ = state.advance();
            const num = std.fmt.parseInt(i64, text, 0) catch 0;
            break :blk .{ .number = num };
        },
        .identifier => blk: {
            const ident = state.current.text;
            _ = state.advance();

            // Check for true/false
            if (std.mem.eql(u8, ident, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, ident, "false")) break :blk .{ .boolean = false };

            // Check for function call
            if (state.current.kind == .lparen) {
                const args = try parseArguments(state);
                break :blk .{ .call = .{
                    .name = ident,
                    .args = args.positional,
                    .kwargs = args.keyword,
                } };
            }

            break :blk .{ .identifier = ident };
        },
        .lbracket => try parseArray(state),
        .lbrace => try parseDict(state),
        else => .{ .string = "" },
    };
}

fn parseArray(state: *ParserState) !MesonValue {
    _ = try state.expect(.lbracket);

    var items = std.ArrayList(MesonValue).init(state.allocator);
    errdefer items.deinit();

    while (state.current.kind != .rbracket and state.current.kind != .eof) {
        state.skipNewlines();
        if (state.current.kind == .rbracket) break;

        const item = try parseExpression(state);
        try items.append(item);

        state.skipNewlines();
        if (state.current.kind == .comma) {
            _ = state.advance();
        }
    }

    _ = try state.expect(.rbracket);
    return .{ .array = try items.toOwnedSlice() };
}

fn parseDict(state: *ParserState) !MesonValue {
    _ = try state.expect(.lbrace);

    var dict = std.StringHashMap(MesonValue).init(state.allocator);
    errdefer dict.deinit();

    while (state.current.kind != .rbrace and state.current.kind != .eof) {
        state.skipNewlines();
        if (state.current.kind == .rbrace) break;

        // Key
        var key: []const u8 = "";
        if (state.current.kind == .string) {
            key = state.current.text;
            _ = state.advance();
        } else if (state.current.kind == .identifier) {
            key = state.current.text;
            _ = state.advance();
        } else {
            break;
        }

        _ = try state.expect(.colon);

        const value = try parseExpression(state);
        try dict.put(key, value);

        state.skipNewlines();
        if (state.current.kind == .comma) {
            _ = state.advance();
        }
    }

    _ = try state.expect(.rbrace);
    return .{ .dict = dict };
}

const ParsedArgs = struct {
    positional: []const MesonValue,
    keyword: std.StringHashMap(MesonValue),
};

fn parseArguments(state: *ParserState) !ParsedArgs {
    _ = try state.expect(.lparen);

    var positional = std.ArrayList(MesonValue).init(state.allocator);
    errdefer positional.deinit();

    var keyword = std.StringHashMap(MesonValue).init(state.allocator);
    errdefer keyword.deinit();

    while (state.current.kind != .rparen and state.current.kind != .eof) {
        state.skipNewlines();
        if (state.current.kind == .rparen) break;

        // Check for keyword argument
        if (state.current.kind == .identifier) {
            const ident = state.current.text;
            const saved_pos = state.lexer.pos;
            _ = state.advance();

            if (state.current.kind == .colon) {
                _ = state.advance();
                const value = try parseExpression(state);
                try keyword.put(ident, value);
            } else {
                // Not a keyword arg, restore and parse as expression
                state.lexer.pos = saved_pos - ident.len;
                state.current = state.lexer.nextToken();
                const value = try parseExpression(state);
                try positional.append(value);
            }
        } else {
            const value = try parseExpression(state);
            try positional.append(value);
        }

        state.skipNewlines();
        if (state.current.kind == .comma) {
            _ = state.advance();
        }
    }

    _ = try state.expect(.rparen);

    return .{
        .positional = try positional.toOwnedSlice(),
        .keyword = keyword,
    };
}

fn handleFunctionCall(state: *ParserState, name: []const u8) !void {
    const args = try parseArguments(state);

    if (std.mem.eql(u8, name, "project")) {
        try handleProject(state, args);
    } else if (std.mem.eql(u8, name, "executable")) {
        try handleExecutable(state, args);
    } else if (std.mem.eql(u8, name, "library") or
        std.mem.eql(u8, name, "static_library") or
        std.mem.eql(u8, name, "shared_library"))
    {
        try handleLibrary(state, name, args);
    } else if (std.mem.eql(u8, name, "dependency")) {
        try handleDependency(state, args);
    } else if (std.mem.eql(u8, name, "subdir")) {
        try handleSubdir(state, args);
    } else if (std.mem.eql(u8, name, "include_directories")) {
        // Store for later use
    }
}

fn handleMethodCall(state: *ParserState, object: []const u8, method: []const u8) !void {
    _ = object;
    const args = try parseArguments(state);
    _ = args;

    // Track dependency methods like dep.found()
    if (std.mem.eql(u8, method, "found")) {
        // Dependency check
    }
}

fn handleProject(state: *ParserState, args: ParsedArgs) !void {
    if (args.positional.len > 0) {
        if (args.positional[0] == .string) {
            state.project.name = args.positional[0].string;
        }
    }

    if (args.keyword.get("version")) |ver| {
        if (ver == .string) {
            state.project.version = ver.string;
        }
    }

    if (args.keyword.get("license")) |lic| {
        if (lic == .string) {
            state.project.license = lic.string;
        }
    }
}

fn handleExecutable(state: *ParserState, args: ParsedArgs) !void {
    if (args.positional.len < 1) return;

    const name = switch (args.positional[0]) {
        .string => |s| s,
        else => return,
    };

    var target = Target.init(state.allocator, name, .executable);
    errdefer target.deinit();

    // Collect source files
    for (args.positional[1..]) |arg| {
        switch (arg) {
            .string => |s| {
                const path = try std.fs.path.join(state.allocator, &.{ state.current_dir, s });
                try target.sources.append(path);
            },
            .array => |arr| {
                for (arr) |item| {
                    if (item == .string) {
                        const path = try std.fs.path.join(state.allocator, &.{ state.current_dir, item.string });
                        try target.sources.append(path);
                    }
                }
            },
            else => {},
        }
    }

    // Handle keyword arguments
    if (args.keyword.get("sources")) |sources| {
        if (sources == .array) {
            for (sources.array) |src| {
                if (src == .string) {
                    const path = try std.fs.path.join(state.allocator, &.{ state.current_dir, src.string });
                    try target.sources.append(path);
                }
            }
        }
    }

    if (args.keyword.get("include_directories")) |inc| {
        _ = inc;
        // Handle include directories
    }

    if (args.keyword.get("dependencies")) |deps| {
        if (deps == .array) {
            for (deps.array) |dep| {
                if (dep == .identifier) {
                    try target.dependencies.append(dep.identifier);
                }
            }
        }
    }

    if (args.keyword.get("c_args")) |c_args| {
        if (c_args == .array) {
            for (c_args.array) |arg| {
                if (arg == .string) {
                    if (std.mem.startsWith(u8, arg.string, "-D")) {
                        try target.flags.defines.append(arg.string[2..]);
                    } else {
                        try target.flags.compile_flags.append(arg.string);
                    }
                }
            }
        }
    }

    try state.project.addTarget(target);
}

fn handleLibrary(state: *ParserState, func_name: []const u8, args: ParsedArgs) !void {
    if (args.positional.len < 1) return;

    const name = switch (args.positional[0]) {
        .string => |s| s,
        else => return,
    };

    const kind: TargetKind = if (std.mem.eql(u8, func_name, "shared_library"))
        .shared_library
    else if (std.mem.eql(u8, func_name, "static_library"))
        .static_library
    else
        .static_library; // default for library()

    var target = Target.init(state.allocator, name, kind);
    errdefer target.deinit();

    // Collect source files (same as executable)
    for (args.positional[1..]) |arg| {
        switch (arg) {
            .string => |s| {
                const path = try std.fs.path.join(state.allocator, &.{ state.current_dir, s });
                try target.sources.append(path);
            },
            .array => |arr| {
                for (arr) |item| {
                    if (item == .string) {
                        const path = try std.fs.path.join(state.allocator, &.{ state.current_dir, item.string });
                        try target.sources.append(path);
                    }
                }
            },
            else => {},
        }
    }

    if (args.keyword.get("sources")) |sources| {
        if (sources == .array) {
            for (sources.array) |src| {
                if (src == .string) {
                    const path = try std.fs.path.join(state.allocator, &.{ state.current_dir, src.string });
                    try target.sources.append(path);
                }
            }
        }
    }

    try state.project.addTarget(target);
}

fn handleDependency(state: *ParserState, args: ParsedArgs) !void {
    if (args.positional.len < 1) return;

    const name = switch (args.positional[0]) {
        .string => |s| s,
        else => return,
    };

    var dep = Dependency{
        .name = name,
        .kind = .build,
    };

    if (args.keyword.get("version")) |ver| {
        if (ver == .string) {
            dep.version = ver.string;
        }
    }

    if (args.keyword.get("required")) |req| {
        if (req == .boolean and !req.boolean) {
            dep.kind = .optional;
        }
    }

    try state.project.addDependency(dep);
}

fn handleSubdir(state: *ParserState, args: ParsedArgs) !void {
    if (args.positional.len < 1) return;

    const subdir_name = switch (args.positional[0]) {
        .string => |s| s,
        else => return,
    };

    const subdir_path = try std.fs.path.join(state.allocator, &.{ state.current_dir, subdir_name, "meson.build" });
    defer state.allocator.free(subdir_path);

    // Try to parse subdirectory
    const file = std.fs.cwd().openFile(subdir_path, .{}) catch {
        try state.project.addWarning(.{
            .severity = .warning,
            .message = try std.fmt.allocPrint(state.allocator, "Could not open subdir: {s}", .{subdir_name}),
        });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(state.allocator, 10 * 1024 * 1024) catch return;
    defer state.allocator.free(content);

    const old_dir = state.current_dir;
    state.current_dir = try std.fs.path.join(state.allocator, &.{ state.current_dir, subdir_name });
    defer state.current_dir = old_dir;

    const old_lexer = state.lexer;
    const old_current = state.current;
    state.lexer = Lexer.init(state.allocator, content);
    state.current = state.lexer.nextToken();

    parseStatements(state) catch |err| {
        try state.project.addWarning(.{
            .severity = .warning,
            .message = try std.fmt.allocPrint(state.allocator, "Error parsing subdir {s}: {}", .{ subdir_name, err }),
        });
    };

    state.lexer = old_lexer;
    state.current = old_current;
}

// Tests
test "Lexer tokenization" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "project('test', 'c')");

    const t1 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.identifier, t1.kind);
    try std.testing.expectEqualStrings("project", t1.text);

    const t2 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.lparen, t2.kind);

    const t3 = lexer.nextToken();
    try std.testing.expectEqual(TokenType.string, t3.kind);
    try std.testing.expectEqualStrings("test", t3.text);
}
