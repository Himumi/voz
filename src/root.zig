const std = @import("std");
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
