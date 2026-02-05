//! Build orchestration engine for the ovo package manager.
//!
//! Coordinates compilation, dependency resolution, parallel task execution,
//! and incremental build caching.

pub const engine = @import("engine.zig");
pub const graph = @import("graph.zig");
pub const scheduler = @import("scheduler.zig");
pub const cache = @import("cache.zig");
pub const artifacts = @import("artifacts.zig");

// Re-export commonly used types
pub const BuildEngine = engine.BuildEngine;
pub const BuildOptions = engine.BuildOptions;
pub const BuildResult = engine.BuildResult;

pub const BuildGraph = graph.BuildGraph;
pub const BuildNode = graph.BuildNode;
pub const NodeKind = graph.NodeKind;

pub const TaskScheduler = scheduler.TaskScheduler;

pub const BuildCache = cache.BuildCache;
pub const CacheEntry = cache.CacheEntry;

pub const ArtifactManager = artifacts.ArtifactManager;

test {
    @import("std").testing.refAllDecls(@This());
}
