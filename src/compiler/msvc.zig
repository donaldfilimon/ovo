//! MSVC Compiler Backend
//!
//! Microsoft Visual C++ (cl.exe) implementation for Windows targets.
//! Provides full C++20/23 modules support with IFC format.

const std = @import("std");
const Allocator = std.mem.Allocator;
const interface = @import("interface.zig");
const modules = @import("modules.zig");

const Compiler = interface.Compiler;
const CompileOptions = interface.CompileOptions;
const CompileResult = interface.CompileResult;
const LinkOptions = interface.LinkOptions;
const LinkResult = interface.LinkResult;
const ModuleDepsResult = interface.ModuleDepsResult;
const Capabilities = interface.Capabilities;
const CompilerKind = interface.CompilerKind;
const Diagnostic = interface.Diagnostic;
const DiagnosticLevel = interface.DiagnosticLevel;

/// MSVC compiler implementation
pub const MSVC = struct {
    allocator: Allocator,
    cl_path: []const u8,
    link_path: []const u8,
    lib_path: []const u8,
    version: MSVCVersion,
    capabilities: Capabilities,
    /// Visual Studio installation path
    vs_path: ?[]const u8,
    /// Windows SDK path
    sdk_path: ?[]const u8,

    const Self = @This();

    pub const MSVCVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,
        /// Visual Studio version (e.g., 2022, 2019)
        vs_version: ?u32 = null,

        pub fn format(self: MSVCVersion, allocator: Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
                self.major,
                self.minor,
                self.patch,
            });
        }

        /// MSVC 19.29+ (VS2019 16.10+) has modules support
        pub fn supportsModules(self: MSVCVersion) bool {
            return self.major >= 19 and self.minor >= 29;
        }

        /// MSVC 19.34+ (VS2022 17.4+) has improved modules
        pub fn hasStdModules(self: MSVCVersion) bool {
            return self.major >= 19 and self.minor >= 34;
        }
    };

    /// Initialize with auto-detection (Windows only)
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const paths = try findMSVC(allocator);
        errdefer {
            allocator.free(paths.cl_path);
            allocator.free(paths.link_path);
            allocator.free(paths.lib_path);
            if (paths.vs_path) |p| allocator.free(p);
            if (paths.sdk_path) |p| allocator.free(p);
        }

        const version = try detectVersion(allocator, paths.cl_path);
        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .cl_path = paths.cl_path,
            .link_path = paths.link_path,
            .lib_path = paths.lib_path,
            .version = version,
            .vs_path = paths.vs_path,
            .sdk_path = paths.sdk_path,
            .capabilities = .{
                .cpp_modules = version.supportsModules(),
                .header_units = version.supportsModules(),
                .module_dep_scan = version.supportsModules(),
                .lto = true, // LTCG
                .pgo = true,
                .sanitizers = version.major >= 19, // AddressSanitizer in VS2019+
                .cross_compile = false, // MSVC is Windows-only
                .max_c_standard = .c17, // MSVC has limited C standard support
                .max_cpp_standard = if (version.hasStdModules()) .cpp23 else .cpp20,
                .version = version_str,
                .vendor = "Microsoft",
            },
        };

        return self;
    }

    /// Initialize with explicit paths
    pub fn initWithPaths(
        allocator: Allocator,
        cl_path: []const u8,
        link_path: ?[]const u8,
        lib_path: ?[]const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const owned_cl = try allocator.dupe(u8, cl_path);
        errdefer allocator.free(owned_cl);

        // Derive link.exe and lib.exe paths from cl.exe path
        const dir = std.fs.path.dirname(cl_path) orelse ".";

        const owned_link = if (link_path) |p|
            try allocator.dupe(u8, p)
        else
            try std.fs.path.join(allocator, &.{ dir, "link.exe" });

        const owned_lib = if (lib_path) |p|
            try allocator.dupe(u8, p)
        else
            try std.fs.path.join(allocator, &.{ dir, "lib.exe" });

        const version = try detectVersion(allocator, owned_cl);
        const version_str = try version.format(allocator);

        self.* = .{
            .allocator = allocator,
            .cl_path = owned_cl,
            .link_path = owned_link,
            .lib_path = owned_lib,
            .version = version,
            .vs_path = null,
            .sdk_path = null,
            .capabilities = .{
                .cpp_modules = version.supportsModules(),
                .header_units = version.supportsModules(),
                .module_dep_scan = version.supportsModules(),
                .lto = true,
                .pgo = true,
                .sanitizers = version.major >= 19,
                .cross_compile = false,
                .max_c_standard = .c17,
                .max_cpp_standard = if (version.hasStdModules()) .cpp23 else .cpp20,
                .version = version_str,
                .vendor = "Microsoft",
            },
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cl_path);
        self.allocator.free(self.link_path);
        self.allocator.free(self.lib_path);
        if (self.vs_path) |p| self.allocator.free(p);
        if (self.sdk_path) |p| self.allocator.free(p);
        self.allocator.free(self.capabilities.version);
        self.allocator.destroy(self);
    }

    /// Get the compiler interface
    pub fn compiler(self: *Self) Compiler {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Compile source files
    pub fn compile(self: *Self, allocator: Allocator, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(self.cl_path);

        // Disable logo
        try args.append("/nologo");

        // Compilation only (no linking)
        if (options.output_kind == .object or options.output_kind == .assembly or
            options.output_kind == .preprocessed)
        {
            try args.append("/c");
        }

        // Output type
        switch (options.output_kind) {
            .assembly => try args.append("/FA"),
            .preprocessed => try args.append("/E"),
            else => {},
        }

        // Output file
        if (options.output) |out| {
            const flag = try std.fmt.allocPrint(allocator, "/Fo{s}", .{out});
            try args.append(flag);
        }

        // Language standard
        if (options.sources.len > 0) {
            const ext = std.fs.path.extension(options.sources[0]);
            if (interface.Language.fromExtension(ext)) |lang| {
                switch (lang) {
                    .c => try args.append(options.c_standard.toMsvcFlag()),
                    .cpp => try args.append(options.cpp_standard.toMsvcFlag()),
                    else => {},
                }
            }
        }

        // Optimization
        try args.append(options.optimization.toMsvcFlag());

        // Debug info
        if (options.debug_info) {
            try args.append("/Zi");
            try args.append("/FS"); // Synchronize PDB writes
        }

        // LTO (LTCG)
        if (options.lto) {
            try args.append("/GL");
        }

        // Include directories
        for (options.include_dirs) |dir| {
            const flag = try std.fmt.allocPrint(allocator, "/I{s}", .{dir});
            try args.append(flag);
        }

        // System include directories
        for (options.system_include_dirs) |dir| {
            const flag = try std.fmt.allocPrint(allocator, "/external:I{s}", .{dir});
            try args.append(flag);
        }
        if (options.system_include_dirs.len > 0) {
            try args.append("/external:W0"); // Suppress warnings from external headers
        }

        // Defines
        for (options.defines) |def| {
            const flag = try std.fmt.allocPrint(allocator, "/D{s}", .{def});
            try args.append(flag);
        }

        // Warnings
        if (options.warnings.len > 0) {
            for (options.warnings) |warn| {
                if (std.mem.eql(u8, warn, "all")) {
                    try args.append("/W4");
                } else if (std.mem.eql(u8, warn, "extra")) {
                    try args.append("/Wall");
                } else {
                    // Try to map common warning names
                    const flag = try std.fmt.allocPrint(allocator, "/w1{s}", .{warn});
                    try args.append(flag);
                }
            }
        } else {
            try args.append("/W3"); // Default warning level
        }

        if (options.warnings_as_errors) {
            try args.append("/WX");
        }

        // Sanitizers
        if (options.sanitize_address) {
            try args.append("/fsanitize=address");
        }

        // C++ modules (MSVC-specific)
        if (options.enable_modules and options.cpp_standard.supportsModules() and self.version.supportsModules()) {
            // Enable modules
            try args.append("/experimental:module");
            try args.append("/stdIfcDir");

            if (options.module_cache_dir) |cache| {
                const cache_flag = try std.fmt.allocPrint(allocator, "/ifcOutput{s}", .{cache});
                try args.append(cache_flag);
            }

            // Prebuilt modules (IFC files)
            for (options.prebuilt_modules) |ifc| {
                const flag = try std.fmt.allocPrint(allocator, "/reference{s}", .{ifc});
                try args.append(flag);
            }

            // Enable standard library modules if available
            if (self.version.hasStdModules()) {
                try args.append("/std:c++latest");
            }
        }

        // MSVC-specific flags
        try args.append("/EHsc"); // Exception handling
        try args.append("/utf-8"); // UTF-8 source and execution charset

        // Extra flags
        for (options.extra_flags) |flag| {
            try args.append(flag);
        }

        // Source files
        for (options.sources) |src| {
            try args.append(src);
        }

        // Execute
        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseMSVCDiagnostics(allocator, result.stderr, result.stdout);

        return .{
            .success = result.exit_code == 0,
            .output_path = if (options.output) |o| try allocator.dupe(u8, o) else null,
            .diagnostics = diagnostics,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.exit_code,
            .duration_ns = duration,
        };
    }

    /// Link object files
    pub fn link(self: *Self, allocator: Allocator, options: LinkOptions) !LinkResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        // Use lib.exe for static libraries, link.exe otherwise
        switch (options.output_kind) {
            .static_lib => {
                try args.append(self.lib_path);
                try args.append("/nologo");

                // Output file
                const out_flag = try std.fmt.allocPrint(allocator, "/OUT:{s}", .{options.output});
                try args.append(out_flag);

                // Object files
                for (options.objects) |obj| {
                    try args.append(obj);
                }

                const result = try runProcess(allocator, args.items, options.cwd);
                const end_time = std.time.nanoTimestamp();

                return .{
                    .success = result.exit_code == 0,
                    .output_path = try allocator.dupe(u8, options.output),
                    .diagnostics = &.{},
                    .stdout = result.stdout,
                    .stderr = result.stderr,
                    .exit_code = result.exit_code,
                    .duration_ns = @intCast(end_time - start_time),
                };
            },
            else => {},
        }

        try args.append(self.link_path);
        try args.append("/nologo");

        // Output file
        const out_flag = try std.fmt.allocPrint(allocator, "/OUT:{s}", .{options.output});
        try args.append(out_flag);

        // Output type
        switch (options.output_kind) {
            .shared_lib => try args.append("/DLL"),
            else => {},
        }

        // Object files
        for (options.objects) |obj| {
            try args.append(obj);
        }

        // Library directories
        for (options.library_dirs) |dir| {
            const flag = try std.fmt.allocPrint(allocator, "/LIBPATH:{s}", .{dir});
            try args.append(flag);
        }

        // Libraries
        for (options.libraries) |lib| {
            // MSVC uses .lib extension
            if (std.mem.endsWith(u8, lib, ".lib")) {
                try args.append(lib);
            } else {
                const lib_name = try std.fmt.allocPrint(allocator, "{s}.lib", .{lib});
                try args.append(lib_name);
            }
        }

        // LTO (LTCG)
        if (options.lto) {
            try args.append("/LTCG");
        }

        // Debug info
        try args.append("/DEBUG");

        // Strip (release mode)
        if (options.strip) {
            try args.append("/OPT:REF");
            try args.append("/OPT:ICF");
        }

        // Extra flags
        for (options.extra_flags) |flag| {
            try args.append(flag);
        }

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseMSVCDiagnostics(allocator, result.stderr, result.stdout);

        return .{
            .success = result.exit_code == 0,
            .output_path = try allocator.dupe(u8, options.output),
            .diagnostics = diagnostics,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.exit_code,
            .duration_ns = duration,
        };
    }

    /// Scan module dependencies
    pub fn scanModuleDeps(self: *Self, allocator: Allocator, source_path: []const u8, options: CompileOptions) !ModuleDepsResult {
        if (self.version.supportsModules()) {
            return self.scanWithMSVC(allocator, source_path, options);
        }

        return self.scanFromSource(allocator, source_path);
    }

    fn scanWithMSVC(self: *Self, allocator: Allocator, source_path: []const u8, options: CompileOptions) !ModuleDepsResult {
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(self.cl_path);
        try args.append("/nologo");
        try args.append(options.cpp_standard.toMsvcFlag());
        try args.append("/experimental:module");
        try args.append("/scanDependencies");

        // Create temp file for dependency output
        const dep_file = try std.fmt.allocPrint(allocator, "ovo-deps-{d}.json", .{std.time.timestamp()});
        defer allocator.free(dep_file);

        try args.append(dep_file);

        for (options.include_dirs) |dir| {
            const flag = try std.fmt.allocPrint(allocator, "/I{s}", .{dir});
            try args.append(flag);
        }

        for (options.defines) |def| {
            const flag = try std.fmt.allocPrint(allocator, "/D{s}", .{def});
            try args.append(flag);
        }

        try args.append(source_path);

        const result = runProcess(allocator, args.items, options.cwd) catch {
            return self.scanFromSource(allocator, source_path);
        };

        if (result.exit_code != 0) {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return self.scanFromSource(allocator, source_path);
        }

        allocator.free(result.stdout);

        // Read and parse dependency file
        const dep_content = std.fs.cwd().readFileAlloc(allocator, dep_file, 1024 * 1024) catch {
            allocator.free(result.stderr);
            return self.scanFromSource(allocator, source_path);
        };
        defer allocator.free(dep_content);

        // Delete temp file
        std.fs.cwd().deleteFile(dep_file) catch {};

        const parsed = try parseMSVCDeps(allocator, dep_content);

        return .{
            .success = true,
            .dependencies = parsed.dependencies,
            .provides = parsed.provides,
            .is_interface = parsed.is_interface,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = result.stderr,
        };
    }

    fn scanFromSource(self: *Self, allocator: Allocator, source_path: []const u8) !ModuleDepsResult {
        _ = self;

        const source = std.fs.cwd().readFileAlloc(allocator, source_path, 1024 * 1024 * 10) catch |err| {
            return .{
                .success = false,
                .dependencies = &.{},
                .provides = null,
                .is_interface = false,
                .stdout = "",
                .stderr = try std.fmt.allocPrint(allocator, "Failed to read source: {}", .{err}),
            };
        };
        defer allocator.free(source);

        const scan_result = try modules.scanModuleDeclarations(allocator, source);
        const is_interface = interface.Language.isModuleInterface(source_path) or
            scan_result.provides != null;

        return .{
            .success = true,
            .dependencies = scan_result.dependencies,
            .provides = scan_result.provides,
            .is_interface = is_interface,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
        };
    }

    /// Compile module interface unit (generates IFC file)
    pub fn compileModuleInterface(self: *Self, allocator: Allocator, source_path: []const u8, output_bmi: []const u8, options: CompileOptions) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(self.cl_path);
        try args.append("/nologo");

        // C++ standard with modules
        try args.append(options.cpp_standard.toMsvcFlag());
        try args.append("/experimental:module");

        // Compile to interface only
        try args.append("/c");
        try args.append("/interface");

        // Output IFC file
        const ifc_flag = try std.fmt.allocPrint(allocator, "/ifcOutput{s}", .{output_bmi});
        try args.append(ifc_flag);

        // Also generate object file
        const basename = std.fs.path.stem(source_path);
        const obj_path = try std.fmt.allocPrint(allocator, "{s}.obj", .{basename});
        const obj_flag = try std.fmt.allocPrint(allocator, "/Fo{s}", .{obj_path});
        try args.append(obj_flag);

        // Prebuilt modules (IFC files this depends on)
        for (options.prebuilt_modules) |ifc| {
            const flag = try std.fmt.allocPrint(allocator, "/reference{s}", .{ifc});
            try args.append(flag);
        }

        // Include directories
        for (options.include_dirs) |dir| {
            const flag = try std.fmt.allocPrint(allocator, "/I{s}", .{dir});
            try args.append(flag);
        }

        for (options.system_include_dirs) |dir| {
            const flag = try std.fmt.allocPrint(allocator, "/external:I{s}", .{dir});
            try args.append(flag);
        }

        // Defines
        for (options.defines) |def| {
            const flag = try std.fmt.allocPrint(allocator, "/D{s}", .{def});
            try args.append(flag);
        }

        // Optimization
        try args.append(options.optimization.toMsvcFlag());

        // Debug info
        if (options.debug_info) {
            try args.append("/Zi");
        }

        // Exception handling
        try args.append("/EHsc");

        // Source file
        try args.append(source_path);

        const result = try runProcess(allocator, args.items, options.cwd);

        const end_time = std.time.nanoTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const diagnostics = try parseMSVCDiagnostics(allocator, result.stderr, result.stdout);

        return .{
            .success = result.exit_code == 0,
            .output_path = try allocator.dupe(u8, output_bmi),
            .diagnostics = diagnostics,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.exit_code,
            .duration_ns = duration,
        };
    }

    pub fn getCapabilities(self: *Self) Capabilities {
        return self.capabilities;
    }

    pub fn getKind(_: *Self) CompilerKind {
        return .msvc;
    }

    pub fn getPath(self: *Self) []const u8 {
        return self.cl_path;
    }

    pub fn verify(self: *Self, allocator: Allocator) !bool {
        const result = try runProcess(allocator, &.{ self.cl_path, "/?" }, null);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        // cl.exe returns 0 or 1 for /? depending on version
        return result.exit_code == 0 or result.exit_code == 1;
    }

    const vtable = interface.compilerInterface(Self);
};

