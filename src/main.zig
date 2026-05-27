const std = @import("std");
const config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.process.fatal("Usage: dcd <name>", .{});
    }

    const target = args[1];

    const home = init.environ_map.get("HOME") orelse
        std.process.fatal("HOME not set", .{});

    const config_base = init.environ_map.get("XDG_CONFIG_HOME") orelse
        try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    const config_path = try std.fmt.allocPrint(allocator, "{s}/dcd/config.toml", .{config_base});

    const content = std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .unlimited) catch |err| {
        std.process.fatal("Cannot read '{s}': {s}", .{ config_path, @errorName(err) });
    };

    const cfg = try config.parse(content, allocator);

    if (std.mem.eql(u8, target, "list")) {
        const stdout = std.Io.File.stdout();
        for (cfg.directories.items) |entry| {
            try stdout.writeStreamingAll(init.io, entry.name);
            try stdout.writeStreamingAll(init.io, "\n");
        }
        return;
    }

    const term_cmd = cfg.terminal orelse
        std.process.fatal("No 'terminal' entry in config", .{});

    const raw_dir = config.lookup(cfg, target) orelse {
        if (cfg.directories.items.len > 0) {
            var names: std.ArrayList([]const u8) = .empty;
            for (cfg.directories.items) |entry| try names.append(allocator, entry.name);
            const joined = try std.mem.join(allocator, ", ", names.items);
            std.process.fatal("Unknown name '{s}', available: {s}", .{ target, joined });
        }
        std.process.fatal("Unknown name '{s}' (no directories configured)", .{target});
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
