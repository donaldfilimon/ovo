//! HTTP client utilities for ovo package manager.
//! Provides HTTP/HTTPS requests for downloading packages and fetching metadata.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

/// HTTP request methods.
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    PATCH,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .PATCH => "PATCH",
        };
    }
};

/// HTTP response status.
pub const Status = struct {
    code: u16,
    reason: []const u8,

    pub fn isSuccess(self: Status) bool {
        return self.code >= 200 and self.code < 300;
    }

    pub fn isRedirect(self: Status) bool {
        return self.code >= 300 and self.code < 400;
    }

    pub fn isClientError(self: Status) bool {
        return self.code >= 400 and self.code < 500;
    }

    pub fn isServerError(self: Status) bool {
        return self.code >= 500;
    }
};

/// HTTP response.
pub const Response = struct {
    status: Status,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
    }

    /// Get a header value (case-insensitive).
    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        // Headers are stored lowercase
        var lower_buf: [256]u8 = undefined;
        const lower = std.ascii.lowerString(&lower_buf, name);
        return self.headers.get(lower);
    }
};

/// HTTP request options.
pub const RequestOptions = struct {
    /// Request headers.
    headers: ?std.StringHashMap([]const u8) = null,
    /// Request body.
    body: ?[]const u8 = null,
    /// Timeout in milliseconds (0 = no timeout).
    timeout_ms: u64 = 30000,
    /// Follow redirects.
    follow_redirects: bool = true,
    /// Maximum redirects to follow.
    max_redirects: u8 = 10,
    /// User agent string.
    user_agent: []const u8 = "ovo/1.0",
};

/// Progress callback for downloads.
pub const ProgressCallback = *const fn (downloaded: usize, total: ?usize, context: ?*anyopaque) void;

/// Download options.
pub const DownloadOptions = struct {
    /// Base request options.
    request: RequestOptions = .{},
    /// Progress callback.
    on_progress: ?ProgressCallback = null,
    /// Progress callback context.
    progress_context: ?*anyopaque = null,
    /// Resume partial download if file exists.
    resume_download: bool = false,
};

/// HTTP client for making requests.
pub const Client = struct {
    allocator: Allocator,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    /// Perform an HTTP request.
    pub fn request(
        self: *Self,
        method: Method,
        url: []const u8,
        options: RequestOptions,
    ) !Response {
        const uri = try Uri.parse(url);

        var headers_buf: [16]std.http.Header = undefined;
        var header_count: usize = 0;

        // Add User-Agent
        headers_buf[header_count] = .{ .name = "User-Agent", .value = options.user_agent };
        header_count += 1;

        // Add Accept
        headers_buf[header_count] = .{ .name = "Accept", .value = "*/*" };
        header_count += 1;

        // Add custom headers
        if (options.headers) |hdrs| {
            var iter = hdrs.iterator();
            while (iter.next()) |entry| {
                if (header_count < headers_buf.len) {
                    headers_buf[header_count] = .{
                        .name = entry.key_ptr.*,
                        .value = entry.value_ptr.*,
                    };
                    header_count += 1;
                }
            }
        }

        const http_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
            .PATCH => .PATCH,
        };

        var req = try self.http_client.open(http_method, uri, .{
            .extra_headers = headers_buf[0..header_count],
            .redirect_behavior = if (options.follow_redirects) .follow else .not_allowed,
        });
        defer req.deinit();

        // Send body if present
        if (options.body) |body| {
            req.transfer_encoding = .{ .content_length = body.len };
        }

        try req.send();

        // Write body
        if (options.body) |body| {
            try req.writer().writeAll(body);
            try req.finish();
        }

        try req.wait();

        // Build response
        var response = Response{
            .status = .{
                .code = @intFromEnum(req.status),
                .reason = @tagName(req.status),
            },
            .headers = std.StringHashMap([]const u8).init(self.allocator),
            .body = &[_]u8{},
            .allocator = self.allocator,
        };
        errdefer response.deinit();

        // Copy headers
        var header_iter = req.response.iterateHeaders();
        while (header_iter.next()) |header| {
            var lower_name: [256]u8 = undefined;
            const lower = std.ascii.lowerString(&lower_name, header.name);
            const key = try self.allocator.dupe(u8, lower);
            errdefer self.allocator.free(key);
            const value = try self.allocator.dupe(u8, header.value);
            try response.headers.put(key, value);
        }

        // Read body
        var body_list = std.ArrayList(u8).init(self.allocator);
        defer body_list.deinit();

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try req.reader().read(&buf);
            if (n == 0) break;
            try body_list.appendSlice(buf[0..n]);
        }

        response.body = try body_list.toOwnedSlice();

        return response;
    }

    /// Perform a GET request.
    pub fn get(self: *Self, url: []const u8, options: RequestOptions) !Response {
        return self.request(.GET, url, options);
    }

    /// Perform a POST request.
    pub fn post(self: *Self, url: []const u8, body: ?[]const u8, options: RequestOptions) !Response {
        var opts = options;
        opts.body = body;
        return self.request(.POST, url, opts);
    }

    /// Download a file to disk.
    pub fn download(
        self: *Self,
        url: []const u8,
        dest_path: []const u8,
        options: DownloadOptions,
    ) !void {
        const uri = try Uri.parse(url);

        var headers_buf: [16]std.http.Header = undefined;
        var header_count: usize = 0;

        headers_buf[header_count] = .{ .name = "User-Agent", .value = options.request.user_agent };
        header_count += 1;

        // Check for resume
        var start_offset: usize = 0;
        if (options.resume_download) {
            if (std.fs.cwd().statFile(dest_path)) |stat| {
                start_offset = stat.size;
                var range_buf: [64]u8 = undefined;
                const range = std.fmt.bufPrint(&range_buf, "bytes={d}-", .{start_offset}) catch "bytes=0-";
                headers_buf[header_count] = .{ .name = "Range", .value = range };
                header_count += 1;
            } else |_| {}
        }

        var req = try self.http_client.open(.GET, uri, .{
            .extra_headers = headers_buf[0..header_count],
            .redirect_behavior = if (options.request.follow_redirects) .follow else .not_allowed,
        });
        defer req.deinit();

        try req.send();
        try req.wait();

        if (!Status.isSuccess(.{ .code = @intFromEnum(req.status), .reason = "" })) {
            return error.HttpError;
        }

        // Get content length
        const content_length: ?usize = if (req.response.content_length) |cl|
            @intCast(cl)
        else
            null;

        // Open destination file
        const file = if (start_offset > 0)
            try std.fs.cwd().openFile(dest_path, .{ .mode = .write_only })
        else
            try std.fs.cwd().createFile(dest_path, .{});
        defer file.close();

        if (start_offset > 0) {
            try file.seekTo(start_offset);
        }

        // Download with progress
        var downloaded: usize = 0;
        var buf: [8192]u8 = undefined;

        while (true) {
            const n = try req.reader().read(&buf);
            if (n == 0) break;

            try file.writeAll(buf[0..n]);
            downloaded += n;

            if (options.on_progress) |callback| {
                const total = if (content_length) |cl| cl + start_offset else null;
                callback(downloaded + start_offset, total, options.progress_context);
            }
        }
    }

    /// Get JSON from a URL.
    pub fn getJson(self: *Self, comptime T: type, url: []const u8, options: RequestOptions) !T {
        var response = try self.get(url, options);
        defer response.deinit();

        if (!response.status.isSuccess()) {
            return error.HttpError;
        }

        return std.json.parseFromSlice(T, self.allocator, response.body, .{}) catch {
            return error.JsonParseError;
        };
    }
};

