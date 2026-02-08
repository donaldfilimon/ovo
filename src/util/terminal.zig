//! Terminal output utilities for ovo package manager.
//! Provides colors, progress bars, spinners, and formatted output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compat = @import("compat.zig");

/// ANSI color codes.
pub const Color = enum {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
        };
    }
};

/// Text styles.
pub const Style = enum {
    bold,
    dim,
    italic,
    underline,
    blink,
    reverse,
    hidden,
    strikethrough,

    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .italic => "\x1b[3m",
            .underline => "\x1b[4m",
            .blink => "\x1b[5m",
            .reverse => "\x1b[7m",
            .hidden => "\x1b[8m",
            .strikethrough => "\x1b[9m",
        };
    }
};

/// Terminal state and capabilities.
pub const Terminal = struct {
    writer: std.fs.File.Writer,
    is_tty: bool,
    supports_color: bool,
    width: u16,
    height: u16,

    /// Initialize terminal with stdout.
    pub fn init() Terminal {
        const stdout = std.io.getStdOut();
        const is_tty = stdout.isTty();

        var width: u16 = 80;
        var height: u16 = 24;

        if (is_tty) {
            if (stdout.getOrEnvTerminalSize()) |size| {
                width = size.width;
                height = size.height;
            }
        }

        return .{
            .writer = stdout.writer(),
            .is_tty = is_tty,
            .supports_color = is_tty and supportsColor(),
            .width = width,
            .height = height,
        };
    }

    /// Write colored text.
    pub fn colored(self: *Terminal, color: Color, text: []const u8) !void {
        if (self.supports_color) {
            try self.writer.writeAll(color.code());
            try self.writer.writeAll(text);
            try self.writer.writeAll(Color.reset.code());
        } else {
            try self.writer.writeAll(text);
        }
    }

    /// Write styled text.
    pub fn styled(self: *Terminal, style: Style, text: []const u8) !void {
        if (self.supports_color) {
            try self.writer.writeAll(style.code());
            try self.writer.writeAll(text);
            try self.writer.writeAll(Color.reset.code());
        } else {
            try self.writer.writeAll(text);
        }
    }

    /// Write text with color and style.
    pub fn write(self: *Terminal, color: ?Color, style: ?Style, text: []const u8) !void {
        if (self.supports_color) {
            if (style) |s| try self.writer.writeAll(s.code());
            if (color) |c| try self.writer.writeAll(c.code());
            try self.writer.writeAll(text);
            try self.writer.writeAll(Color.reset.code());
        } else {
            try self.writer.writeAll(text);
        }
    }

    /// Print formatted output.
    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }

    /// Clear the current line.
    pub fn clearLine(self: *Terminal) !void {
        if (self.is_tty) {
            try self.writer.writeAll("\x1b[2K\r");
        }
    }

    /// Move cursor up n lines.
    pub fn cursorUp(self: *Terminal, n: u16) !void {
        if (self.is_tty and n > 0) {
            try self.writer.print("\x1b[{d}A", .{n});
        }
    }

    /// Move cursor down n lines.
    pub fn cursorDown(self: *Terminal, n: u16) !void {
        if (self.is_tty and n > 0) {
            try self.writer.print("\x1b[{d}B", .{n});
        }
    }

    /// Hide cursor.
    pub fn hideCursor(self: *Terminal) !void {
        if (self.is_tty) {
            try self.writer.writeAll("\x1b[?25l");
        }
    }

    /// Show cursor.
    pub fn showCursor(self: *Terminal) !void {
        if (self.is_tty) {
            try self.writer.writeAll("\x1b[?25h");
        }
    }

    /// Flush output.
    pub fn flush(self: *Terminal) void {
        _ = self;
        // Writer doesn't need explicit flushing in Zig
    }
};

/// Check if terminal supports colors.
fn supportsColor() bool {
    // Check NO_COLOR environment variable
    if (compat.getenv("NO_COLOR")) |_| {
        return false;
    }

    // Check TERM
    if (compat.getenv("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) {
            return false;
        }
    }

    // Check COLORTERM
    if (compat.getenv("COLORTERM")) |_| {
        return true;
    }

    return true;
}

/// Progress bar for long-running operations.
pub const ProgressBar = struct {
    terminal: *Terminal,
    total: usize,
    current: usize,
    width: u16,
    label: []const u8,
    start_time: i64,

    const Self = @This();

    pub fn init(terminal: *Terminal, total: usize, label: []const u8) Self {
        const width = if (terminal.width > 40) terminal.width - 20 else 20;
        return .{
            .terminal = terminal,
            .total = total,
            .current = 0,
            .width = width,
            .label = label,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn update(self: *Self, current: usize) !void {
        self.current = current;
        try self.render();
    }

    pub fn increment(self: *Self) !void {
        if (self.current < self.total) {
            self.current += 1;
            try self.render();
        }
    }

    fn render(self: *Self) !void {
        if (!self.terminal.is_tty) return;

        try self.terminal.clearLine();

        const percent: f64 = if (self.total > 0)
            @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total))
        else
            0;

        const filled = @as(usize, @intFromFloat(percent * @as(f64, @floatFromInt(self.width))));
        const empty = self.width - @as(u16, @intCast(filled));

        // Label
        try self.terminal.colored(.cyan, self.label);
        try self.terminal.print(" [", .{});

        // Filled portion
        try self.terminal.colored(.green, repeatChar('=', filled));

        // Empty portion
        try self.terminal.colored(.bright_black, repeatChar('-', empty));

        try self.terminal.print("] {d}%", .{@as(u8, @intFromFloat(percent * 100))});

        self.terminal.flush();
    }

    pub fn finish(self: *Self, message_text: []const u8) !void {
        try self.terminal.clearLine();
        try self.terminal.colored(.green, "[done] ");
        try self.terminal.print("{s}\n", .{message_text});
    }
};

