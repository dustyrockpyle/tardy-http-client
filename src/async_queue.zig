const std = @import("std");
const Runtime = @import("tardy").Runtime;
const Timer = @import("tardy").Timer;
const assert = std.debug.assert;
const Queue = @import("./queue.zig").Queue;
pub const PopError = @import("./queue.zig").PopError;
pub const PushError = @import("./queue.zig").PushError;

const Atomic = std.atomic.Value;

pub fn AsyncQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const ToNotify = struct {
            task: usize,
            runtime: *Runtime,

            pub fn init(rt: *Runtime) ToNotify {
                return .{ .task = rt.current_task.?, .runtime = rt };
            }

            pub fn triggerWake(self: *const ToNotify) void {
                self.runtime.scheduler.trigger(self.task) catch unreachable;
                self.runtime.wake() catch unreachable;
            }
        };

        allocator: std.mem.Allocator,
        pending_pops: Queue(ToNotify) align(std.atomic.cache_line),
        pending_pushes: Queue(ToNotify) align(std.atomic.cache_line),
        queue: Queue(T) align(std.atomic.cache_line),
        is_running: Atomic(bool) align(std.atomic.cache_line) = .{ .raw = true },

        pub fn init(allocator: std.mem.Allocator, size: usize, worker_max_size: usize) !Self {
            return .{
                .allocator = allocator,
                .pending_pops = try .init(allocator, worker_max_size),
                .pending_pushes = try .init(allocator, worker_max_size),
                .queue = try .init(allocator, size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending_pops.deinit();
            self.pending_pushes.deinit();
            self.queue.deinit();
        }

        pub fn shutdown(self: *Self) void {
            self.is_running.store(false, .seq_cst);
            // Wake up any pending pushes. Should probably only support shutdown after all producers are done?
            while (self.pending_pushes.pop()) |notify| {
                notify.triggerWake();
            } else |_| {}
            // Wake up any pending pops
            while (self.pending_pops.pop()) |notify| {
                notify.triggerWake();
            } else |_| {}
        }

        pub fn pushNoWait(self: *Self, item: T) PushError!void {
            try self.queue.push(item);
            if (self.pending_pops.pop()) |notify| {
                notify.triggerWake();
            } else |_| {}
        }

        pub fn push(self: *Self, rt: *Runtime, item: T) !void {
            self.pushNoWait(item) catch {
                // Queue is full, we need to wait for space.
                while (self.is_running.load(.acquire)) {
                    // If we fail to push the notify... return an error I guess. We should probably use a growable
                    // queue instead for the pending notifies.
                    self.pending_pushes.push(.init(rt)) catch return error.InsufficientNotifySpace;
                    try rt.scheduler.trigger_await();
                    return self.pushNoWait(item) catch continue;
                }
            };
        }

        pub fn popNoWait(self: *Self) PopError!T {
            const result = try self.queue.pop();
            if (self.pending_pushes.pop()) |notify| {
                notify.triggerWake();
            } else |_| {}
            return result;
        }

        pub fn pop(self: *Self, rt: *Runtime) !T {
            return self.popNoWait() catch {
                // Queue is empty, we need to wait for an item.
                while (self.is_running.load(.acquire)) {
                    // If we fail to pop the notify... return an error I guess. We should probably use a grow style
                    // queue instead for the pending notifies.
                    self.pending_pops.push(.init(rt)) catch return error.InsufficientNotifySpace;
                    try rt.scheduler.trigger_await();
                    return self.popNoWait() catch continue;
                }
                return error.Shutdown;
            };
        }

        // Drain the queue without blocking
        pub fn drainNoWait(self: *Self, buffer: []T) usize {
            var count: usize = 0;
            while (count < buffer.len) {
                if (self.popNoWait()) |item| {
                    buffer[count] = item;
                    count += 1;
                } else |_| break;
            }
            return count;
        }

        // Get approximate number of items (may be stale in concurrent environment)
        pub fn approxLen(self: *Self) usize {
            return self.queue.approxLen();
        }
    };
}

