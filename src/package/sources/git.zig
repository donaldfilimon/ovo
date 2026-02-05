//! Git repository source.
//!
//! Handles cloning git repositories, resolving tags/branches/commits,
//! and extracting package contents from specific subdirectories.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const integrity = @import("../integrity.zig");

/// Git-specific errors.
pub const GitError = error{
    CloneFailed,
    FetchFailed,
    CheckoutFailed,
    RefNotFound,
    InvalidRepository,
    NetworkError,
    AuthenticationFailed,
    SubmoduleFailed,
    OutOfMemory,
    CommandFailed,
};

/// Git reference types.
pub const RefType = enum {
    branch,
    tag,
    commit,
    head,

    pub fn fromString(ref: []const u8) ?RefType {
        if (ref.len == 40 and isHexString(ref)) {
            return .commit;
        }
        if (std.mem.startsWith(u8, ref, "refs/heads/")) {
            return .branch;
        }
        if (std.mem.startsWith(u8, ref, "refs/tags/")) {
            return .tag;
        }
        // Could be a branch name or tag name
        return null;
    }
};

fn isHexString(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Git repository configuration.
pub const GitConfig = struct {
    /// Repository URL.
    url: []const u8,

    /// Reference (branch, tag, commit).
    ref: ?[]const u8 = null,

    /// Subdirectory within the repository.
    subdir: ?[]const u8 = null,

    /// Shallow clone depth (0 = full clone).
    depth: u32 = 1,

    /// Initialize submodules.
    submodules: bool = false,

    /// Recursive submodule initialization.
    recursive_submodules: bool = false,

    /// Authentication token for private repos.
    auth_token: ?[]const u8 = null,
};

/// Result of a git clone operation.
pub const CloneResult = struct {
    /// Local path to the cloned repository.
    path: []const u8,

    /// Resolved commit hash.
    commit: []const u8,

    /// Branch name if applicable.
    branch: ?[]const u8 = null,

    /// Tag name if applicable.
    tag: ?[]const u8 = null,

    /// Content hash of the cloned content.
    content_hash: []const u8,

    pub fn deinit(self: *CloneResult, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.commit);
        if (self.branch) |b| allocator.free(b);
        if (self.tag) |t| allocator.free(t);
        allocator.free(self.content_hash);
    }
};

