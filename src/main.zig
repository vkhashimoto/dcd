const std = @import("std");
const config = @import("config.zig");
const picker = @import("picker.zig");

fn execShell(io: std.Io, dir: []const u8, shell: []const u8) noreturn {
    std.process.setCurrentPath(io, dir) catch |err|
        std.process.fatal("chdir '{s}': {s}", .{ dir, @errorName(err) });
    const err = std.process.replace(io, .{ .argv = &.{shell} });
    std.process.fatal("exec {s}: {s}", .{ shell, @errorName(err) });
}

fn resolveShell(config_shell: ?[]const u8, env_shell: ?[]const u8) []const u8 {
    return config_shell orelse env_shell orelse
        std.process.fatal("$SHELL is not set", .{});
}

fn doLaunch(cfg: config.Config, io: std.Io, dir: []const u8, allocator: std.mem.Allocator, shell: []const u8) !void {
    switch (cfg.launch) {
        .exec => execShell(io, dir, shell),
        .spawn => {
            const term_cmd = cfg.terminal orelse
                std.process.fatal("'terminal' must be set when launch = spawn", .{});
            const argv = try config.buildArgv(term_cmd, dir, allocator);
            _ = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
        },
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

    const home = init.environ_map.get("HOME") orelse
        std.process.fatal("HOME not set", .{});
    const config_path = config_path_override orelse blk: {
        const config_base = init.environ_map.get("XDG_CONFIG_HOME") orelse
            try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        break :blk try std.fmt.allocPrint(allocator, "{s}/dcd/config.toml", .{config_base});
    };

    if (cmd_args.len == 0) {
        const content = std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .unlimited) catch |err| {
            std.process.fatal("Cannot read '{s}': {s}", .{ config_path, @errorName(err) });
        };
        const cfg = try config.parse(content, allocator);

        const picker_entries = try allocator.alloc(picker.Entry, cfg.directories.items.len);
        for (cfg.directories.items, 0..) |entry, j| {
            picker_entries[j] = .{ .name = entry.name, .path = entry.path };
        }

        const selection = try picker.run(picker_entries, init.io, allocator);
        const idx = selection orelse return;

        const raw_dir = cfg.directories.items[idx].path;
        const dir = try config.expandHome(raw_dir, home, allocator);
        const shell = resolveShell(cfg.shell, init.environ_map.get("SHELL"));
        try doLaunch(cfg, init.io, dir, allocator, shell);
        return;
    }

    const subcmd = cmd_args[0];

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
    const shell = resolveShell(cfg.shell, init.environ_map.get("SHELL"));
    try doLaunch(cfg, init.io, dir, allocator, shell);
}
