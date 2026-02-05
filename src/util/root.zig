//! Utility modules for the ovo package manager.
//!
//! Provides common functionality for:
//! - File system operations (recursive copy, delete, glob expansion)
//! - Process spawning and output capture
//! - Cryptographic hashing for integrity verification
//! - Glob pattern matching
//! - Semantic versioning parsing and comparison
//! - Terminal colors, progress bars, and spinners
//! - HTTP client for downloading packages

const std = @import("std");

/// File system utilities (recursive operations, path manipulation, glob expansion).
pub const fs = @import("fs.zig");

/// Process spawning and management (subprocess execution, output capture).
pub const process = @import("process.zig");

/// Cryptographic hashing (SHA256, SHA512, BLAKE3) for integrity verification.
pub const hash = @import("hash.zig");

/// Glob pattern matching (*, **, ?, [abc], [a-z]).
pub const glob = @import("glob.zig");

/// Semantic versioning (SemVer 2.0.0) parsing and comparison.
pub const semver = @import("semver.zig");

/// Terminal output utilities (colors, progress bars, spinners, tables).
pub const terminal = @import("terminal.zig");

/// HTTP client for downloading packages and fetching metadata.
pub const http = @import("http.zig");

// Re-export commonly used types and functions

// File system
pub const exists = fs.exists;
pub const isDirectory = fs.isDirectory;
pub const isFile = fs.isFile;
pub const copyRecursive = fs.copyRecursive;
pub const deleteRecursive = fs.deleteRecursive;
pub const ensureDir = fs.ensureDir;
pub const readFile = fs.readFile;
pub const writeFile = fs.writeFile;
pub const CopyOptions = fs.CopyOptions;
pub const DeleteOptions = fs.DeleteOptions;

// Process
pub const run = process.run;
pub const shell = process.shell;
pub const exec = process.exec;
pub const execOutput = process.execOutput;
pub const which = process.which;
pub const ProcessResult = process.ProcessResult;
pub const ProcessOptions = process.ProcessOptions;
pub const ProcessBuilder = process.ProcessBuilder;

// Hash
pub const sha256 = hash.sha256;
pub const sha512 = hash.sha512;
pub const blake3 = hash.blake3;
pub const hashFile = hash.hashFile;
pub const verify = hash.verify;
pub const verifyFile = hash.verifyFile;
pub const Digest = hash.Digest;
pub const Algorithm = hash.Algorithm;

// Glob
pub const globMatch = glob.match;
pub const globMatchPath = glob.matchPath;
pub const globCompile = glob.compile;
pub const globFilter = glob.filter;
pub const isGlobPattern = glob.isGlobPattern;
pub const Pattern = glob.Pattern;

// Semver
pub const Version = semver.Version;
pub const Range = semver.Range;
pub const parseVersion = semver.parse;
pub const parseRange = semver.parseRange;

// Terminal
pub const Terminal = terminal.Terminal;
pub const Color = terminal.Color;
pub const Style = terminal.Style;
pub const ProgressBar = terminal.ProgressBar;
pub const Spinner = terminal.Spinner;
pub const Table = terminal.Table;
pub const info = terminal.info;
pub const success = terminal.success;
pub const warning = terminal.warning;
pub const err = terminal.err;

// HTTP
pub const HttpClient = http.Client;
pub const HttpResponse = http.Response;
pub const HttpStatus = http.Status;
pub const UrlBuilder = http.UrlBuilder;

test {
    std.testing.refAllDecls(@This());
}