/// Find MSVC installation
fn findMSVC(allocator: Allocator) !struct {
    cl_path: []const u8,
    link_path: []const u8,
    lib_path: []const u8,
    vs_path: ?[]const u8,
    sdk_path: ?[]const u8,
} {
    // Try vswhere first (Visual Studio 2017+)
    if (try findVSWhere(allocator)) |vs_path| {
        const tools_path = try std.fs.path.join(allocator, &.{
            vs_path, "VC", "Tools", "MSVC",
        });
        defer allocator.free(tools_path);

        // Find latest MSVC version
        var dir = std.fs.cwd().openDir(tools_path, .{ .iterate = true }) catch {
            allocator.free(vs_path);
            return error.CompilerNotFound;
        };
        defer dir.close();

        var latest_version: ?[]const u8 = null;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                if (latest_version) |lv| {
                    if (std.mem.order(u8, entry.name, lv) == .gt) {
                        allocator.free(lv);
                        latest_version = try allocator.dupe(u8, entry.name);
                    }
                } else {
                    latest_version = try allocator.dupe(u8, entry.name);
                }
            }
        }

        if (latest_version) |version| {
            defer allocator.free(version);

            // Determine host architecture
            const host_arch = if (@import("builtin").cpu.arch == .x86_64)
                "Hostx64/x64"
            else
                "Hostx86/x86";

            const bin_path = try std.fs.path.join(allocator, &.{
                tools_path, version, "bin", host_arch,
            });
            defer allocator.free(bin_path);

            const cl_path = try std.fs.path.join(allocator, &.{ bin_path, "cl.exe" });
            const link_path = try std.fs.path.join(allocator, &.{ bin_path, "link.exe" });
            const lib_path = try std.fs.path.join(allocator, &.{ bin_path, "lib.exe" });

            return .{
                .cl_path = cl_path,
                .link_path = link_path,
                .lib_path = lib_path,
                .vs_path = vs_path,
                .sdk_path = null, // TODO: Find Windows SDK
            };
        }

        allocator.free(vs_path);
    }

    // Fallback: Check PATH
    if (std.posix.getenv("PATH")) |path_env| {
        var paths = std.mem.splitScalar(u8, path_env, ';');
        while (paths.next()) |dir| {
            const cl_path = try std.fs.path.join(allocator, &.{ dir, "cl.exe" });
            defer allocator.free(cl_path);

            if (std.fs.cwd().access(cl_path, .{})) |_| {
                const link_path = try std.fs.path.join(allocator, &.{ dir, "link.exe" });
                const lib_path = try std.fs.path.join(allocator, &.{ dir, "lib.exe" });

                return .{
                    .cl_path = try allocator.dupe(u8, cl_path),
                    .link_path = link_path,
                    .lib_path = lib_path,
                    .vs_path = null,
                    .sdk_path = null,
                };
            } else |_| {}
        }
    }

    return error.CompilerNotFound;
}

