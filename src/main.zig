const std = @import("std");
const assert = std.debug.assert;
const AutoContext = std.hash_map.AutoContext;
const heap = std.heap;
const http = std.http;
const testing = std.testing;
const Uri = std.Uri;

const DownloadError = error{
    MissingContentRange,
};

export fn download(url: [*]const u8, filename: [*]const u8, max_file_handles: u16, chunk_size: u32, max_retries: u16, headers: *std.StringHashMap([]const u8)) !void {
    _ = max_retries;
    _ = chunk_size;
    _ = max_file_handles;
    _ = filename;
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try Uri.parse(url);
    var content_range_headers = http.Headers{ .allocator = allocator };
    var items = try headers.iterator();
    while (try items.next()) |item| {
        content_range_headers.append(item.key_ptr.*, item.value_ptr.*);
    }
    try content_range_headers.append("Content-range", "bytes=0-0");
    var request = try client.request(.GET, uri, headers, .{});
    defer request.deinit();
    request.start();
    request.wait();
    const content_range = try request.response.headers.getFirstValue(.CONTENT_RANGE) catch {
        return DownloadError.MissingContentRange;
    };
    std.debug.print("content range: {s}", .{content_range});
    return;
}

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "simple download" {
    try download(&"https://huggingface.co/mcpotato/42-eicar-street/resolve/main/eicar_test_file", "eicar_test_file", 16, 10_485_760, 5, .{});
}