/// Git source handler.
pub const GitSource = struct {
    allocator: Allocator,
    work_dir: []const u8,

    /// Git executable path.
    git_path: []const u8 = "git",

    pub fn init(allocator: Allocator, work_dir: []const u8) GitSource {
        return .{
            .allocator = allocator,
            .work_dir = work_dir,
        };
    }

    /// Clone a repository.
    pub fn clone(self: *GitSource, config: GitConfig, dest: []const u8) GitError!CloneResult {
        // Build clone command
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        args.appendSlice(&.{ self.git_path, "clone" }) catch return error.OutOfMemory;

        // Add depth for shallow clone
        if (config.depth > 0) {
            args.appendSlice(&.{ "--depth", "1" }) catch return error.OutOfMemory;
        }

        // Add branch/tag reference
        if (config.ref) |ref| {
            const ref_type = RefType.fromString(ref);
            if (ref_type != .commit) {
                args.appendSlice(&.{ "--branch", ref }) catch return error.OutOfMemory;
            }
        }

        // Add submodule options
        if (config.submodules) {
            if (config.recursive_submodules) {
                args.append("--recurse-submodules") catch return error.OutOfMemory;
            }
        }

        // Prepare URL (possibly with auth token)
        const url = if (config.auth_token) |token|
            self.injectAuthToken(config.url, token) catch return error.OutOfMemory
        else
            config.url;
        defer if (config.auth_token != null) self.allocator.free(url);

        args.append(url) catch return error.OutOfMemory;
        args.append(dest) catch return error.OutOfMemory;

        // Execute clone
        try self.runGitCommand(args.items);

        // If ref is a commit hash, we need to checkout
        if (config.ref) |ref| {
            if (RefType.fromString(ref) == .commit) {
                // Fetch the specific commit
                try self.fetchCommit(dest, ref);
                try self.checkout(dest, ref);
            }
        }

        // Initialize submodules if needed
        if (config.submodules and !config.recursive_submodules) {
            self.initSubmodules(dest, config.recursive_submodules) catch {};
        }

        // Get resolved commit
        const commit = try self.getHead(dest);
        errdefer self.allocator.free(commit);

        // Get branch/tag info
        const branch = self.getCurrentBranch(dest) catch null;
        errdefer if (branch) |b| self.allocator.free(b);

        // Calculate content hash
        const target_path = if (config.subdir) |subdir|
            std.fs.path.join(self.allocator, &.{ dest, subdir }) catch return error.OutOfMemory
        else
            self.allocator.dupe(u8, dest) catch return error.OutOfMemory;
        defer self.allocator.free(target_path);

        const content_hash = integrity.hashDirectory(self.allocator, target_path) catch {
            // Fallback to commit hash if directory hashing fails
            return CloneResult{
                .path = self.allocator.dupe(u8, dest) catch return error.OutOfMemory,
                .commit = commit,
                .branch = branch,
                .content_hash = self.allocator.dupe(u8, commit) catch return error.OutOfMemory,
            };
        };
        const hash_str = integrity.hashToString(content_hash);

        return CloneResult{
            .path = self.allocator.dupe(u8, dest) catch return error.OutOfMemory,
            .commit = commit,
            .branch = branch,
            .content_hash = self.allocator.dupe(u8, &hash_str) catch return error.OutOfMemory,
        };
    }

    /// Fetch updates for an existing clone.
    pub fn fetch(self: *GitSource, repo_path: []const u8, ref: ?[]const u8) GitError!void {
        if (ref) |r| {
            try self.runGitCommand(&.{ self.git_path, "-C", repo_path, "fetch", "origin", r });
        } else {
            try self.runGitCommand(&.{ self.git_path, "-C", repo_path, "fetch", "origin" });
        }
    }

    /// Checkout a specific ref.
    pub fn checkout(self: *GitSource, repo_path: []const u8, ref: []const u8) GitError!void {
        try self.runGitCommand(&.{ self.git_path, "-C", repo_path, "checkout", ref });
    }

    /// Fetch a specific commit (for deep clones).
    fn fetchCommit(self: *GitSource, repo_path: []const u8, commit: []const u8) GitError!void {
        try self.runGitCommand(&.{
            self.git_path, "-C", repo_path, "fetch", "--depth", "1", "origin", commit,
        });
    }

    /// Get the HEAD commit hash.
    pub fn getHead(self: *GitSource, repo_path: []const u8) GitError![]const u8 {
        return self.runGitCommandOutput(&.{
            self.git_path, "-C", repo_path, "rev-parse", "HEAD",
        });
    }

    /// Get the current branch name.
    pub fn getCurrentBranch(self: *GitSource, repo_path: []const u8) GitError![]const u8 {
        return self.runGitCommandOutput(&.{
            self.git_path, "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD",
        });
    }

    /// List remote tags.
    pub fn listTags(self: *GitSource, url: []const u8) GitError![][]const u8 {
        const output = try self.runGitCommandOutput(&.{
            self.git_path, "ls-remote", "--tags", url,
        });
        defer self.allocator.free(output);

        var tags = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (tags.items) |t| self.allocator.free(t);
            tags.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            // Format: <hash>\trefs/tags/<name>
            var parts = std.mem.splitScalar(u8, line, '\t');
            _ = parts.next(); // Skip hash

            if (parts.next()) |ref| {
                if (std.mem.startsWith(u8, ref, "refs/tags/")) {
                    const tag_name = ref["refs/tags/".len..];
                    // Skip ^{} dereferenced tags
                    if (!std.mem.endsWith(u8, tag_name, "^{}")) {
                        const tag = self.allocator.dupe(u8, tag_name) catch return error.OutOfMemory;
                        tags.append(tag) catch return error.OutOfMemory;
                    }
                }
            }
        }

        return tags.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// List remote branches.
    pub fn listBranches(self: *GitSource, url: []const u8) GitError![][]const u8 {
        const output = try self.runGitCommandOutput(&.{
            self.git_path, "ls-remote", "--heads", url,
        });
        defer self.allocator.free(output);

        var branches = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (branches.items) |b| self.allocator.free(b);
            branches.deinit();
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var parts = std.mem.splitScalar(u8, line, '\t');
            _ = parts.next(); // Skip hash

            if (parts.next()) |ref| {
                if (std.mem.startsWith(u8, ref, "refs/heads/")) {
                    const branch_name = ref["refs/heads/".len..];
                    const branch = self.allocator.dupe(u8, branch_name) catch return error.OutOfMemory;
                    branches.append(branch) catch return error.OutOfMemory;
                }
            }
        }

        return branches.toOwnedSlice() catch return error.OutOfMemory;
    }

    /// Resolve a ref to a commit hash.
    pub fn resolveRef(self: *GitSource, url: []const u8, ref: []const u8) GitError![]const u8 {
        const output = try self.runGitCommandOutput(&.{
            self.git_path, "ls-remote", url, ref,
        });
        defer self.allocator.free(output);

        var lines = std.mem.splitScalar(u8, output, '\n');
        if (lines.next()) |line| {
            if (line.len >= 40) {
                return self.allocator.dupe(u8, line[0..40]) catch return error.OutOfMemory;
            }
        }

        return error.RefNotFound;
    }

    /// Check if a URL is a valid git repository.
    pub fn isValidRepository(self: *GitSource, url: []const u8) bool {
        self.runGitCommand(&.{ self.git_path, "ls-remote", "--exit-code", url }) catch return false;
        return true;
    }

    /// Initialize submodules.
    fn initSubmodules(self: *GitSource, repo_path: []const u8, recursive: bool) GitError!void {
        if (recursive) {
            try self.runGitCommand(&.{
                self.git_path, "-C", repo_path, "submodule", "update", "--init", "--recursive",
            });
        } else {
            try self.runGitCommand(&.{
                self.git_path, "-C", repo_path, "submodule", "update", "--init",
            });
        }
    }

    /// Inject auth token into URL.
    fn injectAuthToken(self: *GitSource, url: []const u8, token: []const u8) ![]const u8 {
        // https://github.com/... -> https://<token>@github.com/...
        if (std.mem.startsWith(u8, url, "https://")) {
            return std.fmt.allocPrint(self.allocator, "https://{s}@{s}", .{
                token,
                url["https://".len..],
            });
        }
        // For other URLs, return as-is
        return self.allocator.dupe(u8, url);
    }

    fn runGitCommand(self: *GitSource, args: []const []const u8) GitError!void {
        var child = std.process.Child.init(args, self.allocator);
        child.cwd = self.work_dir;

        child.spawn() catch return error.CommandFailed;
        const result = child.wait() catch return error.CommandFailed;

        if (result.Exited != 0) {
            return error.CommandFailed;
        }
    }

    fn runGitCommandOutput(self: *GitSource, args: []const []const u8) GitError![]const u8 {
        var child = std.process.Child.init(args, self.allocator);
        child.cwd = self.work_dir;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch return error.CommandFailed;

        const stdout = child.stdout orelse return error.CommandFailed;
        const output = stdout.reader().readAllAlloc(self.allocator, 1024 * 1024) catch return error.CommandFailed;
        errdefer self.allocator.free(output);

        const result = child.wait() catch return error.CommandFailed;

        if (result.Exited != 0) {
            self.allocator.free(output);
            return error.CommandFailed;
        }

        // Trim trailing whitespace
        const trimmed = std.mem.trimRight(u8, output, " \t\n\r");
        if (trimmed.len != output.len) {
            const result_str = self.allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
            self.allocator.free(output);
            return result_str;
        }

        return output;
    }
};