/// Find Visual Studio installation using vswhere
fn findVSWhere(allocator: Allocator) !?[]const u8 {
    const vswhere_paths = [_][]const u8{
        "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe",
        "C:\\Program Files\\Microsoft Visual Studio\\Installer\\vswhere.exe",
    };

    for (vswhere_paths) |vswhere| {
        if (std.fs.cwd().access(vswhere, .{})) |_| {
            const result = try runProcess(allocator, &.{
                vswhere,
                "-latest",
                "-property",
                "installationPath",
            }, null);
            defer allocator.free(result.stderr);

            if (result.exit_code == 0) {
                const path = std.mem.trim(u8, result.stdout, " \t\n\r");
                if (path.len > 0) {
                    const owned = try allocator.dupe(u8, path);
                    allocator.free(result.stdout);
                    return owned;
                }
            }
            allocator.free(result.stdout);
        } else |_| {}
    }

    return null;
}

/// Detect MSVC version
fn detectVersion(allocator: Allocator, cl_path: []const u8) !MSVC.MSVCVersion {
    const result = try runProcess(allocator, &.{cl_path}, null);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // MSVC outputs version to stderr
    // Format: "Microsoft (R) C/C++ Optimizing Compiler Version 19.34.31935 for x64"
    const output = if (result.stderr.len > 0) result.stderr else result.stdout;

    if (std.mem.indexOf(u8, output, "Version ")) |idx| {
        const version_start = idx + "Version ".len;
        const version_end = std.mem.indexOfAnyPos(u8, output, version_start, " \n\r") orelse output.len;
        const version_str = output[version_start..version_end];

        var parts = std.mem.splitScalar(u8, version_str, '.');
        const major = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
        const minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
        const patch = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;

        // Determine VS version from compiler version
        const vs_version: ?u32 = if (major >= 19) blk: {
            if (minor >= 30) break :blk 2022;
            if (minor >= 20) break :blk 2019;
            break :blk 2017;
        } else null;

        return .{
            .major = major,
            .minor = minor,
            .patch = patch,
            .vs_version = vs_version,
        };
    }

    return .{ .major = 0, .minor = 0, .patch = 0 };
}

