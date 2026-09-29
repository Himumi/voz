const builtin = @import("builtin");
const std = @import("std");
const fmt = std.fmt;
const json = std.json;
const mem = std.mem;
const tar = std.tar;
const xz = std.compress.xz;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cli = @import("cli.zig");
const root = @import("root.zig");
const Command = cli.Command;
const Context = root.Context;
const Config = root.Config;

const zls_temp = "zls_temp";
const arch = builtin.target.cpu.arch;
const os = builtin.target.os.tag;

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
    const target_version = getTargetVersion(zig_target, version);

    const has_installed = try config.hasInstalled(ctx.io, version);
    const is_outdated = config.isOutdated(zig.value, version);

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

    try installBinaries(ctx, zig_target, command);

    try cwd.symLink(ctx.io, version, root.bin_file, .{ .is_directory = true });
    try config.update(ctx, target_version);

    try ctx.stderr.print("Successfully installed {s}\n", .{target_version});
}

fn loadScreen(io: Io, writer: *Io.Writer, message_queue: *Io.Queue([]const u8)) !void {
    while (true) {
        const message = message_queue.getOne(io) catch return;
        try writer.writeAll(message);
        try writer.flush();
    }
}

fn installBinaries(ctx: *Context, zig_target: json.Value, command: Command) !void {
    const version = command.version.?;
    const target_version = getTargetVersion(zig_target, version);

    var queue_buffer: [8][]const u8 = undefined;
    var queue: Io.Queue([]const u8) = .init(&queue_buffer);
    defer queue.close(ctx.io);

    var load_screen = ctx.io.async(loadScreen, .{ ctx.io, ctx.stderr, &queue });
    defer load_screen.cancel(ctx.io) catch {};

    // TODO: Need clean up and minisign handlers.
    var zig_async = ctx.io.async(handleZig, .{ ctx, zig_target, &queue });
    defer zig_async.cancel(ctx.io) catch {};

    var zls_async = ctx.io.async(handleZls, .{ ctx, command, &queue });
    defer _ = zls_async.cancel(ctx.io) catch {};

    try zig_async.await(ctx.io);
    const zls_result = try zls_async.await(ctx.io);

    try moveZig(ctx.io, version, target_version);
    if (zls_result) try moveZls(ctx.io, target_version);
}

fn handleZig(ctx: *Context, zig_target: json.Value, message_queue: *Io.Queue([]const u8)) !void {
    const tarball_url = try getTarballUrl(zig_target);
    const shasum = try getShasum(zig_target);

    var response: Io.Writer.Allocating = .init(ctx.allocator);
    defer response.deinit();

    try message_queue.putOne(ctx.io, "Downloading zig...\n");

    const result = try root.httpGet(ctx.allocator, ctx.io, &response.writer, tarball_url);
    if (result.status.class() != .success) {
        try message_queue.putOne(ctx.io, "Failed downloading zig binary\n");
        return error.FailedGetRequest;
    }

    try message_queue.putOne(ctx.io, "Download zig complete!\n");

    checksum(response.written(), shasum) catch |err| {
        try message_queue.putOne(ctx.io, "Invalid zig shasum\n");
        return err;
    };

    try message_queue.putOne(ctx.io, "Extracting zig...\n");
    extractFromSlice(ctx, Io.Dir.cwd(), response.written()) catch |err| {
        try message_queue.putOne(ctx.io, "Failed extracting compressed zig\n");
        return err;
    };

    try message_queue.putOne(ctx.io, "Extraction zig complete!\n");
}

