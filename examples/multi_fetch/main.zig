const std = @import("std");
const writer = std.io.getStdOut().writer();

const Client = @import("tardy_http_client");

const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;
const Timer = @import("tardy").Timer;

const CLIENT_STACK_SIZE: usize = 2 << 20; // 2 MiB stack size for each client task (seems like a lot, but 1 MiB crashes for HTTPS endpoints...).

pub const std_options: std.Options = .{ .log_level = .warn };
const log = std.log.scoped(.@"tardy-http-client/example/multi_fetch");

const Context = struct {
    client: Client,
    allocator: std.mem.Allocator,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var context = Context{
        .client = .{ .allocator = alloc },
        .allocator = alloc,
    };
    var tardy = try Tardy.init(alloc, .{
        //.threading = .{ .multi = 2 },
        .threading = .single,
        .pooling = .grow,
        .size_tasks_initial = 16,
        .size_aio_reap_max = 16,
    });
    defer tardy.deinit();

    try tardy.entry(
        &context,
        struct {
            fn start(rt: *Runtime, c: *Context) !void {
                try rt.spawn(.{ rt, c }, main_frame, 1024 * 32);
            }
        }.start,
    );
}

fn main_frame(rt: *Runtime, context: *Context) !void {
    // Spin up a bunch of requests.
    var count: u32 = 1;
    while (count <= 16) : (count += 1) {
        std.debug.print("Spawning task {}\n", .{count});
        var arena = std.heap.ArenaAllocator.init(context.allocator);
        const url = try std.fmt.allocPrint(arena.allocator(), "https://jsonplaceholder.typicode.com/posts/{}", .{count});

        try rt.spawn(.{ rt, &context.client, arena, url }, fetch_frame, CLIENT_STACK_SIZE);
    }
}

fn fetch_frame(rt: *Runtime, client: *Client, arena: std.heap.ArenaAllocator, url: []u8) !void {
    var a = arena;
    defer a.deinit();
    const alloc = a.allocator();

    const headers = &[_]std.http.Header{
        .{ .name = "User-Agent", .value = "tardy-http-client-multi_fetch" },
    };
    for (0..3) |i| {
        const response = get(rt, url, headers, client, alloc) catch |err| {
            if (i == 2) {
                std.debug.print("Failed to fetch {s} after 3 attempts: {}\n", .{ url, err });
                return err; // Return the error if all retries fail.
            }
            const base_time = 500 + std.crypto.random.intRangeAtMost(usize, 0, 250); // Add some randomness to backoff to spread out retries.
            const backoff_time = base_time * std.math.pow(usize, 2, i);
            std.debug.print("{} fetching: {s}. Retry #{} in {} ms\n", .{ err, url, i + 1, backoff_time });
            // Retries with exponential backoff
            try Timer.delay(rt, .{ .nanos = std.time.ns_per_ms * backoff_time });
            continue;
        };

        const Result = struct {
            userId: i32,
            id: i32,
            title: []u8,
            body: []u8,
        };
        const result = try std.json.parseFromSlice(Result, alloc, response.items, .{ .ignore_unknown_fields = true });

        std.debug.print("\nURL: {s}\nTitle: {s}\n\n", .{ url, result.value.title });
        return;
    }
}

fn get(
    rt: *Runtime,
    url: []const u8,
    headers: []const std.http.Header,
    client: *Client,
    allocator: std.mem.Allocator,
) !std.ArrayList(u8) {
    var response_body = std.ArrayList(u8).init(allocator);
    errdefer response_body.deinit();

    std.debug.print("Sending GET request: {s}\n", .{url});
    const response = try client.fetch(rt, .{
        .method = .GET,
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_storage = .{ .dynamic = &response_body },
    });
    switch (response.status.class()) {
        .server_error => return error.ServerError,
        .client_error => return error.ClientError,
        else => {},
    }
    return response_body;
}
