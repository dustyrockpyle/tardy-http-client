const std = @import("std");
const builtin = @import("builtin");

const Runtime = @import("tardy").Runtime;
const Timer = @import("tardy").Timer;

const Client = @import("tardy_http_client");
pub const AsyncQueue = Client.AsyncQueue;

pub const THREAD_COUNT = 8;
const WORKERS_PER_THREAD = 16;
const WORKER_COUNT = THREAD_COUNT * WORKERS_PER_THREAD;
const TIMEOUT_MS = 3_000;

const URL_TO_SCRAPE = "http://toscrape.com/";

const Atomic = std.atomic.Value;

const ScrapedUrlQueue = AsyncQueue([]u8);

const Self = @This();

allocator: std.mem.Allocator,
client: Client,
fetch_task_queue: Client.FetchTaskQueue,
fetch_result_queue: Client.FetchResultQueue,
scraped_url_queue: ScrapedUrlQueue,
fail_count: Atomic(usize) align(std.atomic.cache_line) = .{ .raw = 0 },
success_count: Atomic(usize) align(std.atomic.cache_line) = .{ .raw = 0 },
url_count: Atomic(usize) align(std.atomic.cache_line) = .{ .raw = 0 },
active_fetchers: Atomic(usize) align(std.atomic.cache_line) = .{ .raw = 0 },

pub fn init(alloc: std.mem.Allocator) !Self {
    var result = Self{
        .allocator = alloc,
        .client = .{ .allocator = alloc },
        .fetch_task_queue = try .init(alloc, WORKER_COUNT * 4, WORKER_COUNT),
        .fetch_result_queue = try .init(alloc, WORKER_COUNT * 4, WORKER_COUNT),
        .scraped_url_queue = try .init(alloc, WORKER_COUNT * 8, WORKER_COUNT),
    };
    try result.pushStartUrl(URL_TO_SCRAPE);
    return result;
}

pub fn pushStartUrl(self: *Self, url: []const u8) !void {
    const url_len = url.len + 1; // +1 for null terminator
    const url_buffer = try self.allocator.alloc(u8, url_len);
    @memcpy(url_buffer[0..url.len], url);
    url_buffer[url.len] = 0; // Null-terminate
    try self.scraped_url_queue.pushNoWait(url_buffer);
}

pub fn deinit(self: *Self) void {
    self.fetch_task_queue.deinit();
    self.fetch_result_queue.deinit();
    self.scraped_url_queue.deinit();
    self.client.deinit();
}

pub fn start(rt: *Runtime, context: *Self) !void {
    switch (rt.id) {
        // One thread dedicated to fingerprinting + stats printing
        0 => {
            try rt.spawn(.{ rt, context }, fingerprintUrls, 1024 * 32);
            try rt.spawn(.{ rt, context }, statsFrame, 1024 * 32);
        },
        // One thread dedicated to scraping links from fetch results
        1 => try rt.spawn(.{ rt, context }, linkScraperFrame, 1024 * 32),
        // Spawn a bunch of fetch workers on the remaining threads.
        else => for (0..WORKERS_PER_THREAD) |_| {
            try rt.spawn(.{ rt, context }, fetchWorkerWrapper, Client.FETCH_STACK_SIZE);
        },
    }
}

pub fn statsFrame(rt: *Runtime, context: *Self) !void {
    var total_failures: usize = 0;
    var total_successes: usize = 0;
    var current_time: i64 = std.time.milliTimestamp();
    var start_time = current_time;
    std.debug.print("\nStarting URL crawling for {s}\n\n", .{URL_TO_SCRAPE});
    while (true) {
        try Timer.delay(rt, .{ .nanos = std.time.ns_per_s * 5 });
        const fail_count = context.fail_count.swap(0, .monotonic);
        const success_count = context.success_count.swap(0, .monotonic);
        const pending_fetch = context.fetch_task_queue.approxLen();
        const pending_scrape = context.fetch_result_queue.approxLen();
        const pending_url = context.scraped_url_queue.approxLen();
        total_failures += fail_count;
        total_successes += success_count;
        std.debug.print("\nStats: Failures: {}, Successes: {} Pending (Fetch: {} Scrape: {} Fingerprint: {})\n\n", .{ total_failures, total_successes, pending_fetch, pending_scrape, pending_url });
        current_time = std.time.milliTimestamp();

        // Timeout after no progress for a while
        if ((success_count == 0 and fail_count == 0) and current_time - start_time > TIMEOUT_MS) {
            break;
        } else if (success_count > 0) {
            start_time = current_time;
        }
    }
    std.debug.print("\nNo progress made in awhile, so signaling a shutdown. Total successes: {}, Total failures: {}\n\n", .{ total_successes, total_failures });
    context.scraped_url_queue.shutdown();
    context.fetch_result_queue.shutdown();
    context.fetch_task_queue.shutdown();
    // Wait for all fetchers to shutdown.
    var fetcher_count = context.active_fetchers.load(.monotonic);
    while (fetcher_count > 0) : (fetcher_count = context.active_fetchers.load(.monotonic)) {
        std.debug.print("\nWaiting for: {} fetchers to shutdown.\n\n", .{context.active_fetchers.load(.monotonic)});
        try Timer.delay(rt, .{ .nanos = std.time.ns_per_ms * 500 });
    }
    context.client.deinit();
}

