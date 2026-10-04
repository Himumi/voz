const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const zon = std.zon;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = http.Client;

const zon_info = @import("zon_info");

pub const cli = @import("cli.zig");
pub const app_version: []const u8 = zon_info.version;

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

pub const dev_key = "dev";
pub const master_key = "master";
pub const version_key = "version";
pub const tarball_key = "tarball";
pub const shasum_key = "shasum";

pub const Config = struct {
    locals: []const []const u8,
    zig: []const u8,
    zig_url: []const u8,
    zls_url: []const u8,
    mirrorlist: []const u8,
    pubkey: []const u8,

    pub fn write(self: Config, io: Io) !void {
        const file = try Io.Dir.cwd().createFile(io, config_file, .{ .truncate = true });
        defer file.close(io);

        var buffer: [512]u8 = undefined;
        var file_writer = file.writer(io, &buffer);

        try std.json.Stringify.value(self, .{ .whitespace = .indent_2 }, &file_writer.interface);
        try file_writer.interface.flush();
    }

    pub fn getLocalMaster(self: Config) ?[]const u8 {
        for (self.locals, 0..) |version, index| {
            if (isMaster(version)) {
                return self.locals[index];
            }
        }
        return null;
    }

    const installed_symbol = "[ ]";
    const using_symbol = "[X]";

    pub fn getStatus(self: Config, version: []const u8) []const u8 {
        const symbol = if (containsString(self.locals, version))
            installed_symbol
        else
            "";
        return if (mem.eql(u8, self.zig, version))
            using_symbol
        else
            symbol;
    }

    pub fn isOutdated(self: Config, zig: json.Value, version: []const u8) bool {
        if (!mem.eql(u8, version, master_key)) return false;

        const master_version = zig.object.get(master_key).?.object.get(version_key).?.string;
        for (self.locals) |local_version| {
            if (!isMaster(local_version)) continue;
            return mem.order(u8, local_version, master_version) == .lt;
        }

        // It does not have a master "dev" version.
        return true;
    }

    pub fn hasInstalled(self: Config, io: Io, version: []const u8) !bool {
        // - Check version availability.
        if (containsString(self.locals, version)) return true;

        const dir = Io.Dir.cwd().openDir(io, version, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close(io);

        return true;
    }

    pub fn update(self: Config, ctx: *Context, target_version: []const u8) !void {
        var temp = self;
        temp.zig = target_version;

        var versions: std.ArrayList([]const u8) = .empty;
        defer versions.deinit(ctx.allocator);

        try versions.appendSlice(ctx.allocator, self.locals);
        blk: {
            for (self.locals, 0..) |version, index| {
                // Break if it has a same version.
                if (mem.eql(u8, version, target_version)) break :blk;

                if (!isMaster(version) or !isMaster(target_version)) continue;

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

        try temp.write(ctx.io);
    }
};

pub fn isMaster(raw_version: []const u8) bool {
    return mem.findAny(u8, raw_version, dev_key) != null;
}

fn lessThanByString(context: void, lhs: []const u8, rhs: []const u8) bool {
    _ = context;
    return mem.order(u8, lhs, rhs) == .lt;
}

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

pub fn initFiles(gpa: Allocator, io: Io) !void {
    var config_async = io.async(initConfig, .{io});
    defer config_async.cancel(io) catch {};

    var zig_async = io.async(initZig, .{ gpa, io });
    defer zig_async.cancel(io) catch {};

    var zls_async = io.async(initZls, .{ gpa, io });
    defer zls_async.cancel(io) catch {};

    try config_async.await(io);
    try zig_async.await(io);
    try zls_async.await(io);
}

pub fn initConfig(io: Io) !void {
    const cwd = Io.Dir.cwd();
    const union_file = cwd.openFile(io, config_file, .{});

    if (union_file) |file| {
        file.close(io);
    } else |err| {
        if (err != error.FileNotFound) return err;
        try default_config.write(io);
    }
}

pub fn initZig(gpa: Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.openFile(io, zig_file, .{})) |file| {
        file.close(io);
    } else |err| {
        if (err != error.FileNotFound) return err;

        const file = try cwd.createFile(io, zig_file, .{});
        file.close(io);

        // Fetch the content from ziglang.org
        try updateVersion(gpa, io, zig_file, default_config.zig_url);
    }
}

pub fn initZls(gpa: Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.openFile(io, zls_file, .{})) |file| {
        file.close(io);
    } else |err| {
        if (err != error.FileNotFound) return err;

        const file = try cwd.createFile(io, zls_file, .{});
        file.close(io);

        // Fetch the content from zigtools.org
        try updateVersion(gpa, io, zls_file, default_config.zls_url);
    }
}

pub fn readFile(gpa: Allocator, io: Io, path: []const u8) ![]const u8 {
    return try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

pub fn readZon(comptime T: type, gpa: Allocator, io: Io, path: []const u8) !T {
    const cwd = Io.Dir.cwd();

    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const stat = try file.stat(io);

    const buffer = try gpa.allocSentinel(u8, stat.size, 0);
    defer gpa.free(buffer);

    const size = try file.readPositionalAll(io, buffer, 0);
    if (size != stat.size) return error.InvalidFileSize;

    return try zon
        .parse
        .fromSliceAlloc(T, gpa, buffer, null, .{ .ignore_unknown_fields = true });
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

pub fn updateVersions(gpa: Allocator, io: Io, config: Config) !void {
    var zig_async = io.async(updateVersion, .{ gpa, io, zig_file, config.zig_url });
    defer zig_async.cancel(io) catch {};

    var zls_async = io.async(updateVersion, .{ gpa, io, zls_file, config.zls_url });
    defer zls_async.cancel(io) catch {};

    try zig_async.await(io);
    try zls_async.await(io);
}

pub fn updateVersion(gpa: Allocator, io: Io, path: []const u8, url: []const u8) !void {
    var response: Io.Writer.Allocating = .init(gpa);
    defer response.deinit();

    var result = try httpGet(gpa, io, &response.writer, url);
    if (result.status.class() != .success)
        return error.FailedToGetVersions;

    try writeFile(io, path, response.written());
}

pub fn httpGet(gpa: Allocator, io: Io, writer: *Io.Writer, url: []const u8) !Client.FetchResult {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
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
