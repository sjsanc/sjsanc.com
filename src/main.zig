const std = @import("std");
const fs = std.fs;
const log = std.log;
const config = @import("config.zig");
const parsers = @import("parsers.zig");
const builders = @import("builders.zig");

const Post = parsers.Post;

fn postHref(p: Post) []const u8 {
    return p.path;
}

fn postLabel(p: Post) []const u8 {
    return p.title;
}

fn postDate(p: Post) []const u8 {
    return p.date;
}

fn postDateDesc(_: void, a: Post, b: Post) bool {
    return std.mem.order(u8, a.date, b.date) == .gt;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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
        log.err("--config path required", .{});
        return;
    }

    const config_content = try fs.cwd().readFileAlloc(allocator, configPath.?, 4096);
    defer allocator.free(config_content);

    const conf = try config.parseConfig(allocator, config_content);
    defer allocator.free(conf.content_dir);
    defer allocator.free(conf.output_dir);

    // clear and recreate output dir
    fs.deleteTreeAbsolute(conf.output_dir) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try fs.cwd().makePath(conf.output_dir);

    // copy static assets (images, etc.) into output dir
    const static_images_src = "static/images";
    const static_images_dst = try std.fs.path.join(allocator, &.{ conf.output_dir, "images" });
    defer allocator.free(static_images_dst);
    try fs.cwd().makePath(static_images_dst);

    var img_dir = fs.cwd().openDir(static_images_src, .{ .iterate = true }) catch |err| blk: {
        if (err == error.FileNotFound) break :blk null;
        return err;
    } orelse null;

    if (img_dir) |*d| {
        defer d.close();
        var iter = d.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const src_path = try std.fs.path.join(allocator, &.{ static_images_src, entry.name });
            defer allocator.free(src_path);
            const dst_path = try std.fs.path.join(allocator, &.{ static_images_dst, entry.name });
            defer allocator.free(dst_path);
            try fs.cwd().copyFile(src_path, fs.cwd(), dst_path, .{});
        }
    }
    // Read the main layout template
    const layout = try fs.cwd().readFileAlloc(allocator, "templates/layout.html", 64 * 1024);
    defer allocator.free(layout);

    // static pages: file -> layout -> disk
    try builders.buildPage(allocator, layout, "static/html/index.html", conf.output_dir, "index.html", "index.html");
    try builders.buildPage(allocator, layout, "static/html/about.html", conf.output_dir, "about.html", "about.html");

    // parse markdown posts
    const content_dir = try fs.openDirAbsolute(conf.content_dir, .{ .iterate = true });
    var posts = try parsers.parseContent(allocator, content_dir);
    defer {
        for (posts.items) |post| {
            allocator.free(post.html);
            allocator.free(post.raw);
            allocator.free(post.path);
        }
        posts.deinit(allocator);
    }

    // Sort posts by date descending
    std.mem.sort(Post, posts.items, {}, postDateDesc);

    // Build the list of posts HTML grouped by year
    const post_list = try builders.buildPostListByYear(allocator, Post, posts.items, postHref, postLabel, postDate);
    defer allocator.free(post_list);

    // load the writing template
    const writing_template = try fs.cwd().readFileAlloc(allocator, "static/html/writing.html", 64 * 1024);
    defer allocator.free(writing_template);

    // insert the list of posts into the template
    const writing_content = try builders.replaceMarker(allocator, writing_template, "{{ content }}", post_list);
    defer allocator.free(writing_content);

    // insert the writing page into the layout
    const writing_with_content = try builders.replaceMarker(allocator, layout, "{{ content }}", writing_content);
    defer allocator.free(writing_with_content);

    const writing_page = try builders.replaceMarker(allocator, writing_with_content, "{{ path }}", "writing.html");
    defer allocator.free(writing_page);

    // write the page
    const writing_dest = try std.fs.path.join(allocator, &.{ conf.output_dir, "writing.html" });
    defer allocator.free(writing_dest);
    try builders.writeFile(allocator, writing_dest, writing_page);

    // post pages: each post's html -> post template -> layout -> disk
    const post_template = try fs.cwd().readFileAlloc(allocator, "templates/post.html", 64 * 1024);
    defer allocator.free(post_template);

    // create the posts dir
    const posts_dir = try std.fs.path.join(allocator, &.{ conf.output_dir, "posts" });
    defer allocator.free(posts_dir);
    try fs.cwd().makePath(posts_dir);

    // for each post
    for (posts.items) |post| {
        const with_title = try builders.replaceMarker(allocator, post_template, "{{ title }}", post.title);
        defer allocator.free(with_title);

        const in_template = try builders.replaceMarker(allocator, with_title, "{{ content }}", post.html);
        defer allocator.free(in_template);

        const with_content = try builders.replaceMarker(allocator, layout, "{{ content }}", in_template);
        defer allocator.free(with_content);

        const page = try builders.replaceMarker(allocator, with_content, "{{ path }}", post.path);
        defer allocator.free(page);

        const out_path = try std.fs.path.join(allocator, &.{ conf.output_dir, post.path });
        defer allocator.free(out_path);

        if (std.fs.path.dirname(out_path)) |dir| {
            try fs.cwd().makePath(dir);
        }

        try builders.writeFile(allocator, out_path, page);
        log.info("wrote: {s}", .{out_path});
    }
}