pub fn fingerprintUrls(rt: *Runtime, context: *Self) !void {
    const stdout = std.io.getStdOut().writer();
    const input = &context.scraped_url_queue;
    const output = &context.fetch_task_queue;

    var fingerprints: std.AutoHashMap(usize, void) = .init(context.allocator);
    defer fingerprints.deinit();

    while (true) {
        const urls = input.pop(rt) catch |err| {
            if (err == error.Shutdown) return;
            return err;
        };
        defer context.allocator.free(urls);
        var remaining_url: []const u8 = urls[0..];

        // Push a fetch task for each new URL, and print it to stdout.
        while (remaining_url.len > 0) {
            const len = std.mem.indexOfScalar(u8, remaining_url, 0) orelse break;
            const url = remaining_url[0..len];
            remaining_url = remaining_url[len + 1 ..]; // Skip the null terminator
            if (url.len == 0) continue; // Skip empty URLs. This shouldn't happen.
            const fp: u64 = std.hash_map.hashString(url);
            if ((try fingerprints.getOrPut(fp)).found_existing) continue;
            const storage = try context.allocator.create(std.ArrayList(u8));
            storage.* = std.ArrayList(u8).init(context.allocator);
            const task = Client.FetchTask{
                .options = try context.allocator.create(Client.FetchOptions),
            };
            task.options.* = .{
                .method = .GET,
                .location = .{ .url = try context.allocator.dupe(u8, url) },
                .response_storage = .{ .dynamic = storage },
                .retry_attempts = 1,
                .retry_delay = 250,
            };
            try stdout.print("{s}\n", .{url});
            try output.push(rt, task);
        }
    }
}

pub fn fetchWorkerWrapper(rt: *Runtime, context: *Self) !void {
    _ = context.active_fetchers.fetchAdd(1, .monotonic);
    defer _ = context.active_fetchers.fetchSub(1, .monotonic);
    try context.client.spawnFetchWorker(rt, &context.fetch_task_queue, &context.fetch_result_queue);
}

pub fn linkScraperFrame(rt: *Runtime, context: *Self) !void {
    const input = &context.fetch_result_queue;
    const output = &context.scraped_url_queue;
    while (true) {
        var task_result = input.pop(rt) catch |err| switch (err) {
            error.Shutdown => return,
            else => |e| return e,
        };
        defer task_result.deinit(context.allocator);
        const fetch_result = task_result.result catch |err| switch (err) {
            error.Shutdown => continue,
            else => {
                _ = context.fail_count.fetchAdd(1, .monotonic);
                continue;
            },
        };
        if (fetch_result.status.class() != .success) {
            _ = context.fail_count.fetchAdd(1, .monotonic);
            continue;
        }
        _ = context.success_count.fetchAdd(1, .monotonic);
        const body = switch (task_result.task.options.response_storage) {
            .dynamic => |dynamic| dynamic.items,
            .static => |static| static.items,
            else => "",
        };
        const base_url = task_result.task.options.location.url;
        const base_uri = try std.Uri.parse(base_url);

        // Extract URLs from the response body

        var index: usize = 0;
        var url_count: usize = 0;
        var urls: [16][]const u8 = undefined;
        var url_buffer: [4096]u8 = undefined;

        while (index < body.len) {
            // Find URLS by looking for href attributes in the HTML. Who needs a real parser for a toy example
            const href_index = std.mem.indexOf(u8, body[index..], "href=") orelse break;
            index += href_index;

            const endChar = body[index + 5];
            index += 6; // Move past "href='"
            const relative_end = std.mem.indexOfScalar(u8, body[index..], endChar) orelse continue;
            const end = index + relative_end;
            const url = body[index..end];
            index = end + 1; // Skip null terminator

            // Skip empty URLs or fragments only
            if (url.len == 0 or url[0] == '#') continue;

            const validated_url = validateAndResolveUrl(context.allocator, base_uri, url, &url_buffer) catch {
                continue;
            };

            urls[url_count] = validated_url;
            url_count += 1;

            if (url_count == 16) {
                // Push URLs in max batch size of 16 to avoid starvation.
                try pushUrls(rt, context.allocator, output, urls[0..16]);
                url_count = 0;
            }
        }
        if (url_count > 0) {
            try pushUrls(rt, context.allocator, output, urls[0..url_count]);
        }
    }
}