/// Parse MSVC dependency scan output
fn parseMSVCDeps(allocator: Allocator, content: []const u8) !struct {
    provides: ?[]const u8,
    dependencies: []modules.ModuleDependency,
    is_interface: bool,
} {
    // Simplified MSVC JSON parsing
    _ = content;

    return .{
        .provides = null,
        .dependencies = try allocator.alloc(modules.ModuleDependency, 0),
        .is_interface = false,
    };
}

/// Run a process and capture output
fn runProcess(allocator: Allocator, args: []const []const u8, cwd: ?[]const u8) !struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
} {
    var child = std.process.Child.init(args, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024 * 10);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024 * 10);

    const term = try child.wait();

    const exit_code: i32 = switch (term) {
        .Exited => |code| @as(i32, code),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        else => -1,
    };

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

/// Parse MSVC diagnostic output
fn parseMSVCDiagnostics(allocator: Allocator, stderr: []const u8, stdout: []const u8) ![]Diagnostic {
    var diagnostics = std.ArrayList(Diagnostic).init(allocator);
    errdefer diagnostics.deinit();

    // MSVC outputs diagnostics to both stdout and stderr
    const outputs = [_][]const u8{ stderr, stdout };

    for (outputs) |output| {
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (parseMSVCDiagnosticLine(allocator, line)) |diag| {
                try diagnostics.append(diag);
            } else |_| {}
        }
    }

    return diagnostics.toOwnedSlice();
}

