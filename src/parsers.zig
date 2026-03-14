const std = @import("std");
const cmark = @import("cmark.zig");

pub const Post = struct { raw: []const u8, path: []const u8, title: []const u8, date: []const u8, slug: []const u8, html: []const u8 };

// Converts a markdown file in the .vault into an in-memory Post struct
pub fn parsePostMarkdown(gpa: std.mem.Allocator, raw: []const u8) !Post {
    const first_fence_idx = std.mem.indexOf(u8, raw, "---") orelse return error.NoFrontmatter;
    const after_first = raw[first_fence_idx + 3 ..];
    const second_fence_idx = std.mem.indexOf(u8, after_first, "---") orelse return error.NoFrontmatter;
    const frontmatter = after_first[0..second_fence_idx];

    var lines = std.mem.splitScalar(u8, frontmatter, '\n');

    var title: []const u8 = "";
    var date: []const u8 = "";
    var slug: []const u8 = "";

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        const sep = std.mem.indexOf(u8, trimmed, ":") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..sep], " ");
        const val = std.mem.trim(u8, trimmed[sep + 1 ..], " ");

        if (std.mem.eql(u8, key, "title")) {
            title = val;
        } else if (std.mem.eql(u8, key, "date")) {
            date = val;
        } else if (std.mem.eql(u8, key, "slug")) {
            slug = val;
        }
    }

    if (date.len < 4) return error.InvalidDate;
    if (slug.len == 0) return error.MissingSlug;
    const prefixed = try std.mem.concat(gpa, u8, &.{ "posts/", date[0..4], "/", slug, ".html" });
    const content = after_first[second_fence_idx + 3 ..];
    const html = try cmark.markdownToHtml(gpa, content);
    return Post{ .raw = raw, .path = prefixed, .title = title, .date = date, .slug = slug, .html = html };
}

// Walks the .vault directory and returns a flat list of in-memory Posts
pub fn parseContent(gpa: std.mem.Allocator, dir: std.fs.Dir) !std.ArrayListUnmanaged(Post) {
    var output: std.ArrayListUnmanaged(Post) = .{};
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        const raw = try file.readToEndAlloc(gpa, 1024 * 1024);
        const post = try parsePostMarkdown(gpa, raw);
        try output.append(gpa, post);
    }
    return output;
}
