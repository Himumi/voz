const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = http.Client;

pub const cli = @import("cli.zig");

pub const Context = struct {
    allocator: Allocator,
    io: Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,

    pub fn flush(self: *Context) !void {
        try self.stdout.flush();
        try self.stderr.flush();
    }
};

pub const Setting = struct {
    mirrorlist: []const u8,
    pubkey: []const u8,
    zig_url: []const u8,
    zls_url: []const u8,
    locals: []const []const u8,
    zig: []const u8,
    zls: []const u8,

    pub const file_name = "setting.json";

    pub fn write(self: *Setting, file_writer: *Io.Writer) !void {
        try std.json.Stringify.value(self.*, .{ .whitespace = .indent_2 }, file_writer);
        try file_writer.flush();
    }
};

pub const default_setting: Setting = .{
    .zig_url = "https://ziglang.org/download/index.json",
    .zls_url = "https://builds.zigtools.org/index.json",
    .mirrorlist = "https://ziglang.org/download/community-mirrors.txt",
    .pubkey = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U",
    // Installed Zig versions.
    .locals = &.{},
    // Current versions
    .zig = &.{},
    .zls = &.{},
};

pub const setting = "setting.json";
pub const bin = "bin";
pub const zig_versions = "zigVersions.json";
pub const zls_versions = "zlsVersions.json";

pub fn initFiles(io: Io) !void {
    try initSetting(io);
    try initZigVersions(io);
    try initZlsVersions(io);
}

pub fn initBin(io: Io) !void {
    const cwd = Io.Dir.cwd();
    const dir = cwd.openDir(io, bin, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        return try cwd.createDir(io, bin, .default_dir);
    };
    defer dir.close(io);
}

pub fn initSetting(io: Io) !void {
    const cwd = Io.Dir.cwd();
    const union_file = cwd.openFile(io, setting, .{});

    if (union_file) |file| {
        file.close(io);
    } else |err| {
        if (err != error.FileNotFound) return err;

        const new_file = try cwd.createFile(io, setting, .{});
        defer new_file.close(io);

        var buffer: [1024]u8 = undefined;
        var file_writer = new_file.writer(io, &buffer);
        const interface = &file_writer.interface;

        try json
            .Stringify
            .value(default_setting, .{ .whitespace = .indent_2 }, interface);
        try interface.flush();
    }
}

pub fn initZigVersions(io: Io) !void {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, zig_versions, .{}) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        // TODO: Need to fetch the latest for init.
        break :blk try cwd.createFile(io, zig_versions, .{});
    };
    defer file.close(io);
}

pub fn initZlsVersions(io: Io) !void {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, zls_versions, .{}) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        // TODO: Need to fetch the latest for init.
        break :blk try cwd.createFile(io, zls_versions, .{});
    };
    defer file.close(io);
}

pub fn readFile(gpa: Allocator, io: Io, path: []const u8) ![]const u8 {
    return try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

pub fn writeFile(io: Io, path: []const u8, content: []const u8) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);

    try file.writeStreamingAll(io, content);
}

pub fn shouldUpdateVersions(io: Io) !bool {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, zig_versions, .{}) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };

    const now_ns = std.Io.Clock.real.now(io).nanoseconds;
    const last_modified = stat.mtime.nanoseconds;
    const duration = now_ns - last_modified;

    // 24 hours in nanoseconds
    const ttl: u64 = 24 * 3600 * std.time.ns_per_s;
    return duration > ttl;
}

pub fn updateVersions(ctx: *Context, config: Setting) !void {
    var zig_async = ctx
        .io
        .async(updateVersion, .{ ctx, zig_versions, config.zig_url });
    defer zig_async.cancel(ctx.io) catch {};

    var zls_async = ctx
        .io
        .async(updateVersion, .{ ctx, zls_versions, config.zls_url });
    defer zls_async.cancel(ctx.io) catch {};

    try zig_async.await(ctx.io);
    try zls_async.await(ctx.io);
}

pub fn updateVersion(ctx: *Context, path: []const u8, url: []const u8) !void {
    var response: Io.Writer.Allocating = .init(ctx.allocator);
    defer response.deinit();

    var result = try httpGet(ctx, &response.writer, url);
    if (result.status.class() != .success)
        return error.FailedToGetVersions;

    try writeFile(ctx.io, path, response.written());
}

pub fn httpGet(ctx: *Context, writer: *Io.Writer, url: []const u8) !Client.FetchResult {
    var client: std.http.Client = .{
        .allocator = ctx.allocator,
        .io = ctx.io,
    };
    defer client.deinit();

    return try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = writer,
    });
}