fn handleZls(ctx: *Context, command: Command, message_queue: *Io.Queue([]const u8)) !bool {
    if (command.options.no_zls) return false;
    const version = command.version.?;

    const zls_str = try root.readFile(ctx.allocator, ctx.io, root.zls_file);
    defer ctx.allocator.free(zls_str);

    const zls = try json.parseFromSlice(json.Value, ctx.allocator, zls_str, .{});
    defer zls.deinit();

    const zls_target = zls.value.object.get(version) orelse return false;
    const tarball_url = try getTarballUrl(zls_target);
    const shasum = try getShasum(zls_target);

    var response: Io.Writer.Allocating = .init(ctx.allocator);
    defer response.deinit();

    try message_queue.putOne(ctx.io, "Downloading zls...\n");

    const zls_result = try root.httpGet(ctx.allocator, ctx.io, &response.writer, tarball_url);
    if (zls_result.status.class() != .success) {
        try message_queue.putOne(ctx.io, "Failed downloading zls binary\n");
        return error.FailedGetRequest;
    }

    try message_queue.putOne(ctx.io, "Download zls complete!\n");

    checksum(response.written(), shasum) catch |err| {
        try message_queue.putOne(ctx.io, "Invalid zls shasum\n");
        return err;
    };

    const cwd = Io.Dir.cwd();
    try cwd.createDir(ctx.io, zls_temp, .default_dir);

    const temp_dir = try cwd.openDir(ctx.io, zls_temp, .{});
    defer temp_dir.close(ctx.io);

    try message_queue.putOne(ctx.io, "Extracting zls...\n");
    extractFromSlice(ctx, temp_dir, response.written()) catch |err| {
        try message_queue.putOne(ctx.io, "Failed extracting compressed zls\n");
        return err;
    };

    try message_queue.putOne(ctx.io, "Extraction zls complete!\n");
    return true;
}

fn moveZig(io: Io, version: []const u8, target_version: []const u8) !void {
    var dir_buffer: [128]u8 = undefined;
    const dir_name = try fmt.bufPrint(&dir_buffer, "zig-{s}-{s}-{s}", .{
        @tagName(arch),
        @tagName(os),
        target_version,
    });

    try move(io, dir_name, version);
}

// Move the zls to zig directory.
fn moveZls(io: Io, target_version: []const u8) !void {
    var buffer: [56]u8 = undefined;
    const new_path = try fmt.bufPrint(&buffer, "{s}/zls", .{target_version});

    try move(io, "zls_temp/zls", new_path);
    try Io.Dir.cwd().deleteTree(io, zls_temp);
}

/// Minimal buffer size is 56.
fn bufPrintArchOs(buffer: []u8) ![]const u8 {
    return try fmt.bufPrint(buffer, "{s}-{s}", .{
        @tagName(arch),
        @tagName(os),
    });
}

fn checksum(bytes: []const u8, expected: []const u8) !void {
    var digest: [Sha256.digest_length]u8 = undefined;

    Sha256.hash(bytes, &digest, .{});
    const hex_digest = fmt.bytesToHex(digest, .lower);

    if (!mem.eql(u8, &hex_digest, expected)) return error.InvalidChecksum;
}

fn extractFromSlice(ctx: *Context, target: Io.Dir, source: []const u8) !void {
    var reader: Io.Reader = .fixed(source);
    var decommpressor: xz.Decompress = try .init(&reader, ctx.allocator, &.{});
    defer decommpressor.deinit();

    try tar.extract(ctx.io, target, &decommpressor.reader, .{ .mode_mode = .executable_bit_only });
}

fn getShasum(target: json.Value) ![]const u8 {
    var buffer: [56]u8 = undefined;
    const arch_os = try bufPrintArchOs(&buffer);

    return target.object.get(arch_os).?.object.get(root.shasum_key).?.string;
}

fn getTarballUrl(target: json.Value) ![]const u8 {
    var buffer: [56]u8 = undefined;
    const arch_os = try bufPrintArchOs(&buffer);

    return target.object.get(arch_os).?.object.get(root.tarball_key).?.string;
}

fn getTargetVersion(zig_target: json.Value, version: []const u8) []const u8 {
    if (mem.eql(u8, version, root.master_key)) {
        return zig_target.object.get(root.version_key).?.string;
    }
    return version;
}

fn isMaster(raw_version: []const u8) bool {
    return mem.findAny(u8, raw_version, root.dev_key) != null;
}

fn move(io: Io, old_path: []const u8, new_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.rename(old_path, cwd, new_path, io);
}
