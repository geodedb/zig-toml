// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Configuration File Loader Example
//!
//! Demonstrates common patterns for loading configuration files:
//! - Reading TOML from a file
//! - Mapping TOML values to Zig structs
//! - Providing default values
//! - Validating configuration

const std = @import("std");
const toml = @import("toml");

/// Application configuration structure
const Config = struct {
    app_name: []const u8,
    version: []const u8,
    server: ServerConfig,
    database: DatabaseConfig,
    features: FeatureFlags,
};

const ServerConfig = struct {
    host: []const u8,
    port: u16,
    workers: u16,
    max_connections: u32,
};

const DatabaseConfig = struct {
    url: []const u8,
    pool_size: u16,
    timeout_seconds: u32,
};

const FeatureFlags = struct {
    enable_cache: bool,
    enable_metrics: bool,
    enable_tracing: bool,
};

/// Load configuration from a TOML document
fn loadConfig(doc: *const toml.Document) !Config {
    var config: Config = undefined;

    // Top-level values
    config.app_name = if (doc.root.get("name")) |v| v.string else "unnamed";
    config.version = if (doc.root.get("version")) |v| v.string else "0.0.0";

    // Server configuration with defaults
    if (doc.root.get("server")) |server| {
        config.server = .{
            .host = if (server.get("host")) |v| v.string else "127.0.0.1",
            .port = if (server.get("port")) |v| @intCast(v.integer) else 8080,
            .workers = if (server.get("workers")) |v| @intCast(v.integer) else 4,
            .max_connections = if (server.get("max_connections")) |v| @intCast(v.integer) else 1000,
        };
    } else {
        // Default server config
        config.server = .{
            .host = "127.0.0.1",
            .port = 8080,
            .workers = 4,
            .max_connections = 1000,
        };
    }

    // Database configuration with defaults
    if (doc.root.get("database")) |db| {
        config.database = .{
            .url = if (db.get("url")) |v| v.string else "sqlite://data.db",
            .pool_size = if (db.get("pool_size")) |v| @intCast(v.integer) else 10,
            .timeout_seconds = if (db.get("timeout_seconds")) |v| @intCast(v.integer) else 30,
        };
    } else {
        config.database = .{
            .url = "sqlite://data.db",
            .pool_size = 10,
            .timeout_seconds = 30,
        };
    }

    // Feature flags with defaults (all disabled by default)
    if (doc.root.get("features")) |features| {
        config.features = .{
            .enable_cache = if (features.get("cache")) |v| v.bool else false,
            .enable_metrics = if (features.get("metrics")) |v| v.bool else false,
            .enable_tracing = if (features.get("tracing")) |v| v.bool else false,
        };
    } else {
        config.features = .{
            .enable_cache = false,
            .enable_metrics = false,
            .enable_tracing = false,
        };
    }

    return config;
}

/// Validate configuration values
fn validateConfig(config: *const Config) !void {
    // Validate port range
    if (config.server.port == 0) {
        return error.InvalidPort;
    }

    // Validate workers
    if (config.server.workers == 0 or config.server.workers > 256) {
        return error.InvalidWorkerCount;
    }

    // Validate pool size
    if (config.database.pool_size == 0 or config.database.pool_size > 1000) {
        return error.InvalidPoolSize;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Example: Load from embedded TOML string
    // In production, you would read from a file:
    //   const content = try std.fs.cwd().readFileAlloc(allocator, "config.toml", 1024 * 1024);
    //   defer allocator.free(content);

    const config_toml =
        \\name = "MyService"
        \\version = "2.1.0"
        \\
        \\[server]
        \\host = "0.0.0.0"
        \\port = 3000
        \\workers = 8
        \\max_connections = 5000
        \\
        \\[database]
        \\url = "postgres://user:pass@localhost:5432/production"
        \\pool_size = 25
        \\timeout_seconds = 60
        \\
        \\[features]
        \\cache = true
        \\metrics = true
        \\tracing = false
    ;

    // Parse the TOML document
    var doc = try toml.parse(allocator, config_toml, .{});
    defer doc.deinit();

    // Load configuration into struct
    const config = try loadConfig(&doc);

    // Validate configuration
    try validateConfig(&config);

    // Print loaded configuration
    try stdout.print("=== Configuration Loaded Successfully ===\n\n", .{});
    try stdout.print("Application: {s} v{s}\n\n", .{ config.app_name, config.version });

    try stdout.print("Server:\n", .{});
    try stdout.print("  Host: {s}\n", .{config.server.host});
    try stdout.print("  Port: {d}\n", .{config.server.port});
    try stdout.print("  Workers: {d}\n", .{config.server.workers});
    try stdout.print("  Max Connections: {d}\n", .{config.server.max_connections});

    try stdout.print("\nDatabase:\n", .{});
    try stdout.print("  URL: {s}\n", .{config.database.url});
    try stdout.print("  Pool Size: {d}\n", .{config.database.pool_size});
    try stdout.print("  Timeout: {d}s\n", .{config.database.timeout_seconds});

    try stdout.print("\nFeatures:\n", .{});
    try stdout.print("  Cache: {}\n", .{config.features.enable_cache});
    try stdout.print("  Metrics: {}\n", .{config.features.enable_metrics});
    try stdout.print("  Tracing: {}\n", .{config.features.enable_tracing});
}
