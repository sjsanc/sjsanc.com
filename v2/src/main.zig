const std = @import("std");
const fs = std.fs;
const log = std.log;
const v2 = @import("v2");
const cmark = @import("cmark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const contentDir = "/home/sjsanc/.vault/writing/articles";
    const buildDir = "/tmp/sjsanc.com/dist";

    fs.deleteTreeAbsolute(buildDir) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try fs.cwd().makePath(buildDir);

    const dir = try fs.openDirAbsolute(contentDir, .{ .iterate = true });
    try walk(dir, buildDir, allocator);

    try v2.bufferedPrint();
}

fn walk(dir: fs.Dir, outputPath: []const u8, allocator: std.mem.Allocator) anyerror!void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == fs.File.Kind.directory) {
            const outputSubDir = try std.fs.path.join(allocator, &.{ outputPath, entry.name });
            defer allocator.free(outputSubDir);

            try std.fs.cwd().makePath(outputSubDir);

            const subDir = try dir.openDir(entry.name, .{ .iterate = true });
            try walk(subDir, outputSubDir, allocator);
        } else if (std.mem.endsWith(u8, entry.name, ".md")) {
            log.info("processing: {s}", .{entry.name});

            const file = try dir.openFile(entry.name, .{});
            defer file.close();

            const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
            defer allocator.free(raw);

            const html = try cmark.markdownToHtml(allocator, raw);
            defer allocator.free(html);

            const baseName = entry.name[0 .. entry.name.len - 3];
            const outputFileName = try std.fmt.allocPrint(allocator, "{s}.html", .{baseName});
            defer allocator.free(outputFileName);

            const outputFile = try std.fs.path.join(allocator, &.{ outputPath, outputFileName });
            defer allocator.free(outputFile);

            const f = try fs.createFileAbsolute(outputFile, .{});
            defer f.close();
            try f.writeAll(html);

            log.info("wrote: {s}", .{outputFile});
        }
    }
}
