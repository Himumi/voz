const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const root = @import("root.zig");
const Config = root.Config;
const Context = root.Context;

const zig_temp = "zig_temp";

pub fn run(ctx: *Context, config: Config, raw_version: []const u8) !void {
    const cwd = Io.Dir.cwd();

    // Validate the selected version binary existence.
    if (!try dirExists(ctx.io, raw_version))
        return try ctx.stderr.print("Not found {s} version binary\n", .{raw_version});

    // Backup the target version.
    try cwd.rename(raw_version, cwd, zig_temp, ctx.io);

    // Delete after all operations.
    defer cwd.deleteTree(ctx.io, zig_temp) catch {};

    // Validate the selected version exists in 'Config.locals'.
    const local_version = getLocalVersion(config.locals, raw_version) orelse
        return try ctx.stderr.print("Not found {s} version in config\n", .{raw_version});
    errdefer cleanUp(ctx.io, config, raw_version, local_version) catch {};

    var locals: std.ArrayList([]const u8) = try .initCapacity(ctx.allocator, config.locals.len - 1);
    defer locals.deinit(ctx.allocator);

    // Remove the selected version from 'Config.locals'.
    for (config.locals) |version| {
        if (mem.eql(u8, version, local_version)) continue;
        try locals.append(ctx.allocator, version);
    }

    var temp_config = config;
    temp_config.locals = locals.items;

    // When the selected version is a using version.
    if (mem.eql(u8, temp_config.zig, local_version)) {
        cwd.deleteFile(ctx.io, root.bin_file) catch |err| switch (err) {
            error.FileNotFound => return try ctx.stderr.print("Not found bin file\n", .{}),
            else => return err,
        };

        const version = if (locals.items.len == 0)
            ""
        else if (root.isMaster(locals.getLast()))
            "master"
        else
            locals.getLast();

        // Create a new link to the latest version.
        if (version.len > 0) {
            try cwd.symLink(ctx.io, version, root.bin_file, .{ .is_directory = true });
        }
        temp_config.zig = version;
    }

    // Update the config to the config file.
    try temp_config.write(ctx.io);

    try ctx.stderr.print("Deleted {s} version\n", .{raw_version});
}

fn dirExists(io: Io, path: []const u8) !bool {
    const cwd = Io.Dir.cwd();
    const dir = cwd.openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    dir.close(io);

    return true;
}

fn fileExists(io: Io, path: []const u8) !bool {
    const cwd = Io.Dir.cwd();

    const file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);

    return true;
}

fn getLocalVersion(local_versions: []const []const u8, raw_version: []const u8) ?[]const u8 {
    for (local_versions) |version| {
        const temp_version = if (root.isMaster(version)) "master" else version;
        if (mem.eql(u8, temp_version, raw_version)) return version;
    }
    return null;
}

fn cleanUp(
    io: Io,
    config: Config,
    raw_version: []const u8,
    local_version: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    if (mem.eql(u8, config.zig, local_version)) {
        const result = cwd.openFile(io, root.bin_file, .{});
        if (result) |file| {
            file.close(io);
            try cwd.deleteFile(io, root.bin_file);
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
        try cwd.symLink(io, raw_version, root.bin_file, .{ .is_directory = true });
    }
    try cwd.rename(zig_temp, cwd, raw_version, io);
    try config.write(io);
}
