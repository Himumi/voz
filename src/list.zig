const std = @import("std");
const json = std.json;
const mem = std.mem;
const Io = std.Io;

const root = @import("root.zig");
const Context = root.Context;
const Config = root.Config;

const Kind = enum {
    local,
    remote,

    pub fn string(self: Kind) []const u8 {
        return switch (self) {
            .local => "(local)",
            .remote => "(remote)",
        };
    }
};

fn printVersion(
    writer: *Io.Writer,
    version: []const u8,
    status: []const u8,
    kind: ?Kind,
    actual_version: ?[]const u8,
) !void {
    const repo_kind = if (kind) |repo| repo.string() else "";
    const actual = actual_version orelse "";
    try writer.print("{s:<10}{s:<5}{s:<10}{s}\n", .{ version, status, repo_kind, actual });
}

pub fn run(ctx: *Context, config: Config) !void {
    const zig_string = try root.readFile(ctx.allocator, ctx.io, root.zig_file);
    defer ctx.allocator.free(zig_string);

    // It borrows the string memory.
    const zig = try json.parseFromSlice(json.Value, ctx.allocator, zig_string, .{});
    defer zig.deinit();

    try printList(ctx.stderr, config, zig.value.object);
    try ctx.flush();
}

pub fn runLocal(ctx: *Context, config: Config) !void {
    if (config.locals.len == 0) return;
    const writer = ctx.stderr;

    try printHeader(writer);
    try printSeparator(writer);

    for (config.locals) |version| {
        const status = config.getStatus(version);
        if (root.isMaster(version)) {
            try printVersion(writer, root.master_key, status, null, version);
        } else {
            try printVersion(writer, version, status, null, null);
        }
    }

    try printFooter(writer);
    try ctx.flush();
}

fn printList(writer: *Io.Writer, config: Config, zig: json.ObjectMap) !void {
    try printHeader(writer);
    try printSeparator(writer);

    // Skip master version.
    for (zig.keys()[1..]) |version| {
        const status = config.getStatus(version);
        try printVersion(writer, version, status, null, null);
    }

    const remote_actual = zig.get(root.master_key).?.object.get(root.version_key).?.string;
    const remote_status = config.getStatus(remote_actual);
    try printVersion(writer, root.master_key, remote_status, .remote, remote_actual);

    try printSeparator(writer);

    if (config.getLocalMaster()) |local_actual| {
        const local_status = config.getStatus(local_actual);
        try printVersion(writer, root.master_key, local_status, .local, local_actual);
    }

    try printFooter(writer);
}

fn printHeader(writer: *Io.Writer) !void {
    try writer.print("\x1b[1m{s:<9}{s:<8}\x1b[0m\n", .{ "Version", "Status" });
}

fn printFooter(writer: *Io.Writer) !void {
    try writer.print("\n[ ]: installed [X]: current\n", .{});
}

fn printSeparator(writer: *Io.Writer) !void {
    try writer.print("{s:->50}\n", .{""});
}

// test "runList" {
//     const io = std.testing.io;
//     const gpa = std.testing.allocator;
//
//     var buffer: [1024]u8 = undefined;
//     var writer = Io.File.stdout().writer(io, &buffer);
//     const interface = &writer.interface;
//
//     var ctx: Context = .{
//         .io = io,
//         .allocator = gpa,
//         .stdout = interface,
//         .stderr = interface,
//     };
//
//     try root.initFiles(io);
//
//     const config_str = try readFile(ctx.allocator, ctx.io, root.config_file);
//     defer ctx.allocator.free(config_str);
//
//     // It borrows the string memory.
//     var config = try json.parseFromSlice(Config, ctx.allocator, config_str, .{});
//     defer config.deinit();
//
//     config.value.locals = &.{ "0.16.0", "0.17.0-dev.2234+80fe9b2b7" };
//     config.value.zig = "0.16.0";
//
//     try updateVersions(&ctx, config.value);
//     try runList(&ctx, config.value);
//     try runListLocal(&ctx, config.value);
//
//     const cwd = Io.Dir.cwd();
//
//     try cwd.deleteFile(io, root.config_file);
//     try cwd.deleteFile(io, root.zig_file);
//     try cwd.deleteFile(io, root.zls_file);
// }