/// URL building utilities.
pub const UrlBuilder = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn setBase(self: *Self, base: []const u8) !*Self {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(base);
        return self;
    }

    pub fn addPath(self: *Self, segment: []const u8) !*Self {
        // Ensure single slash separator
        if (self.buffer.items.len > 0 and self.buffer.items[self.buffer.items.len - 1] != '/') {
            try self.buffer.append('/');
        }

        const start: usize = if (segment.len > 0 and segment[0] == '/') 1 else 0;
        try self.buffer.appendSlice(segment[start..]);
        return self;
    }

    pub fn addQuery(self: *Self, key: []const u8, value: []const u8) !*Self {
        const sep: u8 = if (std.mem.indexOf(u8, self.buffer.items, "?") == null) '?' else '&';
        try self.buffer.append(sep);
        try self.appendEncoded(key);
        try self.buffer.append('=');
        try self.appendEncoded(value);
        return self;
    }

    fn appendEncoded(self: *Self, str: []const u8) !void {
        for (str) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try self.buffer.append(c);
            } else {
                try self.buffer.append('%');
                const hex = "0123456789ABCDEF";
                try self.buffer.append(hex[c >> 4]);
                try self.buffer.append(hex[c & 0x0F]);
            }
        }
    }

    pub fn build(self: *Self) []const u8 {
        return self.buffer.items;
    }

    pub fn buildOwned(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice();
    }
};

/// Parse Content-Type header.
pub fn parseContentType(content_type: []const u8) struct { mime: []const u8, charset: ?[]const u8 } {
    var mime: []const u8 = content_type;
    var charset: ?[]const u8 = null;

    if (std.mem.indexOf(u8, content_type, ";")) |semi| {
        mime = std.mem.trim(u8, content_type[0..semi], " ");
        const rest = content_type[semi + 1 ..];

        if (std.mem.indexOf(u8, rest, "charset=")) |cs| {
            var cs_value = rest[cs + 8 ..];
            if (std.mem.indexOf(u8, cs_value, ";")) |end| {
                cs_value = cs_value[0..end];
            }
            charset = std.mem.trim(u8, cs_value, " \"");
        }
    }

    return .{ .mime = mime, .charset = charset };
}

test "url builder" {
    const allocator = std.testing.allocator;
    var builder = UrlBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.setBase("https://api.example.com");
    _ = try builder.addPath("packages");
    _ = try builder.addPath("test");
    _ = try builder.addQuery("version", "1.0.0");

    try std.testing.expectEqualStrings(
        "https://api.example.com/packages/test?version=1.0.0",
        builder.build(),
    );
}

test "parse content type" {
    const result = parseContentType("application/json; charset=utf-8");
    try std.testing.expectEqualStrings("application/json", result.mime);
    try std.testing.expectEqualStrings("utf-8", result.charset.?);
}

test "status helpers" {
    try std.testing.expect((Status{ .code = 200, .reason = "OK" }).isSuccess());
    try std.testing.expect((Status{ .code = 301, .reason = "Moved" }).isRedirect());
    try std.testing.expect((Status{ .code = 404, .reason = "Not Found" }).isClientError());
    try std.testing.expect((Status{ .code = 500, .reason = "Error" }).isServerError());
}
