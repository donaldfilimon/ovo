//! Translation module - Import/Export between build systems
//!
//! Provides bidirectional translation between:
//! - OVO's build.zon format
//! - CMake, Xcode, Visual Studio, Meson, Makefile
//! - Package managers: vcpkg, Conan

const std = @import("std");

// Main translation engine
pub const engine = @import("engine.zig");
pub const TranslationEngine = engine.Engine;
pub const TranslationOptions = engine.TranslationOptions;
pub const BuildFormat = engine.BuildFormat;

// Importers
pub const importers = struct {
    pub const cmake = @import("importers/cmake.zig");
    pub const xcode = @import("importers/xcode.zig");
    pub const msbuild = @import("importers/msbuild.zig");
    pub const meson = @import("importers/meson.zig");
    pub const makefile = @import("importers/makefile.zig");
    pub const vcpkg_manifest = @import("importers/vcpkg_manifest.zig");
    pub const conan_manifest = @import("importers/conan_manifest.zig");
};

// Exporters
pub const exporters = struct {
    pub const cmake = @import("exporters/cmake.zig");
    pub const xcode = @import("exporters/xcode.zig");
    pub const msbuild = @import("exporters/msbuild.zig");
    pub const ninja = @import("exporters/ninja.zig");
};

// Re-export common types
pub const CMakeParser = importers.cmake.CMakeParser;
pub const XcodeParser = importers.xcode.XcodeParser;
pub const MSBuildParser = importers.msbuild.MSBuildParser;
pub const MesonParser = importers.meson.MesonParser;

pub const CMakeGenerator = exporters.cmake.CMakeGenerator;
pub const XcodeGenerator = exporters.xcode.XcodeGenerator;
pub const MSBuildGenerator = exporters.msbuild.MSBuildGenerator;
pub const NinjaGenerator = exporters.ninja.NinjaGenerator;

test {
    std.testing.refAllDecls(@This());
}
