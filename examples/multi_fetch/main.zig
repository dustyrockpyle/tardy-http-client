const std = @import("std");
const builtin = @import("builtin");

const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;

const Client = @import("tardy_http_client");

const TASK_COUNT = 16;

pub const std_options: std.Options = .{ .log_level = .warn };
const log = std.log.scoped(.@"tardy-http-client/example/multi_fetch");

const Context = struct {
    allocator: std.mem.Allocator,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var context = Context{
        .allocator = gpa,
    };

    var tardy = try Tardy.init(gpa, .{
        //.threading = .{ .multi = 2 },
        .threading = .single,
        .pooling = .static,
        .size_tasks_initial = try std.math.ceilPowerOfTwo(usize, TASK_COUNT + 1),
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

// Spins up TASK_COUNT requests and prints out the results as they arrive.
fn main_frame(rt: *Runtime, context: *Context) !void {
    var client: Client = .{ .allocator = context.allocator };
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var futures: [TASK_COUNT]Client.FutureFetchResult = undefined;
    var responses: [TASK_COUNT]std.ArrayList(u8) = undefined;
    var completed: [TASK_COUNT]bool = undefined;
    for (0..TASK_COUNT) |task_id| {
        futures[task_id] = .init_with_notify(rt);
        responses[task_id] = .init(alloc);
        completed[task_id] = false;
        std.debug.print("Spawning task {}\n", .{task_id});
        const url = try std.fmt.allocPrint(alloc, "https://jsonplaceholder.typicode.com/posts/{}", .{task_id % 100 + 1});
        client.fetch(rt, &futures[task_id], .{
            .method = .GET,
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &responses[task_id] },
            .retry_attempts = 3,
        }) catch |err| {
            std.debug.print("Error scheduling task {}: {}\n", .{ task_id, err });
            try futures[task_id].setCancelled();
            completed[task_id] = true;
        };
    }

    std.debug.print("\n\nWaiting for responses...\n\n\n", .{});

    var complete_count: usize = 0;
    while (complete_count < TASK_COUNT) {
        try rt.scheduler.trigger_await();
        for (0..TASK_COUNT) |task_id| {
            const future = &futures[task_id];
            if (completed[task_id] or !future.done()) continue; // Skip already completed tasks.
            completed[task_id] = true;
            const result_status = future.result(rt) catch |err| {
                std.debug.print("Error fetching task {}: {}\n", .{ task_id, err });
                continue;
            };
            const Result = struct {
                userId: i32,
                id: i32,
                title: []u8,
                body: []u8,
            };
            if (result_status.status.class() == .success) {
                const response_body = &responses[task_id];
                const json = try std.json.parseFromSlice(Result, alloc, response_body.items, .{ .ignore_unknown_fields = true });
                std.debug.print("Task: {} Successful. Retries: {} Title: {s}\n", .{ task_id, result_status.retry_count, json.value.title });
            } else {
                std.debug.print("\nTask: {} Failed with status: {}\n", .{ task_id, result_status.status });
            }
        }
        const last_complete_count = complete_count;
        complete_count = 0;
        for (0..TASK_COUNT) |task_id| {
            if (completed[task_id]) complete_count += 1;
        }
        if (complete_count > last_complete_count) std.debug.print("\n{} / {} tasks completed.\n\n", .{ complete_count, TASK_COUNT });
    }
}
