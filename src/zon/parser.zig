//! ZON parser for build.zon files.
//!
//! Parses build.zon files using Zig's std.zon and converts them to the Project model.
//! Handles all package metadata, targets, dependencies, and configuration options.
//!
//! This implementation uses a simple recursive descent parser for ZON format since
//! std.zon's high-level parsing API may change between versions. The parser handles
//! the complete build.zon schema defined in schema.zig.
const std = @import("std");
const schema = @import("schema.zig");

pub const ParseError = error{
    FileNotFound,
    InvalidSyntax,
    InvalidFieldType,
    MissingRequiredField,
    UnknownField,
    DuplicateField,
    InvalidEnumValue,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    EndOfStream,
    UnexpectedToken,
    AccessDenied,
    InvalidVersion,
};

/// Parser context holding allocator and error information.
pub const ParserContext = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ErrorInfo),
    warnings: std.ArrayList(ErrorInfo),
    source_path: ?[]const u8,

    pub const ErrorInfo = struct {
        message: []const u8,
        line: ?u32 = null,
        column: ?u32 = null,

        pub fn deinit(self: *ErrorInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.message);
        }
    };

    pub fn init(allocator: std.mem.Allocator, source_path: ?[]const u8) ParserContext {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(ErrorInfo).init(allocator),
            .warnings = std.ArrayList(ErrorInfo).init(allocator),
            .source_path = source_path,
        };
    }

    pub fn deinit(self: *ParserContext) void {
        for (self.errors.items) |*e| e.deinit(self.allocator);
        self.errors.deinit();
        for (self.warnings.items) |*w| w.deinit(self.allocator);
        self.warnings.deinit();
    }

    pub fn addError(self: *ParserContext, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(.{ .message = msg });
    }

    pub fn addErrorAt(self: *ParserContext, line: u32, column: u32, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(.{ .message = msg, .line = line, .column = column });
    }

    pub fn addWarning(self: *ParserContext, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.warnings.append(.{ .message = msg });
    }

    pub fn hasErrors(self: *const ParserContext) bool {
        return self.errors.items.len > 0;
    }
};

/// Token types for ZON lexer.
const TokenType = enum {
    dot,
    left_brace,
    right_brace,
    equals,
    comma,
    string,
    identifier,
    number,
    true_lit,
    false_lit,
    null_lit,
    eof,
    invalid,
};

/// Token structure.
const Token = struct {
    type: TokenType,
    start: usize,
    end: usize,
    line: u32,
    column: u32,
};

/// Simple ZON lexer.
const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    column: u32,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return .{ .type = .eof, .start = self.pos, .end = self.pos, .line = self.line, .column = self.column };
        }

        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;
        const c = self.source[self.pos];

        switch (c) {
            '.' => {
                self.advance();
                return .{ .type = .dot, .start = start, .end = self.pos, .line = start_line, .column = start_col };
            },
            '{' => {
                self.advance();
                return .{ .type = .left_brace, .start = start, .end = self.pos, .line = start_line, .column = start_col };
            },
            '}' => {
                self.advance();
                return .{ .type = .right_brace, .start = start, .end = self.pos, .line = start_line, .column = start_col };
            },
            '=' => {
                self.advance();
                return .{ .type = .equals, .start = start, .end = self.pos, .line = start_line, .column = start_col };
            },
            ',' => {
                self.advance();
                return .{ .type = .comma, .start = start, .end = self.pos, .line = start_line, .column = start_col };
            },
            '"' => return self.readString(),
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    return self.readIdentifier();
                }
                if (std.ascii.isDigit(c) or c == '-') {
                    return self.readNumber();
                }
                self.advance();
                return .{ .type = .invalid, .start = start, .end = self.pos, .line = start_line, .column = start_col };
            },
        }
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.advance();
            } else if (self.pos + 1 < self.source.len and c == '/' and self.source[self.pos + 1] == '/') {
                // Line comment
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn readString(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;
        self.advance(); // Skip opening quote

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.advance(); // Skip closing quote
                return .{ .type = .string, .start = start + 1, .end = self.pos - 1, .line = start_line, .column = start_col };
            }
            if (c == '\\' and self.pos + 1 < self.source.len) {
                self.advance(); // Skip backslash
            }
            self.advance();
        }

        return .{ .type = .invalid, .start = start, .end = self.pos, .line = start_line, .column = start_col };
    }

    fn readIdentifier(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
            self.advance();
        }

        const text = self.source[start..self.pos];
        const token_type: TokenType = if (std.mem.eql(u8, text, "true"))
            .true_lit
        else if (std.mem.eql(u8, text, "false"))
            .false_lit
        else if (std.mem.eql(u8, text, "null"))
            .null_lit
        else
            .identifier;

        return .{ .type = token_type, .start = start, .end = self.pos, .line = start_line, .column = start_col };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        if (self.pos < self.source.len and self.source[self.pos] == '-') {
            self.advance();
        }

        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.advance();
        }

        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.advance();
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.advance();
            }
        }

        return .{ .type = .number, .start = start, .end = self.pos, .line = start_line, .column = start_col };
    }

    pub fn getText(self: *const Lexer, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }
};

