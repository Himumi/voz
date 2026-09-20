const std = @import("std");
const epoch = std.time.epoch;

const voz = @import("voz");
const cli = voz.cli;
const Context = voz.Context;

var stdout_buffer: [1024]u8 = undefined;
var stderr_buffer: [1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var ctx: Context = .{
        .allocator = init.arena.allocator(),
        .io = init.io,
        .stdout = stdout,
        .stderr = stderr,
    };

    try voz.initFiles(ctx.io);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len <= 1) {
        try cli.printHelp(&ctx, cli.help_message);
    } else {
        const command = try cli.parse(args);
        try cli.run(&ctx, command);
    }
    return try ctx.flush();
}
