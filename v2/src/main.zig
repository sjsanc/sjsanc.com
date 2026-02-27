const std = @import("std");
const fs = std.fs;
const log = std.log;
const v2 = @import("v2");
const cmark = @import("cmark.zig");
const config = @import("config.zig");

// the build process:
// 1. clear the dist/ folder
// 2. create a dist/posts/ folder
// 3. copy static/html/*.html files to dist/ respecting relative paths
// 4. read post.html template into memory
// 5. in the loop, when we've got the parsed html, copy the template and replace {{ content }} with the html
// 6. copy the combined post into dist/posts

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

    // create posts subdir
    const posts_path = try std.fs.path.join(allocator, &.{ conf.output_dir, "posts" });
    defer allocator.free(posts_path);
    try fs.makeDirAbsolute(posts_path);

    // open static/html/ and copy every file into the output dir
    const static_html_dir = try fs.cwd().openDir("static/html", .{ .iterate = true });
    var static_it = static_html_dir.iterate();
    while (try static_it.next()) |entry| {
        if (entry.kind != .file) continue;

        // build absolute source path: static/html/<name>
        const src = try std.fs.path.join(allocator, &.{ "static/html", entry.name });
        defer allocator.free(src);

        // build absolute dest path: <output_dir>/<name>
        const dest = try std.fs.path.join(allocator, &.{ conf.output_dir, entry.name });
        defer allocator.free(dest);

        // copyFile works with Dir-relative paths
        try fs.cwd().copyFile(src, fs.cwd(), dest, .{});
        log.info("copied: {s}", .{dest});
    }

    // open static/css and copy every file to output dir
    const static_css_dir = try fs.cwd().openDir("static/css", .{ .iterate = true });
    var static_css_it = static_css_dir.iterate();
    while (try static_css_it.next()) |entry| {
        if (entry.kind != .file) continue;

        // build absolute source path: static/html/<name>
        const src = try std.fs.path.join(allocator, &.{ "static/css", entry.name });
        defer allocator.free(src);

        // build absolute dest path: <output_dir>/<name>
        const dest = try std.fs.path.join(allocator, &.{ conf.output_dir, entry.name });
        defer allocator.free(dest);

        // copyFile works with Dir-relative paths
        try fs.cwd().copyFile(src, fs.cwd(), dest, .{});
        log.info("copied: {s}", .{dest});
    }

    // read the post template into memory
    const template = try fs.cwd().readFileAlloc(allocator, "templates/post.html", 64 * 1024);
    defer allocator.free(template);

    const content_dir = try fs.openDirAbsolute(conf.content_dir, .{ .iterate = true });
    try walk(content_dir, posts_path, template, allocator);
}

fn walk(dir: fs.Dir, output_path: []const u8, template: []const u8, allocator: std.mem.Allocator) anyerror!void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            // recurse into subdirs
            const sub_output = try std.fs.path.join(allocator, &.{ output_path, entry.name });
            defer allocator.free(sub_output);
            try std.fs.cwd().makePath(sub_output);

            const sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            try walk(sub_dir, sub_output, template, allocator);
        } else if (std.mem.endsWith(u8, entry.name, ".md")) {
            log.info("processing: {s}", .{entry.name});

            // read the markdown
            const file = try dir.openFile(entry.name, .{});
            defer file.close();
            const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
            defer allocator.free(raw);

            // convert markdown to html
            const html = try cmark.markdownToHtml(allocator, raw);
            defer allocator.free(html);

            // locate {{ content }} in the template and splice in the html
            const marker = "{{ content }}";
            const marker_pos = std.mem.indexOf(u8, template, marker) orelse
                return error.TemplateMissingContentMarker;

            // build the full page: template[0..marker] ++ html ++ template[marker+len..]
            const before = template[0..marker_pos];
            const after = template[marker_pos + marker.len ..];
            const page = try std.mem.concat(allocator, u8, &.{ before, html, after });
            defer allocator.free(page);

            // write to <output_path>/<basename>.html
            const base_name = entry.name[0 .. entry.name.len - 3];
            const out_name = try std.fmt.allocPrint(allocator, "{s}.html", .{base_name});
            defer allocator.free(out_name);

            const out_path = try std.fs.path.join(allocator, &.{ output_path, out_name });
            defer allocator.free(out_path);

            const f = try fs.createFileAbsolute(out_path, .{});
            defer f.close();
            try f.writeAll(page);

            log.info("wrote: {s}", .{out_path});
        }
    }
}