// Test context for async operations
const TestContext = struct {
    allocator: std.mem.Allocator,
    queue: *AsyncQueue(u32),
    errors: std.ArrayList(anyerror),

    fn init(allocator: std.mem.Allocator, queue: *AsyncQueue(u32)) TestContext {
        return .{
            .allocator = allocator,
            .queue = queue,
            .errors = std.ArrayList(anyerror).init(allocator),
        };
    }

    fn deinit(self: *TestContext) void {
        self.errors.deinit();
    }
};

const testing = std.testing;
const Tardy = @import("tardy").Tardy(.auto);

test "AsyncQueue: Basic init and deinit" {
    var queue = try AsyncQueue(u32).init(testing.allocator, 16, 64);
    defer queue.deinit();

    // Should start in empty state
    try testing.expectError(error.QueueEmpty, queue.popNoWait());
}

test "AsyncQueue: Push and pop without blocking" {
    var queue = try AsyncQueue(u32).init(testing.allocator, 16, 64);
    defer queue.deinit();

    // Push some items
    try queue.pushNoWait(42);
    try queue.pushNoWait(43);
    try queue.pushNoWait(44);

    // Pop them back
    try testing.expectEqual(@as(u32, 42), try queue.popNoWait());
    try testing.expectEqual(@as(u32, 43), try queue.popNoWait());
    try testing.expectEqual(@as(u32, 44), try queue.popNoWait());

    // Should be empty
    try testing.expectError(error.QueueEmpty, queue.popNoWait());
}

test "AsyncQueue: Blocking push and pop" {
    var tardy = try Tardy.init(testing.allocator, .{ .threading = .{ .multi = 2 } });
    defer tardy.deinit();

    const Context = struct {
        queue: *AsyncQueue(u32),
        done: bool = false,
    };

    var queue = try AsyncQueue(u32).init(testing.allocator, 4, 2);
    defer queue.deinit();

    var ctx = Context{ .queue = &queue };

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            switch (rt.id) {
                0 => try rt.spawn(.{ rt, c }, producer, 1024 * 16),
                1 => try rt.spawn(.{ rt, c }, consumer, 1024 * 16),
                else => unreachable,
            }
        }

        fn producer(rt: *Runtime, c: *Context) !void {
            try c.queue.push(rt, 1);
            try c.queue.push(rt, 2);
            try c.queue.push(rt, 3);
            try c.queue.push(rt, 4);
            try c.queue.push(rt, 5);
            c.done = true;
            c.queue.shutdown();
        }

        fn consumer(rt: *Runtime, c: *Context) !void {
            try testing.expectEqual(@as(u32, 1), try c.queue.pop(rt));
            try testing.expectEqual(@as(u32, 2), try c.queue.pop(rt));
            try testing.expectEqual(@as(u32, 3), try c.queue.pop(rt));
            try testing.expectEqual(@as(u32, 4), try c.queue.pop(rt));
            try testing.expectEqual(@as(u32, 5), try c.queue.pop(rt));
        }
    }.start);

    try testing.expect(ctx.done);
}

test "AsyncQueue: Multiple producers and consumers on same thread" {
    const num_threads = 4;
    const workers_per_thread = 2;
    const num_workers = num_threads * workers_per_thread;

    var tardy = try Tardy.init(testing.allocator, .{ .threading = .{ .multi = num_threads } });
    defer tardy.deinit();

    const Context = struct {
        queue: *AsyncQueue(u32),
        sum: std.atomic.Value(u64) = .{ .raw = 0 },
        done_producers: std.atomic.Value(u32) = .{ .raw = 0 },
        done_consumers: std.atomic.Value(u32) = .{ .raw = 0 },
    };

    var queue = try AsyncQueue(u32).init(testing.allocator, 64, num_workers * 2);
    defer queue.deinit();

    var ctx = Context{ .queue = &queue };

    const items_per_producer = 10000;

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            for (0..workers_per_thread) |_| {
                // Spawn producers and consumers for each worker
                try rt.spawn(.{ rt, c }, producer, 65536);
                try rt.spawn(.{ rt, c }, consumer, 65536);
            }
        }

        fn producer(rt: *Runtime, c: *Context) !void {
            for (0..items_per_producer) |_| {
                try c.queue.push(rt, @intCast(rt.id + 1));
            }
            if (c.done_producers.fetchAdd(1, .acq_rel) + 1 == num_workers) {
                c.queue.shutdown();
            }
        }

        fn consumer(rt: *Runtime, c: *Context) !void {
            while (true) {
                if (c.queue.pop(rt)) |val| {
                    _ = c.sum.fetchAdd(val, .acq_rel);
                } else |_| {
                    // Error means we're finished (or worse).
                    break;
                }
            }
            _ = c.done_consumers.fetchAdd(1, .acq_rel);
        }
    }.start);

    // Verify all consumers finished
    try testing.expectEqual(num_workers, ctx.done_consumers.load(.acquire));

    // Verify sum is correct
    var expected_sum: u64 = 0;
    for (0..num_threads) |thread_id| {
        expected_sum += (thread_id + 1) * items_per_producer * workers_per_thread;
    }
    try testing.expectEqual(expected_sum, ctx.sum.load(.acquire));
}

