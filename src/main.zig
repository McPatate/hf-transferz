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
    allocator: *const mem.Allocator,
    client: *http.Client,
    filename: []const u8,
    headers: *const []const http.Header,
    semaphore: *Thread.Semaphore,
    uri: *const Uri,
};

fn download(url: []const u8, filename: []const u8, max_file_handles: u16, chunk_size: u32, max_retries: u16, headers: []const http.Header) !void {
    _ = max_retries;
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try Uri.parse(url);
    var headers_with_content_range = std.ArrayList(http.Header).init(allocator);
    defer headers_with_content_range.deinit();
    try headers_with_content_range.appendSlice(headers);
    try headers_with_content_range.append(http.Header{ .name = "Range", .value = "bytes=0-0" });
    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .headers = .{ .authorization = .omit },
        .extra_headers = headers_with_content_range.items,
        .server_header_buffer = &server_header_buffer,
    });

    try req.send();
    try req.finish();
    try req.wait();

    assert(try req.response.parser.read(req.connection.?, &.{}, true) == 0);

    if (req.response.status != http.Status.partial_content) {
        std.log.err("[get_range] API response error, replied with status: {d}", .{req.response.status});
        return DownloadError.InvalidResponseStatus;
    }

    var header_iter = http.HeaderIterator.init(&server_header_buffer);
    var found = false;
    var content_range: []const u8 = undefined;
    while (header_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Content-range")) {
            found = true;
            content_range = header.value;
            break;
        }
    }

    if (!found) {
        return DownloadError.MissingContentRange;
    }

    req.deinit();

    var it = mem.split(u8, content_range, "/");
    var skip_first = true;
    var length: usize = undefined;
    while (it.next()) |chunk| {
        if (skip_first) {
            skip_first = false;
            continue;
        }
        length = try std.fmt.parseInt(usize, chunk, 10);
    }

    var pool: Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = max_file_handles, .allocator = allocator });
    defer pool.deinit();

    var semaphore = Thread.Semaphore{ .permits = max_file_handles };

    const ctx = SharedContext{
        .allocator = &allocator,
        .client = &client,
        .filename = filename,
        .headers = &headers,
        .semaphore = &semaphore,
        .uri = &uri,
    };

    var start: usize = 0;
    while (start < length) : (start += chunk_size) {
        const stop = @min(start + chunk_size - 1, length);
        try pool.spawn(
            downloadChunk,
            .{
                &ctx,
                start,
                stop,
            },
        );
    }

    return;
}

fn downloadChunk(ctx: *const SharedContext, start: usize, stop: usize) void {
    ctx.semaphore.wait();
    const range = std.fmt.allocPrint(ctx.allocator.*, "bytes={d}-{d}", .{ start, stop }) catch {
        std.log.err("[OOM] failed to allocate memory for range header", .{});
        return;
    };
    std.log.info("querying range: {s}", .{range});
    defer ctx.allocator.*.free(range);
    var server_header_buffer: [16 * 1024]u8 = undefined;
    var request = ctx.client.open(.GET, ctx.uri.*, .{
        .server_header_buffer = &server_header_buffer,
        .headers = .{ .authorization = .omit },
        .extra_headers = ctx.headers.*,
    }) catch |err| {
        std.log.err("error: {s}", .{@errorName(err)});
        return;
    };
    defer request.deinit();
    request.send() catch |err| {
        std.log.err("error: {s}", .{@errorName(err)});
        return;
    };
    request.wait() catch |err| {
        std.log.err("error: {s}", .{@errorName(err)});
        return;
    };

    if (request.response.status != http.Status.ok) {
        std.log.err("[chunk_download] API response error, replied with status: {d}", .{request.response.status});
        ctx.semaphore.post();
        return;
    }

    var file = if (ctx.filename.len > 0 and ctx.filename[0] == '/') fs.createFileAbsolute(ctx.filename, .{ .mode = 0o644, .truncate = false }) catch |err| {
        std.log.err("error: {s}", .{@errorName(err)});
        return;
    } else fs.cwd().createFile(ctx.filename, .{ .mode = 0o644, .truncate = false }) catch |err| {
        std.log.err("error: {s}", .{@errorName(err)});
        return;
    };
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var read_bytes: usize = 1;

    while (read_bytes > 0) {
        read_bytes = request.reader().read(buffer[0..]) catch |err| {
            std.log.err("error: {s}", .{@errorName(err)});
            return;
        };
        file.writeAll(buffer[0..read_bytes]) catch |err| {
            std.log.err("error: {s}", .{@errorName(err)});
            return;
        };
    }
    ctx.semaphore.post();
}

pub fn main() !void {
    var headers = [_]http.Header{};
    // const filename = "/tmp/eicar_test_file";
    const filename = "/tmp/model.safetensors";

    // try download("https://huggingface.co/mcpotato/42-eicar-street/resolve/main/eicar_test_file", filename, 16, 10_485_760, 5, &headers);
    try download("https://huggingface.co/google-bert/bert-base-uncased/resolve/main/model.safetensors", filename, 16, 10_485_760, 5, &headers);
}

test "simple download" {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const headers = [_]http.Header{};
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