/// Parse a git URL into components.
pub const ParsedGitUrl = struct {
    protocol: Protocol,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
    path: ?[]const u8 = null,

    pub const Protocol = enum {
        https,
        ssh,
        git,
    };

    pub fn parse(allocator: Allocator, url: []const u8) !ParsedGitUrl {
        _ = allocator;

        // https://github.com/owner/repo.git
        if (std.mem.startsWith(u8, url, "https://")) {
            const rest = url["https://".len..];
            var parts = std.mem.splitScalar(u8, rest, '/');

            return .{
                .protocol = .https,
                .host = parts.next() orelse return error.InvalidRepository,
                .owner = parts.next() orelse return error.InvalidRepository,
                .repo = stripGitSuffix(parts.next() orelse return error.InvalidRepository),
            };
        }

        // git@github.com:owner/repo.git
        if (std.mem.startsWith(u8, url, "git@")) {
            const rest = url["git@".len..];
            const colon_pos = std.mem.indexOf(u8, rest, ":") orelse return error.InvalidRepository;

            const path_part = rest[colon_pos + 1 ..];
            var parts = std.mem.splitScalar(u8, path_part, '/');

            return .{
                .protocol = .ssh,
                .host = rest[0..colon_pos],
                .owner = parts.next() orelse return error.InvalidRepository,
                .repo = stripGitSuffix(parts.next() orelse return error.InvalidRepository),
            };
        }

        return error.InvalidRepository;
    }
};

fn stripGitSuffix(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".git")) {
        return name[0 .. name.len - 4];
    }
    return name;
}

// Tests
test "ref type detection" {
    try std.testing.expect(RefType.fromString("abc123def456abc123def456abc123def456abcd") == .commit);
    try std.testing.expect(RefType.fromString("refs/heads/main") == .branch);
    try std.testing.expect(RefType.fromString("refs/tags/v1.0.0") == .tag);
    try std.testing.expect(RefType.fromString("main") == null); // Ambiguous
}

test "hex string detection" {
    try std.testing.expect(isHexString("0123456789abcdef"));
    try std.testing.expect(!isHexString("0123456789abcdefg"));
    try std.testing.expect(!isHexString("hello world"));
}

test "strip git suffix" {
    try std.testing.expectEqualStrings("repo", stripGitSuffix("repo.git"));
    try std.testing.expectEqualStrings("repo", stripGitSuffix("repo"));
}