/// ZON value types for intermediate representation.
pub const ZonValue = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    null_val: void,
    array: []ZonValue,
    object: std.StringHashMap(ZonValue),

    pub fn deinit(self: *ZonValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |*v| v.deinit(allocator);
                allocator.free(arr);
            },
            .object => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }

    pub fn getString(self: ZonValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getBool(self: ZonValue) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getNumber(self: ZonValue) ?f64 {
        return switch (self) {
            .number => |n| n,
            else => null,
        };
    }

    pub fn getArray(self: ZonValue) ?[]ZonValue {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn getObject(self: *ZonValue) ?*std.StringHashMap(ZonValue) {
        return switch (self.*) {
            .object => |*o| o,
            else => null,
        };
    }
};

/// Parser for ZON format.
const ZonParser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    current: Token,
    ctx: *ParserContext,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, ctx: *ParserContext) ZonParser {
        var parser = ZonParser{
            .lexer = Lexer.init(source),
            .allocator = allocator,
            .current = undefined,
            .ctx = ctx,
        };
        parser.current = parser.lexer.next();
        return parser;
    }

    fn advance(self: *ZonParser) void {
        self.current = self.lexer.next();
    }

    fn expect(self: *ZonParser, expected: TokenType) !void {
        if (self.current.type != expected) {
            try self.ctx.addErrorAt(
                self.current.line,
                self.current.column,
                "Expected {s}, got {s}",
                .{ @tagName(expected), @tagName(self.current.type) },
            );
            return ParseError.UnexpectedToken;
        }
        self.advance();
    }

    pub fn parse(self: *ZonParser) !ZonValue {
        return self.parseValue();
    }

    fn parseValue(self: *ZonParser) !ZonValue {
        switch (self.current.type) {
            .dot => {
                self.advance();
                if (self.current.type == .left_brace) {
                    return self.parseObject();
                }
                // Anonymous struct field - not supported at top level
                return ParseError.InvalidSyntax;
            },
            .left_brace => return self.parseObject(),
            .string => {
                const text = try self.parseEscapedString(self.lexer.getText(self.current));
                self.advance();
                return .{ .string = text };
            },
            .number => {
                const text = self.lexer.getText(self.current);
                const num = std.fmt.parseFloat(f64, text) catch 0.0;
                self.advance();
                return .{ .number = num };
            },
            .true_lit => {
                self.advance();
                return .{ .boolean = true };
            },
            .false_lit => {
                self.advance();
                return .{ .boolean = false };
            },
            .null_lit => {
                self.advance();
                return .{ .null_val = {} };
            },
            else => {
                try self.ctx.addErrorAt(
                    self.current.line,
                    self.current.column,
                    "Unexpected token: {s}",
                    .{@tagName(self.current.type)},
                );
                return ParseError.InvalidSyntax;
            },
        }
    }

    fn parseObject(self: *ZonParser) !ZonValue {
        try self.expect(.left_brace);

        var obj = std.StringHashMap(ZonValue).init(self.allocator);
        errdefer {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            obj.deinit();
        }

        var is_array = false;
        var array_items = std.ArrayList(ZonValue).init(self.allocator);
        defer array_items.deinit();

        while (self.current.type != .right_brace and self.current.type != .eof) {
            if (self.current.type == .dot) {
                self.advance();
                if (self.current.type == .identifier) {
                    // Named field: .name = value
                    const key = try self.allocator.dupe(u8, self.lexer.getText(self.current));
                    errdefer self.allocator.free(key);
                    self.advance();
                    try self.expect(.equals);
                    var value = try self.parseValue();
                    errdefer value.deinit(self.allocator);
                    try obj.put(key, value);
                } else if (self.current.type == .left_brace) {
                    // Anonymous struct in array: .{ ... }
                    is_array = true;
                    var value = try self.parseObject();
                    errdefer value.deinit(self.allocator);
                    try array_items.append(value);
                } else {
                    try self.ctx.addError("Expected identifier or '{{' after '.'", .{});
                    return ParseError.InvalidSyntax;
                }
            } else if (self.current.type == .string) {
                // Array of strings
                is_array = true;
                const text = try self.parseEscapedString(self.lexer.getText(self.current));
                self.advance();
                try array_items.append(.{ .string = text });
            } else if (self.current.type == .number) {
                // Array of numbers
                is_array = true;
                const text = self.lexer.getText(self.current);
                const num = std.fmt.parseFloat(f64, text) catch 0.0;
                self.advance();
                try array_items.append(.{ .number = num });
            } else if (self.current.type == .true_lit or self.current.type == .false_lit) {
                // Array of booleans
                is_array = true;
                const val = self.current.type == .true_lit;
                self.advance();
                try array_items.append(.{ .boolean = val });
            } else {
                break;
            }

            // Optional comma
            if (self.current.type == .comma) {
                self.advance();
            }
        }

        try self.expect(.right_brace);

        if (is_array and obj.count() == 0) {
            // It's an array
            return .{ .array = try array_items.toOwnedSlice() };
        }

        return .{ .object = obj };
    }

    fn parseEscapedString(self: *ZonParser, raw: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                switch (raw[i]) {
                    'n' => try result.append('\n'),
                    'r' => try result.append('\r'),
                    't' => try result.append('\t'),
                    '\\' => try result.append('\\'),
                    '"' => try result.append('"'),
                    else => {
                        try result.append('\\');
                        try result.append(raw[i]);
                    },
                }
            } else {
                try result.append(raw[i]);
            }
            i += 1;
        }

        return result.toOwnedSlice();
    }
};

/// Parse a build.zon file from path.
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) ParseError!schema.Project {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return ParseError.FileNotFound,
        else => return ParseError.AccessDenied,
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return ParseError.OutOfMemory,
        else => return ParseError.AccessDenied,
    };
    defer allocator.free(content);

    return parseSource(allocator, content, path);
}

/// Parse build.zon content from a string.
pub fn parseSource(allocator: std.mem.Allocator, source: []const u8, source_path: ?[]const u8) ParseError!schema.Project {
    var ctx = ParserContext.init(allocator, source_path);
    defer ctx.deinit();

    const result = parseSourceWithContext(allocator, source, &ctx);
    if (ctx.hasErrors()) {
        return ParseError.InvalidSyntax;
    }
    return result;
}

