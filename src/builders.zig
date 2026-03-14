const std = @import("std");

/// Replace a {{ marker }} in a template string with content.
pub fn replaceMarker(gpa: std.mem.Allocator, template: []const u8, marker: []const u8, content: []const u8) ![]const u8 {
    const pos = std.mem.indexOf(u8, template, marker) orelse return error.TemplateMissingContentMarker;
    return std.mem.concat(gpa, u8, &.{ template[0..pos], content, template[pos + marker.len ..] });
}

/// Builds a page by reading content from a file and inserting {{ content }} into a layout template
pub fn buildPage(
    gpa: std.mem.Allocator,
    layout: []const u8,
    content_path: []const u8,
    output_dir: []const u8,
    name: []const u8,
    nav_path: []const u8,
) !void {
    const content = try std.fs.cwd().readFileAlloc(gpa, content_path, 64 * 1024);
    defer gpa.free(content);

    const with_content = try replaceMarker(gpa, layout, "{{ content }}", content);
    defer gpa.free(with_content);

    const page = try replaceMarker(gpa, with_content, "{{ path }}", nav_path);
    defer gpa.free(page);

    const minified = try collapseWhitespace(gpa, page);
    defer gpa.free(minified);

    const output_path = try std.fs.path.join(gpa, &.{ output_dir, name });
    defer gpa.free(output_path);

    const output = try std.fs.createFileAbsolute(output_path, .{});
    defer output.close();

    try output.writeAll(minified);
}

/// Builds a page with pre-rendered HTML inserted into {{ content }} in a layout
pub fn buildPageFromString(gpa: std.mem.Allocator, layout: []const u8, content_string: []const u8, output_path: []const u8) !void {
    const page = try replaceMarker(gpa, layout, "{{ content }}", content_string);
    defer gpa.free(page);

    const minified = try collapseWhitespace(gpa, page);
    defer gpa.free(minified);

    const output = try std.fs.createFileAbsolute(output_path, .{});
    defer output.close();

    try output.writeAll(minified);
}

/// Builds a list of HTML anchor tags
pub fn buildAnchorList(
    gpa: std.mem.Allocator,
    comptime T: type,
    items: []const T,
    comptime getHref: fn (T) []const u8,
    comptime postHref: fn (T) []const u8,
) ![]const u8 {
    var list_buf: std.ArrayListUnmanaged(u8) = .{};
    for (items) |item| {
        try list_buf.appendSlice(gpa, "<li><a href='");
        try list_buf.appendSlice(gpa, getHref(item));
        try list_buf.appendSlice(gpa, "'>");
        try list_buf.appendSlice(gpa, postHref(item));
        try list_buf.appendSlice(gpa, "</a></li>\n");
    }
    return list_buf.toOwnedSlice(gpa);
}

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

fn monthName(date: []const u8) []const u8 {
    // date format: YYYY-MM-DD
    if (date.len >= 7) {
        const mm = std.fmt.parseInt(u8, date[5..7], 10) catch return "";
        if (mm >= 1 and mm <= 12) return month_names[mm - 1];
    }
    return "";
}

/// Builds a post list grouped by year: <h2>YEAR</h2><ul class="list">...</ul>
pub fn buildPostListByYear(
    gpa: std.mem.Allocator,
    comptime T: type,
    items: []const T,
    comptime getHref: fn (T) []const u8,
    comptime getLabel: fn (T) []const u8,
    comptime getDate: fn (T) []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    var current_year: []const u8 = "";

    for (items) |item| {
        const date = getDate(item);
        const year = if (date.len >= 4) date[0..4] else "";

        if (!std.mem.eql(u8, year, current_year)) {
            if (current_year.len > 0) {
                try buf.appendSlice(gpa, "</ul>\n");
            }
            try buf.appendSlice(gpa, "<h2>");
            try buf.appendSlice(gpa, year);
            try buf.appendSlice(gpa, "</h2>\n<ul class=\"list\">\n");
            current_year = year;
        }

        try buf.appendSlice(gpa, "<li><a href=\"");
        try buf.appendSlice(gpa, getHref(item));
        try buf.appendSlice(gpa, "\">");
        try buf.appendSlice(gpa, getLabel(item));
        try buf.appendSlice(gpa, "</a><span>");
        try buf.appendSlice(gpa, monthName(date));
        try buf.appendSlice(gpa, "</span></li>\n");
    }

    if (current_year.len > 0) {
        try buf.appendSlice(gpa, "</ul>\n");
    }

    return buf.toOwnedSlice(gpa);
}

/// Collapse runs of whitespace (spaces, tabs, newlines) into a single space.
pub fn collapseWhitespace(gpa: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    var in_ws = false;
    for (input) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!in_ws) {
                try buf.append(gpa, ' ');
                in_ws = true;
            }
        } else {
            try buf.append(gpa, c);
            in_ws = false;
        }
    }
    return buf.toOwnedSlice(gpa);
}

pub fn writeFile(gpa: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const minified = try collapseWhitespace(gpa, content);
    defer gpa.free(minified);
    const f = try std.fs.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(minified);
}
