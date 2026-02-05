//! Ovo Package Management System
//!
//! A decentralized package manager for Zig with support for multiple sources:
//! - Git repositories (default)
//! - Archives (tar.gz, zip)
//! - Local paths
//! - vcpkg packages (C/C++ ecosystem)
//! - Conan packages (C/C++ ecosystem)
//! - System libraries (pkg-config)
//! - Future: central registry
//!
//! Features:
//! - Decentralized by default (git URLs, paths)
//! - vcpkg/Conan integration for C++ ecosystem
//! - Lockfile for reproducible builds (ovo.lock)
//! - Fallback support (system lib not found -> fetch it)
//! - Transitive dependency resolution
//! - Cycle detection and version conflict resolution

const std = @import("std");

// Core modules
pub const integrity = @import("integrity.zig");
pub const lockfile = @import("lockfile.zig");
pub const registry = @import("registry.zig");
pub const resolver = @import("resolver.zig");
pub const fetcher = @import("fetcher.zig");
pub const package = @import("package.zig");

// Source modules
pub const sources = struct {
    pub const git = @import("sources/git.zig");
    pub const archive = @import("sources/archive.zig");
    pub const path = @import("sources/path.zig");
    pub const vcpkg = @import("sources/vcpkg.zig");
    pub const conan = @import("sources/conan.zig");
    pub const system = @import("sources/system.zig");
};

// Re-export commonly used types from core modules
pub const Hash = integrity.Hash;
pub const HashString = integrity.HashString;
pub const hashBytes = integrity.hashBytes;
pub const hashFile = integrity.hashFile;
pub const hashToString = integrity.hashToString;
pub const stringToHash = integrity.stringToHash;
pub const verifyBytes = integrity.verifyBytes;
pub const verifyFile = integrity.verifyFile;

pub const Lockfile = lockfile.Lockfile;
pub const LockedPackage = lockfile.LockedPackage;
pub const SourceType = lockfile.SourceType;

pub const Registry = registry.Registry;
pub const RegistryConfig = registry.RegistryConfig;
pub const PackageMetadata = registry.PackageMetadata;

pub const Resolver = resolver.Resolver;
pub const Dependency = resolver.Dependency;
pub const ResolvedPackage = resolver.ResolvedPackage;
pub const ResolutionResult = resolver.ResolutionResult;
pub const ResolveOptions = resolver.ResolveOptions;

pub const Fetcher = fetcher.Fetcher;
pub const FetchResult = fetcher.FetchResult;
pub const FetchOptions = fetcher.FetchOptions;
pub const CacheConfig = fetcher.CacheConfig;

pub const PackageManager = package.PackageManager;
pub const Config = package.Config;
pub const parseDependencyString = package.parseDependencyString;

// Re-export commonly used types from source modules
pub const GitSource = sources.git.GitSource;
pub const GitConfig = sources.git.GitConfig;
pub const CloneResult = sources.git.CloneResult;

pub const ArchiveSource = sources.archive.ArchiveSource;
pub const ArchiveConfig = sources.archive.ArchiveConfig;
pub const ArchiveFormat = sources.archive.ArchiveFormat;

pub const PathSource = sources.path.PathSource;
pub const PathConfig = sources.path.PathConfig;
pub const WorkspaceResolver = sources.path.WorkspaceResolver;

pub const VcpkgSource = sources.vcpkg.VcpkgSource;
pub const Triplet = sources.vcpkg.Triplet;
pub const PackageSpec = sources.vcpkg.PackageSpec;
pub const VcpkgBuildInfo = sources.vcpkg.BuildInfo;

pub const ConanSource = sources.conan.ConanSource;
pub const PackageReference = sources.conan.PackageReference;
pub const ConanSettings = sources.conan.Settings;
pub const ConanBuildInfo = sources.conan.BuildInfo;

pub const SystemSource = sources.system.SystemSource;
pub const LibraryInfo = sources.system.LibraryInfo;
pub const DetectConfig = sources.system.DetectConfig;

// Test all modules
test {
    std.testing.refAllDecls(@This());
}
