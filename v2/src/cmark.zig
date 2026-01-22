const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("cmark.h");
});

pub fn markdownToHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    const html_ptr = c.cmark_markdown_to_html(
        markdown.ptr,
        markdown.len,
        c.CMARK_OPT_DEFAULT,
    );

    if (html_ptr == null) return error.MarkdownConversionFailed;

    const html_len = std.mem.len(html_ptr);
    const html = html_ptr[0..html_len];

    const result = try allocator.dupe(u8, html);

    c.free(html_ptr);

    return result;
}
