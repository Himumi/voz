const std = @import("std");
const Io = std.Io;

pub const cli = @import("cli.zig");

pub const Context = struct {
    stdout: *Io.Writer,
    stderr: *Io.Writer,

    pub fn flush(self: *Context) !void {
        try self.stdout.flush();
        try self.stderr.flush();
    }
};
