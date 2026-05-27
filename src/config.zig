const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    terminal: ?[]const u8,
    directories: std.ArrayList(Entry),

    pub const Entry = struct {
        name: []const u8,
        path: []const u8,
    };
};

// NOTE: returned slices point into `content`, caller must keep it alive.
pub fn parse(content: []const u8, gpa: Allocator) !Config {
    var terminal: ?[]const u8 = null;
    var directories: std.ArrayList(Config.Entry) = .empty;
    var in_dirs = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;

        if (std.mem.eql(u8, t, "[directories]")) {
            in_dirs = true;
            continue;
        }
        if (t[0] == '[') {
            in_dirs = false;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        var val = std.mem.trim(u8, t[eq + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }

        if (!in_dirs) {
            if (std.mem.eql(u8, key, "terminal")) terminal = val;
        } else {
            try directories.append(gpa, .{ .name = key, .path = val });
        }
    }

    return .{ .terminal = terminal, .directories = directories };
}

pub fn lookup(config: Config, name: []const u8) ?[]const u8 {
    for (config.directories.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.path;
    }
    return null;
}

// NOTE: returns a slice into `raw` when no expansion is needed; only `~/...` paths allocate.
pub fn expandHome(raw: []const u8, home: []const u8, gpa: Allocator) ![]const u8 {
    if (std.mem.startsWith(u8, raw, "~/")) {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, raw[2..] });
    }
    if (std.mem.eql(u8, raw, "~")) return home;
    return raw;
}

// NOTE: non-substituted tokens are views into `term_cmd`; substituted tokens are allocated.
pub fn buildArgv(term_cmd: []const u8, dir: []const u8, gpa: Allocator) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var tok = std.mem.splitScalar(u8, term_cmd, ' ');
    var substituted = false;
    while (tok.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.indexOf(u8, part, "%s")) |pos| {
            try argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
                part[0..pos], dir, part[pos + 2 ..],
            }));
            substituted = true;
        } else {
            try argv.append(gpa, part);
        }
    }
    if (!substituted) try argv.append(gpa, dir);
    return argv.items;
}

test "parse: terminal and directories" {
    const content =
        \\terminal = "alacritty --working-directory %s"
        \\
        \\[directories]
        \\code = ~/code
        \\work = ~/work/projects
    ;
    var cfg = try parse(content, std.testing.allocator);
    defer cfg.directories.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("alacritty --working-directory %s", cfg.terminal.?);
    try std.testing.expectEqual(2, cfg.directories.items.len);
    try std.testing.expectEqualStrings("code", cfg.directories.items[0].name);
    try std.testing.expectEqualStrings("~/code", cfg.directories.items[0].path);
    try std.testing.expectEqualStrings("work", cfg.directories.items[1].name);
}

test "parse: quoted values" {
    const content =
        \\terminal = "alacritty --working-directory %s"
        \\[directories]
        \\home = "~"
    ;
    var cfg = try parse(content, std.testing.allocator);
    defer cfg.directories.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("~", cfg.directories.items[0].path);
}

test "parse: comments and blank lines are ignored" {
    const content =
        \\# this is a comment
        \\terminal = alacritty
        \\
        \\# another comment
        \\[directories]
        \\code = ~/code
    ;
    var cfg = try parse(content, std.testing.allocator);
    defer cfg.directories.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, cfg.directories.items.len);
}

test "lookup: found and not found" {
    const content =
        \\[directories]
        \\code = ~/code
        \\work = ~/work
    ;
    var cfg = try parse(content, std.testing.allocator);
    defer cfg.directories.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("~/code", lookup(cfg, "code").?);
    try std.testing.expectEqualStrings("~/work", lookup(cfg, "work").?);
    try std.testing.expect(lookup(cfg, "missing") == null);
}

test "expandHome: tilde only" {
    const result = try expandHome("~", "/home/user", std.testing.allocator);
    try std.testing.expectEqualStrings("/home/user", result);
}

test "expandHome: tilde slash" {
    const result = try expandHome("~/code", "/home/user", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/code", result);
}

test "expandHome: absolute path unchanged" {
    const result = try expandHome("/srv/data", "/home/user", std.testing.allocator);
    try std.testing.expectEqualStrings("/srv/data", result);
}

test "buildArgv: substitutes %s" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv("alacritty --working-directory %s", "/home/user/code", arena.allocator());

    try std.testing.expectEqual(3, argv.len);
    try std.testing.expectEqualStrings("alacritty", argv[0]);
    try std.testing.expectEqualStrings("--working-directory", argv[1]);
    try std.testing.expectEqualStrings("/home/user/code", argv[2]);
}

test "buildArgv: no %s appends dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv("wezterm start", "/home/user/code", arena.allocator());

    try std.testing.expectEqual(3, argv.len);
    try std.testing.expectEqualStrings("wezterm", argv[0]);
    try std.testing.expectEqualStrings("start", argv[1]);
    try std.testing.expectEqualStrings("/home/user/code", argv[2]);
}

test "buildArgv: %s embedded in argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv("term --title name:%s --cwd %s", "/tmp", arena.allocator());

    try std.testing.expectEqual(5, argv.len);
    try std.testing.expectEqualStrings("term", argv[0]);
    try std.testing.expectEqualStrings("name:/tmp", argv[2]);
    try std.testing.expectEqualStrings("--cwd", argv[3]);
    try std.testing.expectEqualStrings("/tmp", argv[4]);
}
