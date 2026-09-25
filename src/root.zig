const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
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

pub const Config = struct {
    locals: []const []const u8,
    zig: []const u8,
    zig_url: []const u8,
    zls_url: []const u8,
    mirrorlist: []const u8,
    pubkey: []const u8,

    pub fn write(self: Config, file_writer: *Io.Writer) !void {
        try std.json.Stringify.value(self, .{ .whitespace = .indent_2 }, file_writer);
        try file_writer.flush();
    }
};

pub const default_config: Config = .{
    .locals = &.{},
    .zig = &.{},

    .zig_url = "https://ziglang.org/download/index.json",
    .zls_url = "https://builds.zigtools.org/index.json",
    .mirrorlist = "https://ziglang.org/download/community-mirrors.txt",
    .pubkey = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U",
};

pub const config_file = "config.json";
pub const bin_file = "bin";
pub const zig_file = "zig.json";
pub const zls_file = "zls.json";

pub fn initFiles(ctx: *Context) !void {
    var config_async = ctx.io.async(initConfig, .{ctx.io});
    defer config_async.cancel(ctx.io) catch {};

    var zig_async = ctx.io.async(initZigVersions, .{ctx});
    defer zig_async.cancel(ctx.io) catch {};

    var zls_async = ctx.io.async(initZlsVersions, .{ctx});
    defer zls_async.cancel(ctx.io) catch {};

    try config_async.await(ctx.io);
    try zig_async.await(ctx.io);
    try zls_async.await(ctx.io);
}

pub fn initConfig(io: Io) !void {
    const cwd = Io.Dir.cwd();
    const union_file = cwd.openFile(io, config_file, .{});

    if (union_file) |file| {
        file.close(io);
    } else |err| {
        if (err != error.FileNotFound) return err;

        const new_file = try cwd.createFile(io, config_file, .{});
        defer new_file.close(io);

        var buffer: [256]u8 = undefined;
        var file_writer = new_file.writer(io, &buffer);
        const interface = &file_writer.interface;

        try default_config.write(interface);
    }
}

pub fn initZigVersions(ctx: *Context) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.openFile(ctx.io, zig_file, .{})) |file| {
        file.close(ctx.io);
    } else |err| {
        if (err != error.FileNotFound) return err;

        const file = try cwd.createFile(ctx.io, zig_file, .{});
        file.close(ctx.io);

        // Fetch the content from ziglang.org
        try updateVersion(ctx, zig_file, default_config.zig_url);
    }
}

pub fn initZlsVersions(ctx: *Context) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.openFile(ctx.io, zls_file, .{})) |file| {
        file.close(ctx.io);
    } else |err| {
        if (err != error.FileNotFound) return err;

        const file = try cwd.createFile(ctx.io, zls_file, .{});
        file.close(ctx.io);

        // Fetch the content from zigtools.org
        try updateVersion(ctx, zls_file, default_config.zls_url);
    }
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
    const stat = cwd.statFile(io, zig_file, .{}) catch |err| switch (err) {
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

pub fn updateVersions(ctx: *Context, config: Config) !void {
    var zig_async = ctx
        .io
        .async(updateVersion, .{ ctx, zig_file, config.zig_url });
    defer zig_async.cancel(ctx.io) catch {};

    var zls_async = ctx
        .io
        .async(updateVersion, .{ ctx, zls_file, config.zls_url });
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

pub fn containsString(list: []const []const u8, target: []const u8) bool {
    for (list) |item| {
        if (mem.eql(u8, item, target)) return true;
    }
    return false;
}