pub fn pushUrls(rt: *Runtime, alloc: std.mem.Allocator, queue: *ScrapedUrlQueue, urls: []const []const u8) !void {
    var size: usize = 0;
    for (urls) |url| {
        size += url.len + 1; // +1 for null terminator
    }
    const dest = try alloc.alloc(u8, size);
    size = 0;
    for (urls) |url| {
        @memcpy(dest[size .. size + url.len], url);
        dest[size + url.len] = 0; // Null-terminate the URL
        size += url.len + 1;
    }
    try queue.push(rt, dest);
}

//
// NOTE: Couldn't be asked to validate the URLs myself, and didn't want to add any dependencies so
// Claude wrote most of the code below. You can tell because it's well commented and that's not my "style".
//

// File extensions we consider as HTML-related content
const html_extensions = [_][]const u8{ ".html", ".htm", ".xhtml", ".php", ".asp", ".aspx", ".jsp" };

// File extensions to skip (non-HTML content)
const skip_extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".ico", ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".zip", ".rar", ".gz", ".tar", ".7z", ".mp3", ".mp4", ".avi", ".mov", ".wmv", ".flv", ".css", ".js", ".json", ".xml", ".txt", ".csv", ".exe", ".dmg", ".pkg", ".deb", ".rpm" };

fn validateAndResolveUrl(allocator: std.mem.Allocator, base_uri: std.Uri, url: []const u8, buffer: []u8) ![]const u8 {
    // Use first half of buffer for resolution, second half for formatting
    const half_size = buffer.len / 2;
    var resolve_buffer = buffer[0..half_size];
    const format_buffer = buffer[half_size..];

    // Handle relative URLs
    const resolved_uri = if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) blk: {
        // Absolute URL
        break :blk try std.Uri.parse(url);
    } else blk: {
        // Relative URL - resolve against base
        const resolved = base_uri.resolve_inplace(url, &resolve_buffer) catch {
            // If resolution fails, skip this URL
            return error.InvalidUrl;
        };
        break :blk resolved;
    };

    // Check if the resolved URL has the same host as base
    const base_host = base_uri.host orelse return error.InvalidUrl;
    const resolved_host = resolved_uri.host orelse return error.InvalidUrl;

    // Get the raw host strings for comparison
    const base_host_str = switch (base_host) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
    const resolved_host_str = switch (resolved_host) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };

    // Compare hosts - allow same domain or subdomains
    if (!isSameDomainOrSubdomain(base_host_str, resolved_host_str)) {
        return error.InvalidUrl; // Different domain, skip
    }

    // Check file extension
    const path = switch (resolved_uri.path) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };

    // Check if it's a known non-HTML extension
    for (skip_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) {
            return error.InvalidUrl; // Skip non-HTML files
        }
    }

    // Check if it has an HTML extension (these are always allowed)
    var has_html_ext = false;
    for (html_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) {
            has_html_ext = true;
            break;
        }
    }

    // If no extension or HTML extension, consider it valid
    // (no extension often means it's a directory or dynamic content)
    const last_dot = std.mem.lastIndexOf(u8, path, ".");
    const last_slash = std.mem.lastIndexOf(u8, path, "/");
    const has_extension = if (last_dot) |dot_pos| blk: {
        if (last_slash) |slash_pos| break :blk dot_pos > slash_pos;
        break :blk true;
    } else false;

    if (!has_extension or has_html_ext) {
        // Format the final URL using the format buffer
        var stream = std.io.fixedBufferStream(format_buffer);
        try resolved_uri.format("", .{}, stream.writer());
        const final_url = stream.getWritten();

        // Allocate and return a copy
        const url_copy = try allocator.dupe(u8, final_url);
        return url_copy;
    }

    return error.InvalidUrl; // Has non-HTML extension
}

fn isSameDomainOrSubdomain(base_host: []const u8, test_host: []const u8) bool {
    // Simple approach: check if the test host is the same or ends with ".base_host"
    if (std.ascii.eqlIgnoreCase(base_host, test_host)) {
        return true;
    }

    // Check if test_host is a subdomain of base_host
    // e.g., "books.toscrape.com" is a subdomain of "toscrape.com"
    var pattern_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, ".{s}", .{base_host}) catch return false;

    return std.ascii.endsWithIgnoreCase(test_host, pattern);
}
