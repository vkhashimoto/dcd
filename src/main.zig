const std = @import("std");
const config = @import("config.zig");

fn warnIfNoTerminal(io: std.Io, content: []const u8, config_path: []const u8, gpa: std.mem.Allocator) !void {
    var cfg = try config.parse(content, gpa);
    defer cfg.directories.deinit(gpa);
    if (cfg.terminal == null) {
        const stderr = std.Io.File.stderr();
        try stderr.writeStreamingAll(io, "warning: 'terminal' is not set in ");
        try stderr.writeStreamingAll(io, config_path);
        try stderr.writeStreamingAll(io, "\n");
        std.process.exit(1);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var config_path_override: ?[]const u8 = null;
    var i: usize = 1;
    if (i < args.len and std.mem.eql(u8, args[i], "--config")) {
        i += 1;
        if (i >= args.len) std.process.fatal("--config requires a path argument", .{});
        config_path_override = args[i];
        i += 1;
    }
    const cmd_args = args[i..];

    if (cmd_args.len == 0) {
        std.process.fatal("Usage: dcd [--config <path>] <name>|add <name> [path]|rm <name>|list", .{});
    }

    const subcmd = cmd_args[0];

    const home = init.environ_map.get("HOME") orelse
        std.process.fatal("HOME not set", .{});
    const config_path = config_path_override orelse blk: {
        const config_base = init.environ_map.get("XDG_CONFIG_HOME") orelse
            try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        break :blk try std.fmt.allocPrint(allocator, "{s}/dcd/config.toml", .{config_base});
    };

    if (std.mem.eql(u8, subcmd, "add")) {
        if (cmd_args.len < 2) std.process.fatal("Usage: dcd add <name> [path]", .{});
        const name = cmd_args[1];
        const entry_path: []const u8 = if (cmd_args.len >= 3) cmd_args[2] else blk: {
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const n = std.process.currentPath(init.io, &buf) catch |err|
                std.process.fatal("Cannot get working directory: {s}", .{@errorName(err)});
            break :blk try allocator.dupe(u8, buf[0..n]);
        };

        const existing: []const u8 = std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .unlimited) catch "";
        const new_content = try config.addEntry(existing, name, entry_path, allocator);

        const config_dir = std.fs.path.dirname(config_path) orelse ".";
        std.Io.Dir.cwd().createDirPath(init.io, config_dir) catch {};
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = config_path, .data = new_content });
        try warnIfNoTerminal(init.io, new_content, config_path, allocator);
        return;
    }

    if (std.mem.eql(u8, subcmd, "rm")) {
        if (cmd_args.len < 2) std.process.fatal("Usage: dcd rm <name>", .{});
        const name = cmd_args[1];

        const existing: []const u8 = std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .unlimited) catch |err|
            std.process.fatal("Cannot read '{s}': {s}", .{ config_path, @errorName(err) });
        const new_content = config.removeEntry(existing, name, allocator) catch |err| switch (err) {
            error.NameNotFound => std.process.fatal("Unknown name '{s}'", .{name}),
            else => return err,
        };
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = config_path, .data = new_content });
        try warnIfNoTerminal(init.io, new_content, config_path, allocator);
        return;
    }

    const content = std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .unlimited) catch |err| {
        std.process.fatal("Cannot read '{s}': {s}", .{ config_path, @errorName(err) });
    };

    const cfg = try config.parse(content, allocator);

    if (std.mem.eql(u8, subcmd, "list")) {
        const stdout = std.Io.File.stdout();
        for (cfg.directories.items) |entry| {
            try stdout.writeStreamingAll(init.io, entry.name);
            try stdout.writeStreamingAll(init.io, "\t");
            try stdout.writeStreamingAll(init.io, entry.path);
            try stdout.writeStreamingAll(init.io, "\n");
        }
        return;
    }

    const term_cmd = cfg.terminal orelse
        std.process.fatal("No 'terminal' entry in config", .{});

    const raw_dir = config.lookup(cfg, subcmd) orelse {
        if (cfg.directories.items.len > 0) {
            var names: std.ArrayList([]const u8) = .empty;
            for (cfg.directories.items) |entry| try names.append(allocator, entry.name);
            const joined = try std.mem.join(allocator, ", ", names.items);
            std.process.fatal("Unknown name '{s}', available: {s}", .{ subcmd, joined });
        }
        std.process.fatal("Unknown name '{s}' (no directories configured)", .{subcmd});
    };

    const dir = try config.expandHome(raw_dir, home, allocator);
    const argv = try config.buildArgv(term_cmd, dir, allocator);

    _ = try std.process.spawn(init.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}