fn repeatChar(char: u8, count: usize) []const u8 {
    const buf = struct {
        var data: [256]u8 = undefined;
    };

    const len = @min(count, buf.data.len);
    @memset(buf.data[0..len], char);
    return buf.data[0..len];
}

/// Spinner for indeterminate operations.
pub const Spinner = struct {
    terminal: *Terminal,
    message_text: []const u8,
    frame: usize,
    running: bool,

    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const simple_frames = [_][]const u8{ "|", "/", "-", "\\" };

    const Self = @This();

    pub fn init(terminal: *Terminal, msg: []const u8) Self {
        return .{
            .terminal = terminal,
            .message_text = msg,
            .frame = 0,
            .running = false,
        };
    }

    pub fn start(self: *Self) !void {
        self.running = true;
        try self.terminal.hideCursor();
        try self.render();
    }

    pub fn tick(self: *Self) !void {
        if (!self.running) return;
        self.frame = (self.frame + 1) % frames.len;
        try self.render();
    }

    fn render(self: *Self) !void {
        if (!self.terminal.is_tty) return;

        try self.terminal.clearLine();

        const frame_chars = if (self.terminal.supports_color) frames else simple_frames;
        const current_frame = frame_chars[self.frame % frame_chars.len];

        try self.terminal.colored(.cyan, current_frame);
        try self.terminal.print(" {s}", .{self.message_text});

        self.terminal.flush();
    }

    pub fn stop(self: *Self, succeeded: bool, msg: []const u8) !void {
        self.running = false;
        try self.terminal.clearLine();
        try self.terminal.showCursor();

        if (succeeded) {
            try self.terminal.colored(.green, "[ok] ");
        } else {
            try self.terminal.colored(.red, "[err] ");
        }
        try self.terminal.print("{s}\n", .{msg});
    }

    pub fn updateMessage(self: *Self, msg: []const u8) void {
        self.message_text = msg;
    }
};

/// Formatted message types.
pub const MessageType = enum {
    info,
    success,
    warning,
    err,
    debug,

    fn prefix(self: MessageType) []const u8 {
        return switch (self) {
            .info => "[info]",
            .success => "[ok]",
            .warning => "[warn]",
            .err => "[err]",
            .debug => "[debug]",
        };
    }

    fn color(self: MessageType) Color {
        return switch (self) {
            .info => .cyan,
            .success => .green,
            .warning => .yellow,
            .err => .red,
            .debug => .bright_black,
        };
    }
};

/// Print a formatted message.
pub fn message(terminal: *Terminal, msg_type: MessageType, text: []const u8) !void {
    try terminal.colored(msg_type.color(), msg_type.prefix());
    try terminal.print(" {s}\n", .{text});
}

/// Print an info message.
pub fn info(terminal: *Terminal, text: []const u8) !void {
    try message(terminal, .info, text);
}

/// Print a success message.
pub fn success(terminal: *Terminal, text: []const u8) !void {
    try message(terminal, .success, text);
}

/// Print a warning message.
pub fn warning(terminal: *Terminal, text: []const u8) !void {
    try message(terminal, .warning, text);
}

/// Print an error message.
pub fn err(terminal: *Terminal, text: []const u8) !void {
    try message(terminal, .err, text);
}

/// Print a debug message.
pub fn debug(terminal: *Terminal, text: []const u8) !void {
    try message(terminal, .debug, text);
}

/// Table formatting.
pub const Table = struct {
    allocator: Allocator,
    headers: []const []const u8,
    rows: std.ArrayList([]const []const u8),
    column_widths: []usize,

    const Self = @This();

    pub fn init(allocator: Allocator, headers: []const []const u8) !Self {
        var widths = try allocator.alloc(usize, headers.len);
        for (headers, 0..) |h, i| {
            widths[i] = h.len;
        }

        return .{
            .allocator = allocator,
            .headers = headers,
            .rows = std.ArrayList([]const []const u8).init(allocator),
            .column_widths = widths,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.column_widths);
        self.rows.deinit();
    }

    pub fn addRow(self: *Self, row: []const []const u8) !void {
        for (row, 0..) |cell, i| {
            if (i < self.column_widths.len) {
                self.column_widths[i] = @max(self.column_widths[i], cell.len);
            }
        }
        try self.rows.append(row);
    }

    pub fn render(self: *Self, terminal: *Terminal) !void {
        // Print headers
        for (self.headers, 0..) |header, i| {
            try terminal.styled(.bold, header);
            try printPadding(terminal, self.column_widths[i] - header.len + 2);
        }
        try terminal.print("\n", .{});

        // Print separator
        for (self.column_widths) |col_width| {
            try terminal.colored(.bright_black, repeatChar('-', col_width));
            try terminal.print("  ", .{});
        }
        try terminal.print("\n", .{});

        // Print rows
        for (self.rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < self.column_widths.len) {
                    try terminal.print("{s}", .{cell});
                    try printPadding(terminal, self.column_widths[i] - cell.len + 2);
                }
            }
            try terminal.print("\n", .{});
        }
    }
};

fn printPadding(terminal: *Terminal, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try terminal.print(" ", .{});
    }
}

test "color codes" {
    try std.testing.expectEqualStrings("\x1b[31m", Color.red.code());
    try std.testing.expectEqualStrings("\x1b[0m", Color.reset.code());
}

test "style codes" {
    try std.testing.expectEqualStrings("\x1b[1m", Style.bold.code());
}
