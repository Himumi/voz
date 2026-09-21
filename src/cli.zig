const builtin = @import("builtin");
const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Client = http.Client;
const Io = std.Io;

const list = @import("list.zig");
const root = @import("root.zig");
const Context = root.Context;
const Setting = root.Setting;

pub fn run(ctx: *Context, command: Command) !void {
    const options = command.options;

    const config_str = try root.readFile(ctx.allocator, ctx.io, Setting.file_name);
    defer ctx.allocator.free(config_str);

    // It borrows the string memory.
    const config = try json.parseFromSlice(Setting, ctx.allocator, config_str, .{});
    defer config.deinit();

    switch (command.kind) {
        .help => return try printHelp(ctx, help_message),
        .install => {
            if (command.options.help) {
                return try printHelp(ctx, install_message);
            }
        },
        .list => {
            const is_help = options.help or options.force or options.no_zls or options.sync;
            if (is_help) {
                return try printHelp(ctx, list_message);
            }

            if (options.local) {
                return try list.runLocal(ctx, config.value);
            }

            try root.updateVersions(ctx, config.value);
            try list.run(ctx, config.value);
        },
        .remove => {
            if (command.options.help) {
                return try printHelp(ctx, remove_message);
            }
        },
        .upgrade => {
            if (command.options.help) {
                return try printHelp(ctx, upgrade_message);
            }
        },
        .use => {
            if (command.options.help) {
                return try printHelp(ctx, use_message);
            }
        },
        .version => try ctx.stderr.print("0.0.0\n", .{}),
    }
}

pub fn parse(args: []const [:0]const u8) error{InvalidOption}!Command {
    var command: Command = undefined;

    var input = args[1..];
    command.kind = parseCommand(input[0]) orelse blk: {
        input = input[1..];
        break :blk .help;
    };

    command.options = try parseOptions(input);
    command.version = parseVersion(input);

    return command;
}

test "parse" {
    var args = [_][:0]const u8{
        "voz",
        "use",
        "0.0.0",
    };

    const expected: Command = .{
        .kind = .use,
        .options = .empty,
        .version = "0.0.0",
    };
    const command = try parse(&args);

    try testing.expectEqual(expected.kind, command.kind);
    if (command.version) |version| {
        try testing.expectEqualSlices(u8, expected.version orelse unreachable, version);
    } else {
        return error.ReceivedNull;
    }

    const options_info = @typeInfo(Command.Options);
    inline for (options_info.@"struct".fields) |field| {
        const actual_value: bool = @field(expected.options, field.name);
        const expected_value: bool = @field(command.options, field.name);
        try testing.expectEqual(expected_value, actual_value);
    }
}

const commands: std.StaticStringMap(Command.Kind) = .initComptime(.{
    .{ "help", .help },
    .{ "install", .install },
    .{ "list", .list },
    .{ "remove", .remove },
    .{ "upgrade", .upgrade },
    .{ "use", .use },
    .{ "version", .version },
});

fn parseCommand(arg: []const u8) ?Command.Kind {
    return commands.get(arg);
}

test "parseCommand" {
    try testing.expectEqual(Command.Kind.help, parseCommand("help"));
    try testing.expectEqual(Command.Kind.install, parseCommand("install"));
    try testing.expectEqual(Command.Kind.list, parseCommand("list"));
    try testing.expectEqual(Command.Kind.remove, parseCommand("remove"));
    try testing.expectEqual(Command.Kind.upgrade, parseCommand("upgrade"));
    try testing.expectEqual(Command.Kind.use, parseCommand("use"));
    try testing.expectEqual(Command.Kind.version, parseCommand("version"));
    try testing.expectEqual(null, parseCommand("unknown"));
}

