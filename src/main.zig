const std = @import("std");
const assert = std.debug.assert;
const AutoContext = std.hash_map.AutoContext;
const fs = std.fs;
const heap = std.heap;
const http = std.http;
const io = std.io;
const mem = std.mem;
const testing = std.testing;
const Thread = std.Thread;
const Uri = std.Uri;

const DownloadError = error{
    InvalidResponseStatus,
    MissingContentRange,
};

const SharedContext = struct {
    allocator: *mem.Allocator,
    client: *http.Client,
    filename: []const u8,
    headers: *http.Headers,
    semaphore: *Thread.Semaphore,
    uri: *Uri,
};

fn download(url: []const u8, filename: []const u8, max_file_handles: u16, chunk_size: u32, max_retries: u16, headers: *http.Headers) !void {
    _ = max_retries;
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try Uri.parse(url);
    var content_range_headers = http.Headers{ .allocator = allocator, .list = try headers.list.clone(allocator), .index = try headers.index.clone(allocator) };
    defer content_range_headers.deinit();
    try content_range_headers.append("Range", "bytes=0-0");
    var request = try client.request(.GET, uri, content_range_headers, .{});
    try request.start();
    try request.wait();

    if (request.response.status != http.Status.ok) {
        std.debug.print("[get_range] API response error, replied with status: {d}", .{request.response.status});
        return DownloadError.InvalidResponseStatus;
    }

    const content_range = request.response.headers.getFirstValue("Content-range") orelse return DownloadError.MissingContentRange;
    var it = mem.split(u8, content_range, "/");
    var skip_first = true;
    var length: usize = undefined;
    while (it.next()) |chunk| {
        if (skip_first) {
            skip_first = false;
            continue;
        }
        length = try std.fmt.parseInt(u8, chunk, 10);
    }

    request.deinit();

    var pool: Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = max_file_handles, .allocator = allocator });
    defer pool.deinit();

    var semaphore = Thread.Semaphore{ .permits = max_file_handles };

    var ctx = SharedContext{
        .client = &client,
        .filename = filename,
        .headers = headers,
        .semaphore = &semaphore,
        .uri = &uri,
    };

    var start: usize = 0;
    while (start < length) : (start += chunk_size) {
        const stop = @min(start + chunk_size - 1, length);
        try pool.spawn(
            downloadChunk,
            .{
                ctx,
                start,
                stop,
            },
        );
    }

    return;
}

fn downloadChunk(ctx: *SharedContext, start: usize, stop: usize) void {
    ctx.semaphore.wait();
    const range = try std.fmt.allocPrint(ctx.allocator.*, "bytes={d}-{d}", .{ start, stop });
    defer ctx.allocator.*.free(range);
    var request = try ctx.client.request(.GET, ctx.uri.*, ctx.headers.*, .{});
    defer request.deinit();
    try request.start();
    try request.wait();

    if (request.response.status != http.Status.ok) {
        std.debug.print("[chunk_download] API response error, replied with status: {d}", .{request.response.status});
        ctx.semaphore.post();
        return DownloadError.InvalidResponseStatus;
    }

    var file = if (ctx.filename.len > 0 and ctx.filename[0] == '/') try fs.createFileAbsolute(ctx.filename, .{ .mode = 0o644, .truncate = false }) else try fs.cwd().createFile(ctx.filename, .{ .mode = 0o644, .truncate = false });
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var read_bytes: usize = 1;

    while (read_bytes > 0) {
        read_bytes = try request.reader().read(buffer[0..]);
        try file.writeAll(buffer[0..read_bytes]);
    }
    ctx.semaphore.post();
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var headers = http.Headers.init(allocator);
    defer headers.deinit();
    const filename = "/tmp/eicar_test_file";

    try download("https://huggingface.co/mcpotato/42-eicar-street/resolve/main/eicar_test_file", filename, 16, 10_485_760, 5, &headers);
}

test "simple download" {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var headers = http.Headers.init(allocator);
    defer headers.deinit();
    const filename = "eicar_test_file";

    try download("https://huggingface.co/mcpotato/42-eicar-street/resolve/main/eicar_test_file", filename, 16, 10_485_760, 5, &headers);

    const file = try fs.cwd().openFile(filename, .{});
    const file_content = try file.reader().readAllAlloc(allocator, 8_192);
    defer allocator.free(file_content);
    file.close();
    try fs.cwd().deleteFile(filename);

    const value = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*\n\n";

    assert(mem.eql(u8, file_content, value));
}
