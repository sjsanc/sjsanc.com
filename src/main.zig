const std = @import("std");
const fs = std.fs;
const log = std.log;
const v2 = @import("v2");
const cmark = @import("cmark.zig");
const config = @import("config.zig");

const Post = struct { raw: []const u8, path: []const u8, title: []const u8, date: []const u8, slug: []const u8, html: []const u8 };

fn copyStaticFile(gpa: std.mem.Allocator, output_dir: []const u8, name: []const u8) !void {
    const src = try std.fs.path.join(gpa, &.{ "static/html", name });
    defer gpa.free(src);
    const dest = try std.fs.path.join(gpa, &.{ output_dir, name });
    defer gpa.free(dest);
    try fs.cwd().copyFile(src, fs.cwd(), dest, .{});
}

fn renderTemplate(gpa: std.mem.Allocator, template: []const u8, content: []const u8) ![]const u8 {
    const marker = "{{ content }}";
    const pos = std.mem.indexOf(u8, template, marker) orelse return error.TemplateMissingContentMarker;
    return std.mem.concat(gpa, u8, &.{
        template[0..pos],
        content,
        template[pos + marker.len ..],
    });
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try fs.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(content);
}

fn buildPostList(gpa: std.mem.Allocator, posts: std.ArrayListUnmanaged(Post)) !std.ArrayListUnmanaged(u8) {
    var list_buf: std.ArrayListUnmanaged(u8) = .{};
    for (posts.items) |post| {
        try list_buf.appendSlice(gpa, "<li><a href=\"posts/");
        try list_buf.appendSlice(gpa, post.path);
        try list_buf.appendSlice(gpa, "\">");
        try list_buf.appendSlice(gpa, post.title);
        try list_buf.appendSlice(gpa, " ");
        try list_buf.appendSlice(gpa, post.date[0..4]); // year
        try list_buf.appendSlice(gpa, "</a></li>\n");
    }
    return list_buf;
}

fn buildWritingPage(gpa: std.mem.Allocator, posts: std.ArrayListUnmanaged(Post), output_dir: []const u8) !void {
    var list_buf = try buildPostList(gpa, posts);
    defer list_buf.deinit(gpa);

    const template = try fs.cwd().readFileAlloc(gpa, "static/html/writing.html", 64 * 1024);
    defer gpa.free(template);

    const page = try renderTemplate(gpa, template, list_buf.items);
    defer gpa.free(page);

    const dest = try std.fs.path.join(gpa, &.{ output_dir, "writing.html" });
    defer gpa.free(dest);

    const file = try fs.createFileAbsolute(dest, .{});
    defer file.close();

    try file.writeAll(page);
}

fn buildPostPages(gpa: std.mem.Allocator, posts: std.ArrayListUnmanaged(Post), output_dir: []const u8) !void {
    const posts_path = try std.fs.path.join(gpa, &.{ output_dir, "posts" });
    defer gpa.free(posts_path);
    try fs.makeDirAbsolute(posts_path);

    const template = try fs.cwd().readFileAlloc(gpa, "templates/post.html", 64 * 1024);
    defer gpa.free(template);

    const marker = "{{ content }}";
    const marker_pos = std.mem.indexOf(u8, template, marker) orelse return error.TemplateMissingContentMarker;
    const before = template[0..marker_pos];
    const after = template[marker_pos + marker.len ..];

    for (posts.items) |post| {
        const page = try std.mem.concat(gpa, u8, &.{ before, post.html, after });
        defer gpa.free(page);

        // swap .md for .html and join with posts output path
        const html_name = try std.mem.replaceOwned(u8, gpa, post.path, ".md", ".html");
        defer gpa.free(html_name);
        const out_path = try std.fs.path.join(gpa, &.{ posts_path, html_name });
        defer gpa.free(out_path);

        // ensure parent dir exists for nested paths like 2024/test.html
        if (std.fs.path.dirname(out_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        const file = try fs.createFileAbsolute(out_path, .{});
        defer file.close();
        try file.writeAll(page);
        log.info("wrote: {s}", .{out_path});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // retrieve the process args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // extract the config file path
    var configPath: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i < args.len) {
                configPath = args[i];
            }
        }
    }

    if (configPath == null) {
        log.err("--config path requird", .{});
        return;
    }

    // read the contents of the config file
    const config_content = try std.fs.cwd().readFileAlloc(allocator, configPath.?, 4096);
    defer allocator.free(config_content);

    // parse the config file
    const conf = try config.parseConfig(allocator, config_content);
    defer allocator.free(conf.content_dir);
    defer allocator.free(conf.output_dir);

    // clear the dist/ folder
    fs.deleteTreeAbsolute(conf.output_dir) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try fs.cwd().makePath(conf.output_dir);

    try copyStaticFile(allocator, conf.output_dir, "index.html");

    try copyStaticFile(allocator, conf.output_dir, "uses.html");

    const content_dir = try fs.openDirAbsolute(conf.content_dir, .{ .iterate = true });
    var posts = try parseContent(allocator, content_dir);

    try buildWritingPage(allocator, posts, conf.output_dir);

    try buildPostPages(allocator, posts, conf.output_dir);

    defer {
        for (posts.items) |post| {
            allocator.free(post.html);
            allocator.free(post.raw);
            allocator.free(post.path);
        }
        posts.deinit(allocator);
    }
}

fn parseContent(gpa: std.mem.Allocator, dir: fs.Dir) !std.ArrayListUnmanaged(Post) {
    var output: std.ArrayListUnmanaged(Post) = .{};
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        const raw = try file.readToEndAlloc(gpa, 1024 * 1024);
        const path = try gpa.dupe(u8, entry.path);
        defer gpa.free(path);
        const post = try parsePostMarkdown(gpa, raw, path);
        try output.append(gpa, post);
    }
    return output;
}

fn parsePostMarkdown(gpa: std.mem.Allocator, raw: []const u8, path: []const u8) !Post {
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

    const path_html = try std.mem.replaceOwned(u8, gpa, path, ".md", ".html");
    const content = after_first[second_fence_idx + 3 ..];
    const html = try cmark.markdownToHtml(gpa, content);
    return Post{ .raw = raw, .path = path_html, .title = title, .date = date, .slug = slug, .html = html };
}
