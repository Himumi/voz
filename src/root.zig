const std = @import("std");
const json = std.json;
const Io = std.Io;

pub const cli = @import("cli.zig");

pub const Context = struct {
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
    zig_version_url: []const u8,
    zls_version_url: []const u8,
    local_versions: []const []const u8,

    pub const file_name = "setting.json";

    pub fn write(self: *Setting, file_writer: *Io.Writer) !void {
        try std.json.Stringify.value(self.*, .{ .whitespace = .indent_2 }, file_writer);
        try file_writer.flush();
    }
};

pub const default_setting: Setting = .{
    .mirrorlist = "https://ziglang.org/download/community-mirrors.txt",
    .pubkey = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U",
    .zig_version_url = "https://ziglang.org/download/index.json",
    .zls_version_url = "https://builds.zigtools.org/index.json",
    .local_versions = &.{},
};

pub const setting = "setting.json";
pub const bin = "bin";
pub const zig_versions = "zigVersions.json";
pub const zls_versions = "zlsVersions.json";

pub fn initFiles(io: Io) !void {
    try initBin(io);
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
        break :blk try cwd.createFile(io, zig_versions, .{});
    };
    defer file.close(io);
}

pub fn initZlsVersions(io: Io) !void {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, zls_versions, .{}) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk try cwd.createFile(io, zls_versions, .{});
    };
    defer file.close(io);
}