/// Parse with full context for detailed error reporting.
pub fn parseSourceWithContext(
    allocator: std.mem.Allocator,
    source: []const u8,
    ctx: *ParserContext,
) ParseError!schema.Project {
    var parser = ZonParser.init(allocator, source, ctx);
    var root_value = try parser.parse();
    defer root_value.deinit(allocator);

    return convertToProject(allocator, &root_value, ctx);
}

/// Convert ZonValue to Project.
fn convertToProject(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ParseError!schema.Project {
    const obj = value.getObject() orelse {
        try ctx.addError("Root must be a struct", .{});
        return ParseError.InvalidSyntax;
    };

    var project = schema.Project{
        .name = undefined,
        .version = undefined,
        .targets = undefined,
    };

    // Parse required name
    if (obj.get("name")) |name_val| {
        if (name_val.getString()) |name| {
            project.name = try allocator.dupe(u8, name);
        } else {
            try ctx.addError("'name' must be a string", .{});
            return ParseError.InvalidFieldType;
        }
    } else {
        try ctx.addError("Missing required field 'name'", .{});
        return ParseError.MissingRequiredField;
    }
    errdefer allocator.free(project.name);

    // Parse required version
    if (obj.get("version")) |ver_val| {
        if (ver_val.getString()) |ver_str| {
            project.version = try schema.Version.parse(allocator, ver_str);
        } else {
            try ctx.addError("'version' must be a string", .{});
            return ParseError.InvalidFieldType;
        }
    } else {
        try ctx.addError("Missing required field 'version'", .{});
        return ParseError.MissingRequiredField;
    }
    errdefer project.version.deinit(allocator);

    // Parse optional metadata
    project.description = try getOptionalStringField(allocator, obj, "description");
    project.license = try getOptionalStringField(allocator, obj, "license");
    project.repository = try getOptionalStringField(allocator, obj, "repository");
    project.homepage = try getOptionalStringField(allocator, obj, "homepage");
    project.documentation = try getOptionalStringField(allocator, obj, "documentation");
    project.min_ovo_version = try getOptionalStringField(allocator, obj, "min_ovo_version");
    project.authors = try getOptionalStringArrayField(allocator, obj, "authors");
    project.keywords = try getOptionalStringArrayField(allocator, obj, "keywords");
    project.workspace_members = try getOptionalStringArrayField(allocator, obj, "workspace_members");

    // Parse defaults
    if (obj.getPtr("defaults")) |defaults_val| {
        project.defaults = try convertToDefaults(allocator, defaults_val, ctx);
    }

    // Parse targets (required)
    if (obj.getPtr("targets")) |targets_val| {
        project.targets = try convertToTargets(allocator, targets_val, ctx);
    } else {
        try ctx.addError("Missing required field 'targets'", .{});
        return ParseError.MissingRequiredField;
    }
    errdefer {
        for (project.targets) |*t| t.deinit(allocator);
        allocator.free(project.targets);
    }

    // Parse dependencies
    if (obj.getPtr("dependencies")) |deps_val| {
        project.dependencies = try convertToDependencies(allocator, deps_val, ctx);
    }

    // Parse tests
    if (obj.getPtr("tests")) |tests_val| {
        project.tests = try convertToTests(allocator, tests_val, ctx);
    }

    // Parse benchmarks
    if (obj.getPtr("benchmarks")) |benchmarks_val| {
        project.benchmarks = try convertToBenchmarks(allocator, benchmarks_val, ctx);
    }

    // Parse examples
    if (obj.getPtr("examples")) |examples_val| {
        project.examples = try convertToExamples(allocator, examples_val, ctx);
    }

    // Parse scripts
    if (obj.getPtr("scripts")) |scripts_val| {
        project.scripts = try convertToScripts(allocator, scripts_val, ctx);
    }

    // Parse profiles
    if (obj.getPtr("profiles")) |profiles_val| {
        project.profiles = try convertToProfiles(allocator, profiles_val, ctx);
    }

    // Parse cross_targets
    if (obj.getPtr("cross_targets")) |cross_val| {
        project.cross_targets = try convertToCrossTargets(allocator, cross_val, ctx);
    }

    // Parse features
    if (obj.getPtr("features")) |features_val| {
        project.features = try convertToFeatures(allocator, features_val, ctx);
    }

    // Parse modules
    if (obj.getPtr("modules")) |modules_val| {
        project.modules = try convertToModuleSettings(allocator, modules_val, ctx);
    }

    return project;
}

fn getOptionalStringField(allocator: std.mem.Allocator, obj: *std.StringHashMap(ZonValue), key: []const u8) !?[]const u8 {
    if (obj.get(key)) |val| {
        if (val.getString()) |s| {
            return try allocator.dupe(u8, s);
        }
    }
    return null;
}

fn getOptionalStringArrayField(allocator: std.mem.Allocator, obj: *std.StringHashMap(ZonValue), key: []const u8) !?[]const []const u8 {
    if (obj.getPtr(key)) |val| {
        if (val.getArray()) |arr| {
            var result = std.ArrayList([]const u8).init(allocator);
            errdefer {
                for (result.items) |s| allocator.free(s);
                result.deinit();
            }
            for (arr) |item| {
                if (item.getString()) |s| {
                    try result.append(try allocator.dupe(u8, s));
                }
            }
            return result.toOwnedSlice();
        }
    }
    return null;
}

fn getOptionalBoolField(obj: *std.StringHashMap(ZonValue), key: []const u8) ?bool {
    if (obj.get(key)) |val| {
        return val.getBool();
    }
    return null;
}

fn getOptionalU32Field(obj: *std.StringHashMap(ZonValue), key: []const u8) ?u32 {
    if (obj.get(key)) |val| {
        if (val.getNumber()) |n| {
            return @intFromFloat(n);
        }
    }
    return null;
}

fn convertToDefaults(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) !schema.Defaults {
    _ = ctx;
    const obj = value.getObject() orelse return schema.Defaults{};

    var defaults = schema.Defaults{};

    if (getOptionalStringField(allocator, obj, "cpp_standard") catch null) |cpp_str| {
        defer allocator.free(cpp_str);
        defaults.cpp_standard = schema.CppStandard.fromString(cpp_str);
    }
    if (getOptionalStringField(allocator, obj, "c_standard") catch null) |c_str| {
        defer allocator.free(c_str);
        defaults.c_standard = schema.CStandard.fromString(c_str);
    }
    if (getOptionalStringField(allocator, obj, "compiler") catch null) |comp_str| {
        defer allocator.free(comp_str);
        defaults.compiler = schema.Compiler.fromString(comp_str);
    }
    if (getOptionalStringField(allocator, obj, "optimization") catch null) |opt_str| {
        defer allocator.free(opt_str);
        defaults.optimization = schema.Optimization.fromString(opt_str);
    }

    if (obj.getPtr("includes")) |inc_val| {
        defaults.includes = try convertToIncludeSpecs(allocator, inc_val);
    }
    if (obj.getPtr("defines")) |def_val| {
        defaults.defines = try convertToDefineSpecs(allocator, def_val);
    }
    if (obj.getPtr("flags")) |flag_val| {
        defaults.flags = try convertToFlagSpecs(allocator, flag_val);
    }

    return defaults;
}

fn convertToTargets(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.Target {
    const arr = value.getArray() orelse return &[_]schema.Target{};

    var targets = std.ArrayList(schema.Target).init(allocator);
    errdefer {
        for (targets.items) |*t| t.deinit(allocator);
        targets.deinit();
    }

    for (arr) |*item| {
        const target = try convertToTarget(allocator, item, ctx);
        try targets.append(target);
    }

    return targets.toOwnedSlice();
}

fn convertToTarget(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) !schema.Target {
    const obj = value.getObject() orelse {
        try ctx.addError("Target must be a struct", .{});
        return ParseError.InvalidSyntax;
    };

    var target = schema.Target{
        .name = undefined,
        .target_type = undefined,
        .sources = undefined,
    };

    // Parse name
    if (obj.get("name")) |name_val| {
        if (name_val.getString()) |name| {
            target.name = try allocator.dupe(u8, name);
        } else {
            try ctx.addError("Target 'name' must be a string", .{});
            return ParseError.InvalidFieldType;
        }
    } else {
        try ctx.addError("Target missing required 'name'", .{});
        return ParseError.MissingRequiredField;
    }
    errdefer allocator.free(target.name);

    // Parse type
    if (obj.get("type")) |type_val| {
        if (type_val.getString()) |type_str| {
            target.target_type = schema.TargetType.fromString(type_str) orelse {
                try ctx.addError("Invalid target type: '{s}'", .{type_str});
                return ParseError.InvalidEnumValue;
            };
        } else {
            try ctx.addError("Target 'type' must be a string", .{});
            return ParseError.InvalidFieldType;
        }
    } else {
        try ctx.addError("Target '{s}' missing required 'type'", .{target.name});
        return ParseError.MissingRequiredField;
    }

    // Parse sources
    if (obj.getPtr("sources")) |sources_val| {
        target.sources = try convertToSourceSpecs(allocator, sources_val);
    } else {
        target.sources = try allocator.alloc(schema.SourceSpec, 0);
    }
    errdefer {
        for (target.sources) |*s| s.deinit(allocator);
        allocator.free(target.sources);
    }

    // Optional fields
    if (obj.getPtr("includes")) |inc_val| {
        target.includes = try convertToIncludeSpecs(allocator, inc_val);
    }
    if (obj.getPtr("defines")) |def_val| {
        target.defines = try convertToDefineSpecs(allocator, def_val);
    }
    if (obj.getPtr("flags")) |flag_val| {
        target.flags = try convertToFlagSpecs(allocator, flag_val);
    }
    target.link_libraries = try getOptionalStringArrayField(allocator, obj, "link_libraries");
    target.dependencies = try getOptionalStringArrayField(allocator, obj, "dependencies");
    target.output_name = try getOptionalStringField(allocator, obj, "output_name");
    target.install_dir = try getOptionalStringField(allocator, obj, "install_dir");
    target.required_features = try getOptionalStringArrayField(allocator, obj, "required_features");

    if (getOptionalStringField(allocator, obj, "cpp_standard") catch null) |cpp_str| {
        defer allocator.free(cpp_str);
        target.cpp_standard = schema.CppStandard.fromString(cpp_str);
    }
    if (getOptionalStringField(allocator, obj, "c_standard") catch null) |c_str| {
        defer allocator.free(c_str);
        target.c_standard = schema.CStandard.fromString(c_str);
    }
    if (getOptionalStringField(allocator, obj, "optimization") catch null) |opt_str| {
        defer allocator.free(opt_str);
        target.optimization = schema.Optimization.fromString(opt_str);
    }

    if (obj.getPtr("platform")) |plat_val| {
        target.platform = try convertToPlatformFilter(allocator, plat_val);
    }

    return target;
}

fn convertToSourceSpecs(allocator: std.mem.Allocator, value: *ZonValue) ![]schema.SourceSpec {
    const arr = value.getArray() orelse return &[_]schema.SourceSpec{};

    var sources = std.ArrayList(schema.SourceSpec).init(allocator);
    errdefer {
        for (sources.items) |*s| s.deinit(allocator);
        sources.deinit();
    }

    for (arr) |*item| {
        if (item.getString()) |pattern| {
            try sources.append(.{
                .pattern = try allocator.dupe(u8, pattern),
            });
        } else if (item.getObject()) |obj| {
            const pattern = (try getOptionalStringField(allocator, obj, "pattern")) orelse continue;
            var spec = schema.SourceSpec{
                .pattern = pattern,
            };
            spec.exclude = try getOptionalStringArrayField(allocator, obj, "exclude");
            if (obj.getPtr("platform")) |plat_val| {
                spec.platform = try convertToPlatformFilter(allocator, plat_val);
            }
            try sources.append(spec);
        }
    }

    return sources.toOwnedSlice();
}

fn convertToIncludeSpecs(allocator: std.mem.Allocator, value: *ZonValue) ![]schema.IncludeSpec {
    const arr = value.getArray() orelse return &[_]schema.IncludeSpec{};

    var includes = std.ArrayList(schema.IncludeSpec).init(allocator);
    errdefer {
        for (includes.items) |*i| i.deinit(allocator);
        includes.deinit();
    }

    for (arr) |*item| {
        if (item.getString()) |path| {
            try includes.append(.{
                .path = try allocator.dupe(u8, path),
            });
        } else if (item.getObject()) |obj| {
            const path = (try getOptionalStringField(allocator, obj, "path")) orelse continue;
            var spec = schema.IncludeSpec{
                .path = path,
                .system = getOptionalBoolField(obj, "system") orelse false,
            };
            if (obj.getPtr("platform")) |plat_val| {
                spec.platform = try convertToPlatformFilter(allocator, plat_val);
            }
            try includes.append(spec);
        }
    }

    return includes.toOwnedSlice();
}

fn convertToDefineSpecs(allocator: std.mem.Allocator, value: *ZonValue) ![]schema.DefineSpec {
    const arr = value.getArray() orelse return &[_]schema.DefineSpec{};

    var defines = std.ArrayList(schema.DefineSpec).init(allocator);
    errdefer {
        for (defines.items) |*d| d.deinit(allocator);
        defines.deinit();
    }

    for (arr) |*item| {
        if (item.getString()) |def_str| {
            if (std.mem.indexOf(u8, def_str, "=")) |eq_idx| {
                try defines.append(.{
                    .name = try allocator.dupe(u8, def_str[0..eq_idx]),
                    .value = try allocator.dupe(u8, def_str[eq_idx + 1 ..]),
                });
            } else {
                try defines.append(.{
                    .name = try allocator.dupe(u8, def_str),
                });
            }
        } else if (item.getObject()) |obj| {
            const name = (try getOptionalStringField(allocator, obj, "name")) orelse continue;
            var spec = schema.DefineSpec{
                .name = name,
                .value = try getOptionalStringField(allocator, obj, "value"),
            };
            if (obj.getPtr("platform")) |plat_val| {
                spec.platform = try convertToPlatformFilter(allocator, plat_val);
            }
            try defines.append(spec);
        }
    }

    return defines.toOwnedSlice();
}

fn convertToFlagSpecs(allocator: std.mem.Allocator, value: *ZonValue) ![]schema.FlagSpec {
    const arr = value.getArray() orelse return &[_]schema.FlagSpec{};

    var flags = std.ArrayList(schema.FlagSpec).init(allocator);
    errdefer {
        for (flags.items) |*f| f.deinit(allocator);
        flags.deinit();
    }

    for (arr) |*item| {
        if (item.getString()) |flag_str| {
            try flags.append(.{
                .flag = try allocator.dupe(u8, flag_str),
            });
        } else if (item.getObject()) |obj| {
            const flag = (try getOptionalStringField(allocator, obj, "flag")) orelse continue;
            var spec = schema.FlagSpec{
                .flag = flag,
                .compile_only = getOptionalBoolField(obj, "compile_only") orelse false,
                .link_only = getOptionalBoolField(obj, "link_only") orelse false,
            };
            if (obj.getPtr("platform")) |plat_val| {
                spec.platform = try convertToPlatformFilter(allocator, plat_val);
            }
            try flags.append(spec);
        }
    }

    return flags.toOwnedSlice();
}

fn convertToPlatformFilter(allocator: std.mem.Allocator, value: *ZonValue) !schema.PlatformFilter {
    const obj = value.getObject() orelse return schema.PlatformFilter{};

    var filter = schema.PlatformFilter{};

    if (getOptionalStringField(allocator, obj, "os") catch null) |os_str| {
        defer allocator.free(os_str);
        filter.os = schema.OsTag.fromString(os_str);
    }
    if (getOptionalStringField(allocator, obj, "arch") catch null) |arch_str| {
        defer allocator.free(arch_str);
        filter.arch = schema.CpuArch.fromString(arch_str);
    }
    if (getOptionalStringField(allocator, obj, "compiler") catch null) |comp_str| {
        defer allocator.free(comp_str);
        filter.compiler = schema.Compiler.fromString(comp_str);
    }

    return filter;
}

fn convertToDependencies(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.Dependency {
    const arr = value.getArray() orelse return &[_]schema.Dependency{};

    var deps = std.ArrayList(schema.Dependency).init(allocator);
    errdefer {
        for (deps.items) |*d| d.deinit(allocator);
        deps.deinit();
    }

    for (arr) |*item| {
        const dep = try convertToDependency(allocator, item, ctx);
        try deps.append(dep);
    }

    return deps.toOwnedSlice();
}

fn convertToDependency(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) !schema.Dependency {
    const obj = value.getObject() orelse {
        try ctx.addError("Dependency must be a struct", .{});
        return ParseError.InvalidSyntax;
    };

    var dep = schema.Dependency{
        .name = undefined,
        .source = undefined,
    };

    // Parse name
    if (obj.get("name")) |name_val| {
        if (name_val.getString()) |name| {
            dep.name = try allocator.dupe(u8, name);
        } else {
            try ctx.addError("Dependency 'name' must be a string", .{});
            return ParseError.InvalidFieldType;
        }
    } else {
        try ctx.addError("Dependency missing required 'name'", .{});
        return ParseError.MissingRequiredField;
    }
    errdefer allocator.free(dep.name);

    // Determine source type
    if (obj.getPtr("git")) |git_val| {
        if (git_val.getObject()) |git_obj| {
            dep.source = .{
                .git = .{
                    .url = (try getOptionalStringField(allocator, git_obj, "url")) orelse {
                        try ctx.addError("Git dependency '{s}' missing 'url'", .{dep.name});
                        return ParseError.MissingRequiredField;
                    },
                    .tag = try getOptionalStringField(allocator, git_obj, "tag"),
                    .branch = try getOptionalStringField(allocator, git_obj, "branch"),
                    .commit = try getOptionalStringField(allocator, git_obj, "commit"),
                },
            };
        }
    } else if (obj.getPtr("url")) |url_val| {
        if (url_val.getString()) |url_str| {
            dep.source = .{
                .url = .{
                    .location = try allocator.dupe(u8, url_str),
                    .hash = try getOptionalStringField(allocator, obj, "hash"),
                },
            };
        } else if (url_val.getObject()) |url_obj| {
            dep.source = .{
                .url = .{
                    .location = (try getOptionalStringField(allocator, url_obj, "location")) orelse {
                        try ctx.addError("URL dependency '{s}' missing 'location'", .{dep.name});
                        return ParseError.MissingRequiredField;
                    },
                    .hash = try getOptionalStringField(allocator, url_obj, "hash"),
                },
            };
        }
    } else if (obj.getPtr("path")) |path_val| {
        if (path_val.getString()) |path_str| {
            dep.source = .{ .path = try allocator.dupe(u8, path_str) };
        }
    } else if (obj.getPtr("vcpkg")) |vcpkg_val| {
        if (vcpkg_val.getObject()) |vcpkg_obj| {
            dep.source = .{
                .vcpkg = .{
                    .name = (try getOptionalStringField(allocator, vcpkg_obj, "name")) orelse {
                        try ctx.addError("vcpkg dependency '{s}' missing package 'name'", .{dep.name});
                        return ParseError.MissingRequiredField;
                    },
                    .version = try getOptionalStringField(allocator, vcpkg_obj, "version"),
                    .features = try getOptionalStringArrayField(allocator, vcpkg_obj, "features"),
                },
            };
        }
    } else if (obj.getPtr("conan")) |conan_val| {
        if (conan_val.getObject()) |conan_obj| {
            const pkg_name = (try getOptionalStringField(allocator, conan_obj, "name")) orelse {
                try ctx.addError("Conan dependency '{s}' missing package 'name'", .{dep.name});
                return ParseError.MissingRequiredField;
            };
            const version = (try getOptionalStringField(allocator, conan_obj, "version")) orelse {
                try ctx.addError("Conan dependency '{s}' missing 'version'", .{dep.name});
                return ParseError.MissingRequiredField;
            };
            dep.source = .{
                .conan = .{
                    .name = pkg_name,
                    .version = version,
                    .options = try getOptionalStringArrayField(allocator, conan_obj, "options"),
                },
            };
        }
    } else if (obj.getPtr("system")) |sys_val| {
        if (sys_val.getString()) |sys_name| {
            dep.source = .{
                .system = .{
                    .name = try allocator.dupe(u8, sys_name),
                    .fallback = null,
                },
            };
        } else if (sys_val.getObject()) |sys_obj| {
            dep.source = .{
                .system = .{
                    .name = (try getOptionalStringField(allocator, sys_obj, "name")) orelse {
                        try ctx.addError("System dependency '{s}' missing 'name'", .{dep.name});
                        return ParseError.MissingRequiredField;
                    },
                    .fallback = null,
                },
            };
        }
    } else {
        try ctx.addError("Dependency '{s}' has no valid source type", .{dep.name});
        return ParseError.MissingRequiredField;
    }

    dep.feature = try getOptionalStringField(allocator, obj, "feature");
    dep.build_options = try getOptionalStringArrayField(allocator, obj, "build_options");
    dep.components = try getOptionalStringArrayField(allocator, obj, "components");
    dep.link_static = getOptionalBoolField(obj, "link_static");

    return dep;
}

fn convertToTests(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.TestSpec {
    _ = ctx;
    const arr = value.getArray() orelse return &[_]schema.TestSpec{};

    var tests = std.ArrayList(schema.TestSpec).init(allocator);
    errdefer {
        for (tests.items) |*t| t.deinit(allocator);
        tests.deinit();
    }

    for (arr) |*item| {
        if (item.getObject()) |obj| {
            var test_spec = schema.TestSpec{
                .name = (try getOptionalStringField(allocator, obj, "name")) orelse continue,
                .sources = undefined,
            };
            if (obj.getPtr("sources")) |sources_val| {
                test_spec.sources = try convertToSourceSpecs(allocator, sources_val);
            } else {
                test_spec.sources = try allocator.alloc(schema.SourceSpec, 0);
            }
            test_spec.dependencies = try getOptionalStringArrayField(allocator, obj, "dependencies");
            test_spec.framework = try getOptionalStringField(allocator, obj, "framework");
            test_spec.args = try getOptionalStringArrayField(allocator, obj, "args");
            test_spec.env = try getOptionalStringArrayField(allocator, obj, "env");
            test_spec.working_dir = try getOptionalStringField(allocator, obj, "working_dir");
            test_spec.timeout = getOptionalU32Field(obj, "timeout");
            try tests.append(test_spec);
        }
    }

    return tests.toOwnedSlice();
}

fn convertToBenchmarks(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.BenchmarkSpec {
    _ = ctx;
    const arr = value.getArray() orelse return &[_]schema.BenchmarkSpec{};

    var benchmarks = std.ArrayList(schema.BenchmarkSpec).init(allocator);
    errdefer {
        for (benchmarks.items) |*b| b.deinit(allocator);
        benchmarks.deinit();
    }

    for (arr) |*item| {
        if (item.getObject()) |obj| {
            var bench = schema.BenchmarkSpec{
                .name = (try getOptionalStringField(allocator, obj, "name")) orelse continue,
                .sources = undefined,
            };
            if (obj.getPtr("sources")) |sources_val| {
                bench.sources = try convertToSourceSpecs(allocator, sources_val);
            } else {
                bench.sources = try allocator.alloc(schema.SourceSpec, 0);
            }
            bench.dependencies = try getOptionalStringArrayField(allocator, obj, "dependencies");
            bench.framework = try getOptionalStringField(allocator, obj, "framework");
            bench.iterations = getOptionalU32Field(obj, "iterations");
            bench.warmup = getOptionalU32Field(obj, "warmup");
            try benchmarks.append(bench);
        }
    }

    return benchmarks.toOwnedSlice();
}

fn convertToExamples(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.ExampleSpec {
    _ = ctx;
    const arr = value.getArray() orelse return &[_]schema.ExampleSpec{};

    var examples = std.ArrayList(schema.ExampleSpec).init(allocator);
    errdefer {
        for (examples.items) |*e| e.deinit(allocator);
        examples.deinit();
    }

    for (arr) |*item| {
        if (item.getObject()) |obj| {
            var example = schema.ExampleSpec{
                .name = (try getOptionalStringField(allocator, obj, "name")) orelse continue,
                .sources = undefined,
            };
            if (obj.getPtr("sources")) |sources_val| {
                example.sources = try convertToSourceSpecs(allocator, sources_val);
            } else {
                example.sources = try allocator.alloc(schema.SourceSpec, 0);
            }
            example.dependencies = try getOptionalStringArrayField(allocator, obj, "dependencies");
            example.description = try getOptionalStringField(allocator, obj, "description");
            try examples.append(example);
        }
    }

    return examples.toOwnedSlice();
}

fn convertToScripts(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.ScriptSpec {
    _ = ctx;
    const arr = value.getArray() orelse return &[_]schema.ScriptSpec{};

    var scripts = std.ArrayList(schema.ScriptSpec).init(allocator);
    errdefer {
        for (scripts.items) |*s| s.deinit(allocator);
        scripts.deinit();
    }

    for (arr) |*item| {
        if (item.getObject()) |obj| {
            var script = schema.ScriptSpec{
                .name = (try getOptionalStringField(allocator, obj, "name")) orelse continue,
                .command = (try getOptionalStringField(allocator, obj, "command")) orelse continue,
            };
            script.args = try getOptionalStringArrayField(allocator, obj, "args");
            script.env = try getOptionalStringArrayField(allocator, obj, "env");
            script.working_dir = try getOptionalStringField(allocator, obj, "working_dir");
            if (getOptionalStringField(allocator, obj, "hook") catch null) |hook_str| {
                defer allocator.free(hook_str);
                script.hook = schema.HookType.fromString(hook_str);
            }
            try scripts.append(script);
        }
    }

    return scripts.toOwnedSlice();
}

fn convertToProfiles(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.Profile {
    _ = ctx;
    const arr = value.getArray() orelse return &[_]schema.Profile{};

    var profiles = std.ArrayList(schema.Profile).init(allocator);
    errdefer {
        for (profiles.items) |*p| p.deinit(allocator);
        profiles.deinit();
    }

    for (arr) |*item| {
        if (item.getObject()) |obj| {
            var profile = schema.Profile{
                .name = (try getOptionalStringField(allocator, obj, "name")) orelse continue,
            };
            profile.inherits = try getOptionalStringField(allocator, obj, "inherits");
            if (getOptionalStringField(allocator, obj, "optimization") catch null) |opt_str| {
                defer allocator.free(opt_str);
                profile.optimization = schema.Optimization.fromString(opt_str);
            }
            if (getOptionalStringField(allocator, obj, "cpp_standard") catch null) |cpp_str| {
                defer allocator.free(cpp_str);
                profile.cpp_standard = schema.CppStandard.fromString(cpp_str);
            }
            if (getOptionalStringField(allocator, obj, "c_standard") catch null) |c_str| {
                defer allocator.free(c_str);
                profile.c_standard = schema.CStandard.fromString(c_str);
            }
            if (obj.getPtr("defines")) |def_val| {
                profile.defines = try convertToDefineSpecs(allocator, def_val);
            }
            if (obj.getPtr("flags")) |flag_val| {
                profile.flags = try convertToFlagSpecs(allocator, flag_val);
            }
            profile.sanitizers = try getOptionalStringArrayField(allocator, obj, "sanitizers");
            profile.debug_info = getOptionalBoolField(obj, "debug_info");
            profile.lto = getOptionalBoolField(obj, "lto");
            profile.pic = getOptionalBoolField(obj, "pic");
            try profiles.append(profile);
        }
    }

    return profiles.toOwnedSlice();
}

fn convertToCrossTargets(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.CrossTarget {
    const arr = value.getArray() orelse return &[_]schema.CrossTarget{};

    var targets = std.ArrayList(schema.CrossTarget).init(allocator);
    errdefer {
        for (targets.items) |*t| t.deinit(allocator);
        targets.deinit();
    }

    for (arr) |*item| {
        if (item.getObject()) |obj| {
            const name = (try getOptionalStringField(allocator, obj, "name")) orelse continue;
            errdefer allocator.free(name);

            const os_str = (try getOptionalStringField(allocator, obj, "os")) orelse {
                try ctx.addError("Cross target '{s}' missing 'os'", .{name});
                continue;
            };
            defer allocator.free(os_str);

            const arch_str = (try getOptionalStringField(allocator, obj, "arch")) orelse {
                try ctx.addError("Cross target '{s}' missing 'arch'", .{name});
                continue;
            };
            defer allocator.free(arch_str);

            const os = schema.OsTag.fromString(os_str) orelse {
                try ctx.addError("Cross target '{s}' has invalid OS: '{s}'", .{ name, os_str });
                continue;
            };
            const arch = schema.CpuArch.fromString(arch_str) orelse {
                try ctx.addError("Cross target '{s}' has invalid arch: '{s}'", .{ name, arch_str });
                continue;
            };

            var target = schema.CrossTarget{
                .name = name,
                .os = os,
                .arch = arch,
            };
            target.toolchain = try getOptionalStringField(allocator, obj, "toolchain");
            target.sysroot = try getOptionalStringField(allocator, obj, "sysroot");
            if (obj.getPtr("defines")) |def_val| {
                target.defines = try convertToDefineSpecs(allocator, def_val);
            }
            if (obj.getPtr("flags")) |flag_val| {
                target.flags = try convertToFlagSpecs(allocator, flag_val);
            }
            try targets.append(target);
        }
    }

    return targets.toOwnedSlice();
}

fn convertToFeatures(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) ![]schema.Feature {
    _ = ctx;
    const arr = value.getArray() orelse return &[_]schema.Feature{};

    var features = std.ArrayList(schema.Feature).init(allocator);
    errdefer {
        for (features.items) |*f| f.deinit(allocator);
        features.deinit();
    }

    for (arr) |*item| {
        if (item.getObject()) |obj| {
            var feature = schema.Feature{
                .name = (try getOptionalStringField(allocator, obj, "name")) orelse continue,
            };
            feature.description = try getOptionalStringField(allocator, obj, "description");
            feature.dependencies = try getOptionalStringArrayField(allocator, obj, "dependencies");
            feature.implies = try getOptionalStringArrayField(allocator, obj, "implies");
            feature.conflicts = try getOptionalStringArrayField(allocator, obj, "conflicts");
            feature.default = getOptionalBoolField(obj, "default") orelse false;
            if (obj.getPtr("defines")) |def_val| {
                feature.defines = try convertToDefineSpecs(allocator, def_val);
            }
            try features.append(feature);
        }
    }

    return features.toOwnedSlice();
}

fn convertToModuleSettings(allocator: std.mem.Allocator, value: *ZonValue, ctx: *ParserContext) !schema.ModuleSettings {
    _ = ctx;
    const obj = value.getObject() orelse return schema.ModuleSettings{};

    var modules = schema.ModuleSettings{};
    modules.enabled = getOptionalBoolField(obj, "enabled") orelse false;
    modules.cache_dir = try getOptionalStringField(allocator, obj, "cache_dir");

    if (obj.getPtr("interfaces")) |iface_val| {
        modules.interfaces = try convertToSourceSpecs(allocator, iface_val);
    }
    if (obj.getPtr("partitions")) |part_val| {
        modules.partitions = try convertToSourceSpecs(allocator, part_val);
    }

    return modules;
}

// ============================================================================
// Tests
// ============================================================================

test "parse simple project" {
    const allocator = std.testing.allocator;
    const source =
        \\.{
        \\    .name = "test_project",
        \\    .version = "1.0.0",
        \\    .targets = .{
        \\        .{
        \\            .name = "main",
        \\            .type = "executable",
        \\            .sources = .{ "src/main.cpp" },
        \\        },
        \\    },
        \\}
    ;

    var project = try parseSource(allocator, source, null);
    defer project.deinit(allocator);

    try std.testing.expectEqualStrings("test_project", project.name);
    try std.testing.expectEqual(@as(u32, 1), project.version.major);
    try std.testing.expectEqual(@as(usize, 1), project.targets.len);
    try std.testing.expectEqualStrings("main", project.targets[0].name);
    try std.testing.expectEqual(schema.TargetType.executable, project.targets[0].target_type);
}

test "parse project with dependencies" {
    const allocator = std.testing.allocator;
    const source =
        \\.{
        \\    .name = "myapp",
        \\    .version = "2.0.0",
        \\    .targets = .{
        \\        .{
        \\            .name = "myapp",
        \\            .type = "executable",
        \\            .sources = .{ "src/main.cpp" },
        \\        },
        \\    },
        \\    .dependencies = .{
        \\        .{
        \\            .name = "fmt",
        \\            .git = .{
        \\                .url = "https://github.com/fmtlib/fmt",
        \\                .tag = "10.0.0",
        \\            },
        \\        },
        \\        .{
        \\            .name = "zlib",
        \\            .system = "zlib",
        \\        },
        \\    },
        \\}
    ;

    var project = try parseSource(allocator, source, null);
    defer project.deinit(allocator);

    try std.testing.expectEqualStrings("myapp", project.name);
    try std.testing.expect(project.dependencies != null);
    try std.testing.expectEqual(@as(usize, 2), project.dependencies.?.len);
    try std.testing.expectEqualStrings("fmt", project.dependencies.?[0].name);
    try std.testing.expectEqualStrings("zlib", project.dependencies.?[1].name);
}

test "lexer basic tokens" {
    const source = ".{ .name = \"test\" }";
    var lexer = Lexer.init(source);

    try std.testing.expectEqual(TokenType.dot, lexer.next().type);
    try std.testing.expectEqual(TokenType.left_brace, lexer.next().type);
    try std.testing.expectEqual(TokenType.dot, lexer.next().type);
    try std.testing.expectEqual(TokenType.identifier, lexer.next().type);
    try std.testing.expectEqual(TokenType.equals, lexer.next().type);
    try std.testing.expectEqual(TokenType.string, lexer.next().type);
    try std.testing.expectEqual(TokenType.right_brace, lexer.next().type);
    try std.testing.expectEqual(TokenType.eof, lexer.next().type);
}
