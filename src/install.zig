const builtin = @import("builtin");
const std = @import("std");
const fmt = std.fmt;
const json = std.json;
const mem = std.mem;
const tar = std.tar;
const Io = std.Io;

const cli = @import("cli.zig");
const root = @import("root.zig");
const Command = cli.Command;
const Context = root.Context;
const Config = root.Config;

pub fn run(ctx: *Context, config: Config, command: Command) !void {
    const cwd = Io.Dir.cwd();
    const version = command.version.?;

    const zig_str = try root.readFile(ctx.allocator, ctx.io, root.zig_file);
    defer ctx.allocator.free(zig_str);

    // It borrows string memory.
    const zig = try json.parseFromSlice(json.Value, ctx.allocator, zig_str, .{});
    defer zig.deinit();

    const zig_target = zig.value.object.get(version) orelse {
        return try ctx.stderr.print("not found version: {s}\n", .{version});
    };

    const target_version = blk: {
        if (mem.eql(u8, version, "master")) {
            break :blk zig_target.object.get("version").?.string;
        }
        break :blk version;
    };

    const has_installed = try hasInstalled(ctx.io, config, command);
    const is_outdated = isOutdated(config, zig.value, version);

    if (has_installed) {
        if (!(is_outdated or command.options.force)) {
            return try ctx.stderr.print("has already installed: {s}\n", .{target_version});
        }
        try cwd.deleteTree(ctx.io, version);
    }

    cwd.deleteFile(ctx.io, root.bin_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var queue_buffer: [8][]const u8 = undefined;
    var queue: Io.Queue([]const u8) = .init(&queue_buffer);
    defer queue.close(ctx.io);

    var load_screen = ctx.io.async(loadScreen, .{ ctx.io, ctx.stderr, &queue });
    defer load_screen.cancel(ctx.io) catch {};

    // TODO: Need clean up, checksum, and minisign handlers.
    var zig_async = ctx.io.async(handleZig, .{ ctx, zig_target, &queue });
    defer zig_async.cancel(ctx.io) catch {};

    var zls_async = ctx.io.async(handleZls, .{ ctx, command, &queue });
    defer _ = zls_async.cancel(ctx.io) catch {};

    try zig_async.await(ctx.io);
    const zls_result = try zls_async.await(ctx.io);

    try moveZig(ctx.io, version, target_version);
    if (zls_result) try moveZls(ctx.io, target_version);

    try cwd.symLink(ctx.io, version, root.bin_file, .{ .is_directory = true });
    try updateConfig(ctx, config, target_version);

    try ctx.stderr.print("Successfully installed {s}\n", .{target_version});
}

fn hasInstalled(io: Io, config: Config, command: Command) !bool {
    const cwd = Io.Dir.cwd();
    const version = command.version.?;

    // - Check version availability.
    if (root.containsString(config.locals, version)) return true;

    const dir = cwd.openDir(io, version, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);

    return true;
}

fn isOutdated(config: Config, zig: json.Value, version: []const u8) bool {
    if (!mem.eql(u8, version, "master")) return false;

    const master_version = zig.object.get("master").?.object.get("version").?.string;
    for (config.locals) |local_version| {
        if (!isMaster(local_version)) continue;
        return mem.order(u8, local_version, master_version) == .lt;
    }

    // It does not have a master "dev" version.
    return true;
}

fn loadScreen(io: Io, writer: *Io.Writer, message_queue: *Io.Queue([]const u8)) !void {
    while (true) {
        const message = message_queue.getOne(io) catch return;
        try writer.writeAll(message);
        try writer.flush();
    }
}

fn handleZig(ctx: *Context, zig_target: json.Value, message_queue: *Io.Queue([]const u8)) !void {
    var arch_buffer: [56]u8 = undefined;
    const arch_os = try bufPrintArchOs(&arch_buffer);

    const tarball_url = zig_target.object.get(arch_os).?.object.get("tarball").?.string;

    var response: Io.Writer.Allocating = .init(ctx.allocator);
    defer response.deinit();

    try message_queue.putOne(ctx.io, "Downloading zig...\n");

    const result = try root.httpGet(ctx.allocator, ctx.io, &response.writer, tarball_url);
    if (result.status.class() != .success) return error.FailedGetRequest;

    try message_queue.putAll(ctx.io, &.{
        "Download zig complete!\n",
        "Extracting zig...\n",
    });

    try extractFromSlice(ctx, Io.Dir.cwd(), response.written());
    try message_queue.putOne(ctx.io, "Extraction zig complete!\n");
}

fn handleZls(ctx: *Context, command: Command, message_queue: *Io.Queue([]const u8)) !bool {
    var arch_buffer: [56]u8 = undefined;
    const arch_os = try bufPrintArchOs(&arch_buffer);

    if (command.options.no_zls) return false;
    const version = command.version.?;

    const zls_str = try root.readFile(ctx.allocator, ctx.io, root.zls_file);
    defer ctx.allocator.free(zls_str);

    const zls = try json.parseFromSlice(json.Value, ctx.allocator, zls_str, .{});
    defer zls.deinit();

    const zls_target = zls.value.object.get(version) orelse return false;
    const tarball_url = zls_target.object.get(arch_os).?.object.get("tarball").?.string;

    var response: Io.Writer.Allocating = .init(ctx.allocator);
    defer response.deinit();

    try message_queue.putOne(ctx.io, "Downloading zls...\n");

    const zls_result = try root.httpGet(ctx.allocator, ctx.io, &response.writer, tarball_url);
    if (zls_result.status.class() != .success) return error.FailedGetRequest;

    const cwd = Io.Dir.cwd();
    try cwd.createDir(ctx.io, "zls_temp", .default_dir);

    const temp_dir = try cwd.openDir(ctx.io, "zls_temp", .{});
    defer temp_dir.close(ctx.io);

    try message_queue.putAll(ctx.io, &.{
        "Download zls complete!\n",
        "Extracting zls...\n",
    });

    try extractFromSlice(ctx, temp_dir, response.written());
    try message_queue.putOne(ctx.io, "Extraction zls complete!\n");

    return true;
}

fn updateConfig(ctx: *Context, config: Config, target_version: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var temp = config;

    temp.zig = target_version;

    var versions: std.ArrayList([]const u8) = .empty;
    defer versions.deinit(ctx.allocator);

    try versions.appendSlice(ctx.allocator, config.locals);
    blk: {
        for (config.locals, 0..) |version, index| {
            // Break if it has a same version.
            if (mem.eql(u8, version, target_version)) break :blk;

            if (!isMaster(version)) continue;
            if (!isMaster(target_version)) continue;

            // Replace the "dev" version with a new version.
            versions.items[index] = target_version;
            break :blk;
        }

        // Append a new version at the end list.
        try versions.append(ctx.allocator, target_version);
    }
    mem.sort([]const u8, versions.items, {}, lessThanByString);

    // Replace the previous with the new versions.
    temp.locals = versions.items;

    // Update config file.
    const config_file = try cwd.createFile(ctx.io, root.config_file, .{ .truncate = true });
    defer config_file.close(ctx.io);

    var buffer: [1024]u8 = undefined;
    var config_writer = config_file.writer(ctx.io, &buffer);

    try temp.write(&config_writer.interface);
}

fn moveZig(io: Io, version: []const u8, target_version: []const u8) !void {
    var dir_buffer: [128]u8 = undefined;
    const dir_name = try fmt.bufPrint(&dir_buffer, "zig-{s}-{s}-{s}", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        target_version,
    });

    try move(io, dir_name, version);
}