test "AsyncQueue: Single producers and consumers on separate threads" {
    const num_threads = 8;
    const num_workers = num_threads / 2;

    var tardy = try Tardy.init(testing.allocator, .{ .threading = .{ .multi = num_threads } });
    defer tardy.deinit();

    const Context = struct {
        queue: *AsyncQueue(u32),
        sum: std.atomic.Value(u64) = .{ .raw = 0 },
        done_producers: std.atomic.Value(u32) = .{ .raw = 0 },
        done_consumers: std.atomic.Value(u32) = .{ .raw = 0 },
    };

    var queue = try AsyncQueue(u32).init(testing.allocator, 64, num_workers * 2);
    defer queue.deinit();

    var ctx = Context{ .queue = &queue };

    const items_per_producer = 10000;

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            if (rt.id % 2 == 0) {
                // Even threads are producers
                try rt.spawn(.{ rt, c }, producer, 65536);
            } else {
                // Odd threads are consumers
                try rt.spawn(.{ rt, c }, consumer, 65536);
            }
        }

        fn producer(rt: *Runtime, c: *Context) !void {
            for (0..items_per_producer) |_| {
                try c.queue.push(rt, @intCast(rt.id + 1));
            }
            if (c.done_producers.fetchAdd(1, .acq_rel) + 1 == num_workers) {
                c.queue.shutdown();
            }
        }

        fn consumer(rt: *Runtime, c: *Context) !void {
            while (true) {
                if (c.queue.pop(rt)) |val| {
                    _ = c.sum.fetchAdd(val, .acq_rel);
                } else |_| {
                    // Error means we're finished (or worse).
                    break;
                }
            }
            _ = c.done_consumers.fetchAdd(1, .acq_rel);
        }
    }.start);

    // Verify all consumers finished
    try testing.expectEqual(num_workers, ctx.done_consumers.load(.acquire));

    // Verify sum is correct
    var expected_sum: u64 = 0;
    for (0..num_workers) |worker_id| {
        expected_sum += (worker_id * 2 + 1) * items_per_producer;
    }
    try testing.expectEqual(expected_sum, ctx.sum.load(.acquire));
}

test "AsyncQueue: Drain operation" {
    var queue = try AsyncQueue(u32).init(testing.allocator, 16, 64);
    defer queue.deinit();

    // Push some items
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try queue.pushNoWait(i);
    }

    // Drain them
    var buffer: [20]u32 = undefined;
    const count = queue.drainNoWait(&buffer);

    try testing.expectEqual(@as(usize, 10), count);

    // Verify values
    i = 0;
    while (i < count) : (i += 1) {
        try testing.expectEqual(i, buffer[i]);
    }

    // Queue should be empty
    try testing.expectError(error.QueueEmpty, queue.popNoWait());
}

test "AsyncQueue: Approximate length" {
    var queue = try AsyncQueue(u32).init(testing.allocator, 16, 4);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 0), queue.approxLen());

    try queue.pushNoWait(1);
    try testing.expectEqual(@as(usize, 1), queue.approxLen());

    try queue.pushNoWait(2);
    try queue.pushNoWait(3);
    try testing.expectEqual(@as(usize, 3), queue.approxLen());

    _ = try queue.popNoWait();
    try testing.expectEqual(@as(usize, 2), queue.approxLen());
}