fn parseOptions(args: []const [:0]const u8) error{InvalidOption}!Command.Options {
    var options: Command.Options = .empty;

    for (args) |literal_arg| {
        const arg: []const u8 = literal_arg;
        if (!mem.startsWith(u8, arg, "--")) continue;

        if (mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (mem.eql(u8, arg, "--local")) {
            options.local = true;
        } else if (mem.eql(u8, arg, "--no-zls")) {
            options.no_zls = true;
        } else if (mem.eql(u8, arg, "--sync")) {
            options.sync = true;
        } else {
            return error.InvalidOption;
        }
    }

    return options;
}

test "parseOptions" {
    var args = [_][:0]const u8{
        "--force",
        "--help",
        "--local",
        "--no-zls",
        "--sync",
    };

    const expected: Command.Options = .{
        .force = true,
        .help = true,
        .local = true,
        .no_zls = true,
        .sync = true,
    };
    const actual = try parseOptions(&args);

    const options_info = @typeInfo(Command.Options);
    inline for (options_info.@"struct".fields) |field| {
        const expected_value: bool = @field(expected, field.name);
        const actual_value: bool = @field(actual, field.name);
        try testing.expectEqual(expected_value, actual_value);
    }

    var invalid_args = [_][:0]const u8{
        "--help",
        "--invalid",
    };
    try testing.expectError(error.InvalidOption, parseOptions(&invalid_args));
}

const reserved: std.StaticStringMap(void) = .initComptime(.{
    .{ "help", void },
    .{ "install", void },
    .{ "list", void },
    .{ "remove", void },
    .{ "upgrade", void },
    .{ "use", void },
    .{ "version", void },
    .{ "--force", void },
    .{ "--help", void },
    .{ "--local", void },
    .{ "--no-zls", void },
    .{ "--sync", void },
});

fn parseVersion(args: []const [:0]const u8) ?[]const u8 {
    var version: ?[]const u8 = null;

    for (args) |literal_arg| {
        const arg: []const u8 = literal_arg;

        if (reserved.get(arg) == null) {
            version = arg;
            break;
        }
    }
    return version;
}

test "parseVersion" {
    var args = [_][:0]const u8{ "use", "0.0.0", "0.0.1" };
    const version = parseVersion(&args) orelse return error.ReceivedNull;
    try testing.expectEqualSlices(u8, "0.0.0", version);
}

pub const Command = struct {
    kind: Kind = .help,
    options: Options = .empty,
    // It borrows the memory from the caller.
    version: ?[]const u8,

    pub const Kind = enum {
        help,
        install,
        list,
        remove,
        upgrade,
        use,
        version,
    };

    pub const Options = struct {
        force: bool = false,
        help: bool = false,
        local: bool = false,
        no_zls: bool = false,
        sync: bool = false,

        pub const empty: Options = .{};
    };
};

pub const help_message =
    \\VOZ is a Zig Version Manager.
    \\
    \\Usage: voz [command] [options]
    \\
    \\Commands:
    \\
    \\  install    Download and install selected Zig version
    \\  use        Switch between Zig versions
    \\  list       Print available Zig versions
    \\  remove     Remove an installed Zig version
    \\
    \\  help       Print this help and exit
    \\  upgrade    Upgrade VOZ version
    \\  version    Print VOZ version and exit
    \\
    \\
;

pub const install_message =
    \\voz install - Download and install selected Zig version.
    \\
    \\Usage: voz install [options] [ZIG VERSION]
    \\
    \\Options:
    \\
    \\  --no-zls   Exclude ZLS
    \\  --force    Force installation even if the version is installed
    \\  --help     Print install command help message
    \\
    \\
;

pub const use_message =
    \\voz use - Switch between Zig versions.
    \\
    \\Usage: voz use [options] [ZIG VERSION]
    \\
    \\Options:
    \\
    \\  --sync     Synchronize Zig version with the local repository.
    \\  --help     Print use command help message
    \\
    \\
;

pub const list_message =
    \\voz list - Print available Zig versions.
    \\
    \\Usage: voz list [options]
    \\
    \\Options:
    \\
    \\  --local    Print installed Zig versions.
    \\  --help     Print list command help message
    \\
    \\
;

pub const remove_message =
    \\voz remove - Remove an installed Zig version.
    \\
    \\Usage: voz remove [options] [ZIG VERSION]
    \\
    \\Options:
    \\
    \\  --help     Print remove command help message
    \\
    \\
;

pub const upgrade_message =
    \\voz upgrade - Upgrade VOZ version.
    \\
    \\Usage: voz upgrade [options]
    \\
    \\Options:
    \\
    \\  --help     Print upgrade command help message
    \\
    \\
;

pub const copyright_fmt = "Copyright © {d} Himumi\n";

pub fn printHelp(ctx: *Context, message: []const u8) !void {
    try ctx.stderr.print("{s}", .{message});
    try ctx.stderr.print(copyright_fmt, .{getCurrentYear(ctx.io)});
}

fn getCurrentYear(io: std.Io) u16 {
    const seconds: u64 = @intCast(std.Io.Clock.real.now(io).toSeconds());

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const epoch_day = epoch_secs.getEpochDay();
    const epoch_year = epoch_day.calculateYearDay();

    return epoch_year.year;
}
