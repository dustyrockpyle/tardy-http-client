const std = @import("std");
const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;
const Client = @import("tardy_http_client");

pub const std_options: std.Options = .{ .log_level = .warn };

const Context = struct {
    allocator: std.mem.Allocator,
    url: []const u8 = "http://api.ipify.org?format=json",
};

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var context = Context{ .allocator = gpa };
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len >= 2) context.url = args[1];

    var tardy = try Tardy.init(gpa, .{ .threading = .single });
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

// Queries provided URL and prints the response.
fn main_frame(rt: *Runtime, context: *Context) !void {
    var client: Client = .{ .allocator = context.allocator };
    defer client.deinit();
    var response: std.ArrayList(u8) = .init(context.allocator);
    defer response.deinit();
    var future: Client.FutureFetchResult = .{};

    std.debug.print("\nSpawning fetch for: {s}\n", .{context.url});
    client.fetch(rt, &future, .{
        .method = .GET,
        .location = .{ .url = context.url },
        .response_storage = .{ .dynamic = &response },
        .retry_attempts = 3, // Default is 0 retries.
        .retry_delay = 250, // Default is 500 milliseconds,
        .retry_exponential_backoff_base = 2.0, // Default is 2.0
    }) catch |err| {
        std.debug.print("Error scheduling fetch: {}\n", .{err});
        try future.setCancelled();
    };

    std.debug.print("\nWaiting for response...\n\n", .{});

    const result = future.result(rt) catch |err| {
        std.debug.print("Fetch error: {}\n", .{err});
        return;
    };

    if (result.status.class() == .success) {
        std.debug.print("Fetch status: {} - {?s}\n", .{ @intFromEnum(result.status), result.status.phrase() });
        std.debug.print("Retry count: {}\n", .{result.retry_count});
        if (result.retry_status) |retry_status| std.debug.print("Retry status: {} {?s}\n", .{ @intFromEnum(retry_status), retry_status.phrase() });
        if (result.retry_error) |retry_err| std.debug.print("Retry error: {}\n", .{retry_err});
        std.debug.print("Body:\n\n{s}\n\n", .{response.items});
    } else {
        std.debug.print("Fetch Failed with status: {} - {?s}\n", .{ @intFromEnum(result.status), result.status.phrase() });
    }
}