// Move the zls to zig directory.
fn moveZls(io: Io, target_version: []const u8) !void {
    var buffer: [56]u8 = undefined;
    const new_path = try fmt.bufPrint(&buffer, "{s}/zls", .{target_version});

    try move(io, "zls_temp/zls", new_path);

    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io, "zls_temp");
}

/// Minimal buffer size is 56.
fn bufPrintArchOs(buffer: []u8) ![]const u8 {
    return try fmt.bufPrint(buffer, "{s}-{s}", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
    });
}

fn extractFromSlice(ctx: *Context, target: Io.Dir, source: []const u8) !void {
    var reader: Io.Reader = .fixed(source);
    var decommpressor: std.compress.xz.Decompress = try .init(&reader, ctx.allocator, &.{});
    defer decommpressor.deinit();

    try tar.extract(ctx.io, target, &decommpressor.reader, .{ .mode_mode = .executable_bit_only });
}

fn isMaster(raw_version: []const u8) bool {
    return mem.findAny(u8, raw_version, "dev") != null;
}

fn lessThanByString(context: void, lhs: []const u8, rhs: []const u8) bool {
    _ = context;
    return mem.order(u8, lhs, rhs) == .lt;
}

fn move(io: Io, old_path: []const u8, new_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.rename(old_path, cwd, new_path, io);
}
