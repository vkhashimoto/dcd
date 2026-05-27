const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct { name: []const u8, path: []const u8 };

fn fuzzyMatch(query: []const u8, target: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (target) |c| {
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) {
            qi += 1;
            if (qi == query.len) return true;
        }
    }
    return false;
}

fn clearLines(tty: std.Io.File, io: std.Io, n: usize) !void {
    var esc: [32]u8 = undefined;
    const seq = try std.fmt.bufPrint(&esc, "\x1b[{d}A\x1b[J", .{n});
    try tty.writeStreamingAll(io, seq);
}

pub fn run(entries: []const Entry, io: std.Io, gpa: Allocator, header: ?[]const u8) !?usize {
    const tty_fd = try std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0);
    const tty = std.Io.File{ .handle = tty_fd, .flags = .{ .nonblocking = false } };
    defer tty.close(io);

    const orig = try std.posix.tcgetattr(tty_fd);
    defer std.posix.tcsetattr(tty_fd, .FLUSH, orig) catch {};

    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(tty_fd, .FLUSH, raw);

    const header_lines: usize = if (header) |h| blk: {
        try tty.writeStreamingAll(io, h);
        try tty.writeStreamingAll(io, "\n");
        break :blk 1;
    } else 0;

    // NOTE: input beyond 256 chars is silently dropped; generous for directory names.
    var query_buf: [256]u8 = undefined;
    var query_len: usize = 0;
    var sel: usize = 0;
    var prev_lines: usize = 0;
    var render_buf: std.ArrayList(u8) = .empty;
    defer render_buf.deinit(gpa);

    while (true) {
        const query = query_buf[0..query_len];

        var filtered: [64]usize = undefined;
        var filtered_len: usize = 0;
        for (entries, 0..) |entry, ei| {
            if (filtered_len >= 64) break;
            if (fuzzyMatch(query, entry.name)) {
                filtered[filtered_len] = ei;
                filtered_len += 1;
            }
        }
        for (entries, 0..) |entry, ei| {
            if (filtered_len >= 64) break;
            if (!fuzzyMatch(query, entry.name) and fuzzyMatch(query, entry.path)) {
                filtered[filtered_len] = ei;
                filtered_len += 1;
            }
        }
        if (filtered_len > 0 and sel >= filtered_len) sel = filtered_len - 1;

        render_buf.clearRetainingCapacity();
        if (prev_lines > 0) {
            var esc: [32]u8 = undefined;
            const seq = try std.fmt.bufPrint(&esc, "\x1b[{d}A\x1b[J", .{prev_lines});
            try render_buf.appendSlice(gpa, seq);
        }
        try render_buf.appendSlice(gpa, "> ");
        try render_buf.appendSlice(gpa, query);
        try render_buf.append(gpa, '\n');

        var lines_drawn: usize = 1;
        if (filtered_len == 0) {
            try render_buf.appendSlice(gpa, "(no matches)\n");
            lines_drawn += 1;
        } else {
            for (filtered[0..filtered_len], 0..) |ei, fi| {
                const entry = entries[ei];
                if (fi == sel) {
                    try render_buf.appendSlice(gpa, "> ");
                } else {
                    try render_buf.appendSlice(gpa, "  ");
                }
                try render_buf.appendSlice(gpa, entry.name);
                try render_buf.appendSlice(gpa, "  ");
                try render_buf.appendSlice(gpa, entry.path);
                try render_buf.append(gpa, '\n');
                lines_drawn += 1;
            }
        }
        try tty.writeStreamingAll(io, render_buf.items);
        prev_lines = lines_drawn;

        // VMIN=1 blocks until at least 1 byte is available
        var input: [4]u8 = undefined;
        const n = try std.posix.read(tty_fd, &input);
        if (n == 0) continue;

        // Arrow keys arrive as 3-byte ESC sequences
        if (n >= 3 and input[0] == 0x1b and input[1] == '[') {
            switch (input[2]) {
                'A' => if (filtered_len > 0) {
                    sel = if (sel == 0) filtered_len - 1 else sel - 1;
                },
                'B' => if (filtered_len > 0) {
                    sel = if (sel + 1 >= filtered_len) 0 else sel + 1;
                },
                else => {},
            }
            continue;
        }

        switch (input[0]) {
            0x10 => if (filtered_len > 0) { // Ctrl+P
                sel = if (sel == 0) filtered_len - 1 else sel - 1;
            },
            0x0e => if (filtered_len > 0) { // Ctrl+N
                sel = if (sel + 1 >= filtered_len) 0 else sel + 1;
            },
            0x0d, 0x0a => { // Enter
                try clearLines(tty, io, prev_lines + header_lines);
                if (filtered_len == 0) return null;
                return filtered[sel];
            },
            0x03 => { // Ctrl+C
                if (query_len > 0) {
                    query_len = 0;
                    sel = 0;
                } else {
                    try clearLines(tty, io, prev_lines + header_lines);
                    return null;
                }
            },
            0x15 => { // Ctrl+U
                query_len = 0;
                sel = 0;
            },
            0x1b => { // Escape
                try clearLines(tty, io, prev_lines + header_lines);
                return null;
            },
            0x7f, 0x08 => { // Backspace
                if (query_len > 0) {
                    query_len -= 1;
                    sel = 0;
                }
            },
            0x20...0x7e => { // printable ASCII
                if (query_len < query_buf.len) {
                    query_buf[query_len] = input[0];
                    query_len += 1;
                    sel = 0;
                }
            },
            else => {},
        }
    }
}
