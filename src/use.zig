const std = @import("std");
const json = std.json;
const mem = std.mem;
const zon = std.zon;
const Io = std.Io;
const Allocator = mem.Allocator;

const cli = @import("cli.zig");
const install = @import("install.zig");
const root = @import("root.zig");
const Command = cli.Command;
const Config = root.Config;
const Context = root.Context;

pub fn run(ctx: *Context, config: Config, command: Command) !void {
    if (command.options.sync) {
        try handleSync(ctx, config, command);
    } else {
        try handleLocal(ctx, config, command.version.?);
    }
}

fn handleLocal(ctx: *Context, config: Config, local_version: []const u8) !void {
    const has_installed = try config.hasInstalled(ctx.io, local_version);
    if (has_installed) {
        try switchVersion(ctx.io, config, local_version);
        try printVersion(ctx.stderr, local_version);
    } else {
        try ctx.stderr.print("{s} version has not installed\n", .{local_version});
        try ctx.stderr.print("Try to install manually 'voz install {s}'\n", .{local_version});
    }
}

const Zon = struct {
    minimum_zig_version: ?[]const u8 = null,

    const file_name = "build.zig.zon";
};

const not_found_zon = "Not found build.zig.zon\n";
const not_found_minimum_version =
    \\Not found minimum_zig_version field in build.zig.zon
    \\Try to install manually 'voz install [version]'
    \\
;

fn handleSync(ctx: *Context, config: Config, command: Command) !void {
    const parsed_zon = root.readZon(Zon, ctx.allocator, ctx.io, Zon.file_name) catch |err| {
        if (err != error.FileNotFound) return err;
        return try ctx.stderr.writeAll(not_found_zon);
    };
    defer zon.parse.free(ctx.allocator, parsed_zon);

    if (parsed_zon.minimum_zig_version == null) {
        return try ctx.stderr.writeAll(not_found_minimum_version);
    }
    const local_version = parsed_zon.minimum_zig_version orelse unreachable;

    var mutable_command = command;
    mutable_command.version = local_version;

    try install.run(ctx, config, mutable_command);

    if (isSuccess(ctx.stderr.buffered())) {
        // Need to read config after updated by 'install.run'.
        const config_str = try root.readFile(ctx.allocator, ctx.io, root.config_file);
        defer ctx.allocator.free(config_str);

        const parsed_config = try json.parseFromSlice(root.Config, ctx.allocator, config_str, .{});
        defer parsed_config.deinit();

        try switchVersion(ctx.io, parsed_config.value, local_version);
    } else {
        try switchVersion(ctx.io, config, local_version);
    }
    try printVersion(ctx.stderr, local_version);
}

fn isSuccess(message: []const u8) bool {
    return mem.findAny(u8, message, "Successfully") != null;
}

fn printVersion(writer: *Io.Writer, version: []const u8) !void {
    try writer.print("Now using {s}\n", .{version});
}

fn switchVersion(io: Io, config: Config, version: []const u8) !void {
    const cwd = Io.Dir.cwd();

    try cwd.deleteFile(io, root.bin_file);
    try cwd.symLink(io, version, root.bin_file, .{ .is_directory = true });

    var temp = config;
    temp.zig = if (mem.eql(u8, version, root.master_key))
        config.getLocalMaster() orelse unreachable
    else
        version;
    try temp.write(io);
}