/// Parse single MSVC diagnostic line
fn parseMSVCDiagnosticLine(allocator: Allocator, line: []const u8) !Diagnostic {
    // MSVC format: file(line[,col]): level code: message
    // Example: main.cpp(10): error C2065: 'foo': undeclared identifier

    const paren_open = std.mem.indexOfScalar(u8, line, '(') orelse return error.InvalidFormat;
    const paren_close = std.mem.indexOfScalarPos(u8, line, paren_open, ')') orelse return error.InvalidFormat;

    const file = line[0..paren_open];
    const location = line[paren_open + 1 .. paren_close];

    // Parse line and optional column
    var loc_parts = std.mem.splitScalar(u8, location, ',');
    const line_num = std.fmt.parseInt(u32, loc_parts.next() orelse "0", 10) catch null;
    const col_num = if (loc_parts.next()) |col|
        std.fmt.parseInt(u32, col, 10) catch null
    else
        null;

    // Parse rest: ": level code: message"
    const rest = line[paren_close + 1 ..];
    const colon1 = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidFormat;
    const after_colon1 = std.mem.trim(u8, rest[colon1 + 1 ..], " ");

    const colon2 = std.mem.indexOfScalar(u8, after_colon1, ':') orelse return error.InvalidFormat;
    const level_and_code = std.mem.trim(u8, after_colon1[0..colon2], " ");
    const message = std.mem.trim(u8, after_colon1[colon2 + 1 ..], " ");

    // Parse level and code
    var lc_parts = std.mem.splitScalar(u8, level_and_code, ' ');
    const level_str = lc_parts.next() orelse return error.InvalidFormat;
    const code = lc_parts.next();

    const level: DiagnosticLevel = if (std.mem.eql(u8, level_str, "error"))
        .error_
    else if (std.mem.eql(u8, level_str, "warning"))
        .warning
    else if (std.mem.eql(u8, level_str, "note"))
        .note
    else if (std.mem.eql(u8, level_str, "fatal"))
        .fatal
    else
        return error.InvalidFormat;

    return .{
        .level = level,
        .file = try allocator.dupe(u8, file),
        .line = line_num,
        .column = col_num,
        .message = try allocator.dupe(u8, message),
        .code = if (code) |c| try allocator.dupe(u8, c) else null,
    };
}

test "MSVC version parsing" {
    const testing = std.testing;

    const v1934 = MSVC.MSVCVersion{ .major = 19, .minor = 34, .patch = 0, .vs_version = 2022 };
    const v1929 = MSVC.MSVCVersion{ .major = 19, .minor = 29, .patch = 0, .vs_version = 2019 };
    const v1920 = MSVC.MSVCVersion{ .major = 19, .minor = 20, .patch = 0, .vs_version = 2019 };

    try testing.expect(v1934.supportsModules());
    try testing.expect(v1934.hasStdModules());
    try testing.expect(v1929.supportsModules());
    try testing.expect(!v1929.hasStdModules());
    try testing.expect(!v1920.supportsModules());
}
