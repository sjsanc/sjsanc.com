const std = @import("std");

pub const Config = struct {
    content_dir: []const u8,
    output_dir: []const u8,
};

pub fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !Config {
    var content_dir: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "content_dir")) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");
                content_dir = try allocator.dupe(u8, value);
            }
        } else if (std.mem.startsWith(u8, trimmed, "output_dir")) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");
                output_dir = try allocator.dupe(u8, value);
            }
        }
    }

    if (content_dir == null or output_dir == null) {
        return error.MissingConfigFields;
    }

    return Config{
        .content_dir = content_dir.?,
        .output_dir = output_dir.?,
    };
}
