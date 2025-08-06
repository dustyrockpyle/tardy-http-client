const std = @import("std");
const assert = std.debug.assert;
const Random = std.Random;

const Atomic = std.atomic.Value;

pub const PopError = error{
    QueueEmpty,
};

pub const PushError = error{
    QueueFull,
};

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Cell = struct {
            sequence: Atomic(usize),
            data: T,
        };

        allocator: std.mem.Allocator,
        buffer: []Cell,
        mask: usize,

        write_index: Atomic(usize) align(std.atomic.cache_line),
        read_index: Atomic(usize) align(std.atomic.cache_line),

        pub fn init(allocator: std.mem.Allocator, min_size: usize) !Self {
            const pow2Size = try std.math.ceilPowerOfTwo(usize, @max(2, min_size));

            const buffer = try allocator.alloc(Cell, pow2Size);
            errdefer allocator.free(buffer);

            // Initialize sequence numbers for each cell
            for (buffer, 0..) |*cell, i| {
                cell.sequence = .{ .raw = i };
            }

            return .{
                .allocator = allocator,
                .buffer = buffer,
                .mask = pow2Size - 1,
                .write_index = .{ .raw = 0 },
                .read_index = .{ .raw = 0 },
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.buffer);
        }

        pub fn push(self: *Self, item: T) PushError!void {
            var pos = self.write_index.load(.monotonic);

            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const dif: isize = @bitCast(seq -% pos);

                if (dif == 0) {
                    // Cell is available for writing, try to claim it
                    if (self.write_index.cmpxchgWeak(pos, pos + 1, .monotonic, .monotonic)) |new_pos| {
                        pos = new_pos;
                        continue;
                    }
                    // Successfully claimed the cell, write the data
                    cell.data = item;
                    cell.sequence.store(pos + 1, .release);
                    return;
                } else if (dif < 0) {
                    // Cell is not yet available for writing (queue is full)
                    return PushError.QueueFull;
                } else {
                    // Cell is ahead of us, reload position and retry
                    pos = self.write_index.load(.monotonic);
                }
            }
        }

        pub fn pop(self: *Self) PopError!T {
            var pos = self.read_index.load(.monotonic);

            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const dif: isize = @bitCast(seq -% (pos + 1));

                if (dif == 0) {
                    // Try to claim this cell for reading
                    if (self.read_index.cmpxchgWeak(pos, pos + 1, .monotonic, .monotonic)) |new_pos| {
                        pos = new_pos;
                        continue;
                    }
                    // Successfully claimed the cell, read the data
                    const data = cell.data;
                    cell.sequence.store(pos + self.buffer.len, .release);
                    return data;
                } else if (dif < 0) {
                    // Queue is empty
                    return PopError.QueueEmpty;
                } else {
                    // Another thread is ahead, reload and retry
                    pos = self.read_index.load(.monotonic);
                }
            }
        }

        // Gets approximate number of items
        pub fn approxLen(self: *Self) usize {
            const write_pos = self.write_index.load(.monotonic);
            const read_pos = self.read_index.load(.monotonic);
            return write_pos -% read_pos;
        }
    };
}

const testing = std.testing;

test "Queue: Minimum Size" {
    // Test with minimum allowed size (2)
    var ring: Queue(u32) = try .init(testing.allocator, 2);
    defer ring.deinit();

    try ring.push(42);
    try ring.push(43);
    try testing.expectError(error.QueueFull, ring.push(44));
    try testing.expectEqual(@as(u32, 42), try ring.pop());
    try testing.expectEqual(@as(u32, 43), try ring.pop());
    try testing.expectError(error.QueueEmpty, ring.pop());
}

test "Queue: Large Size" {
    // Test with a larger power-of-2 size
    const size: usize = 4096;
    var ring: Queue(u64) = try .init(testing.allocator, size);
    defer ring.deinit();

    // Fill to capacity
    for (0..size) |i| {
        try ring.push(@intCast(i));
    }
    try testing.expectError(error.QueueFull, ring.push(9999));

    // Verify all values
    for (0..size) |i| {
        try testing.expectEqual(@as(u64, @intCast(i)), try ring.pop());
    }
    try testing.expectError(error.QueueEmpty, ring.pop());
}

test "Queue: Wrap Around" {
    const size: u32 = 8;
    var ring: Queue(u32) = try .init(testing.allocator, size);
    defer ring.deinit();

    // Fill half
    for (0..4) |i| {
        try ring.push(@intCast(i));
    }

    // Pop half
    for (0..4) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), try ring.pop());
    }

    // Fill again to test wrap around
    for (4..12) |i| {
        try ring.push(@intCast(i));
    }

    // Should be full now
    try testing.expectError(error.QueueFull, ring.push(99));

    // Pop all and verify order
    for (4..12) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), try ring.pop());
    }
    try testing.expectError(error.QueueEmpty, ring.pop());
}

test "Queue: Alternating Push Pop" {
    const size: u32 = 16;
    var ring: Queue(i32) = try .init(testing.allocator, size);
    defer ring.deinit();

    // Alternating single push/pop
    for (0..100) |i| {
        const val: i32 = @intCast(i);
        try ring.push(val);
        try testing.expectEqual(val, try ring.pop());
    }

    // Alternating batch push/pop
    for (0..10) |batch| {
        // Push 5 items
        for (0..5) |i| {
            try ring.push(@intCast(batch * 100 + i));
        }
        // Pop 5 items
        for (0..5) |i| {
            try testing.expectEqual(@as(i32, @intCast(batch * 100 + i)), try ring.pop());
        }
    }
}

test "Queue: Concurrent Simulation" {
    // Simulate concurrent access patterns with sequential operations
    const size: u32 = 64;
    var ring: Queue(u32) = try .init(testing.allocator, size);
    defer ring.deinit();

    // Producer 1: Push even numbers
    for (0..20) |i| {
        try ring.push(@intCast(i * 2));
    }

    // Consumer 1: Pop 10 items
    for (0..10) |i| {
        try testing.expectEqual(@as(u32, @intCast(i * 2)), try ring.pop());
    }

    // Producer 2: Push odd numbers
    for (0..20) |i| {
        try ring.push(@intCast(i * 2 + 1));
    }

    // Consumer 2: Pop remaining items
    // First the remaining even numbers
    for (10..20) |i| {
        try testing.expectEqual(@as(u32, @intCast(i * 2)), try ring.pop());
    }
    // Then the odd numbers
    for (0..20) |i| {
        try testing.expectEqual(@as(u32, @intCast(i * 2 + 1)), try ring.pop());
    }

    try testing.expectError(error.QueueEmpty, ring.pop());
}

test "Queue: Stress Test" {
    const size: u32 = 256;
    var ring: Queue(usize) = try .init(testing.allocator, size);
    defer ring.deinit();

    // Perform many cycles of fill/empty
    for (0..1000) |cycle| {
        // Fill to capacity
        for (0..size) |i| {
            try ring.push(cycle * 1000 + i);
        }
        try testing.expectError(error.QueueFull, ring.push(9999));

        // Empty completely
        for (0..size) |i| {
            try testing.expectEqual(cycle * 1000 + i, try ring.pop());
        }
        try testing.expectError(error.QueueEmpty, ring.pop());
    }
}

test "Queue: Sequential Consistency" {
    // Test that items maintain FIFO order under various patterns
    const size: u32 = 32;
    var ring: Queue(u32) = try .init(testing.allocator, size);
    defer ring.deinit();

    var next_push: u32 = 0;
    var next_pop: u32 = 0;

    // Random-like pattern of pushes and pops
    const pattern = [_]u8{ 3, 2, 5, 3, 7, 4, 2, 1, 8, 8 }; // push counts alternating with pop counts

    for (pattern, 0..) |count, i| {
        if (i % 2 == 0) {
            // Push phase
            var j: u8 = 0;
            while (j < count) : (j += 1) {
                ring.push(next_push) catch break;
                next_push += 1;
            }
        } else {
            // Pop phase
            var j: u8 = 0;
            while (j < count) : (j += 1) {
                const val = ring.pop() catch break;
                try testing.expectEqual(next_pop, val);
                next_pop += 1;
            }
        }
    }

    // Pop any remaining items
    while (ring.pop()) |val| {
        try testing.expectEqual(next_pop, val);
        next_pop += 1;
    } else |_| {}

    try testing.expectEqual(next_push, next_pop);
}

const ProducerContext = struct {
    queue: *Queue(u32),
    start_value: u32,
    count: u32,
};

const ConsumerContext = struct {
    queue: *Queue(u32),
    results: std.ArrayList(u32),
    expected_count: u32,
};

fn producer(ctx: *ProducerContext) !void {
    var i: u32 = 0;
    while (i < ctx.count) : (i += 1) {
        const value = ctx.start_value + i;
        while (true) {
            ctx.queue.push(value) catch {
                // Queue is full, yield and retry
                std.Thread.yield() catch {};
                continue;
            };
            break;
        }
    }
}

fn consumer(ctx: *ConsumerContext) !void {
    while (ctx.results.items.len < ctx.expected_count) {
        if (ctx.queue.pop()) |value| {
            try ctx.results.append(value);
        } else |_| {
            // Queue is empty, yield and retry
            std.Thread.yield() catch {};
        }
    }
}

test "Queue: Multi-threaded MPMC" {
    const size: usize = 1024;
    const num_producers = 4;
    const num_consumers = 4;
    const items_per_producer = 100_000;

    var ring: Queue(u32) = try .init(testing.allocator, size);
    defer ring.deinit();

    // Create producer contexts
    var producer_contexts: [num_producers]ProducerContext = undefined;
    for (&producer_contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .queue = &ring,
            .start_value = @intCast(i * items_per_producer),
            .count = items_per_producer,
        };
    }

    // Create consumer contexts with result storage
    var consumer_contexts: [num_consumers]ConsumerContext = undefined;
    var consumer_results: [num_consumers]std.ArrayList(u32) = undefined;
    for (&consumer_contexts, &consumer_results) |*ctx, *results| {
        results.* = std.ArrayList(u32).init(testing.allocator);
        ctx.* = .{
            .queue = &ring,
            .results = results.*,
            .expected_count = @divExact(num_producers * items_per_producer, num_consumers),
        };
    }
    defer for (&consumer_contexts) |*ctx| {
        ctx.results.deinit();
    };
    const start_time = std.time.nanoTimestamp();

    // Spawn producer threads
    var producer_threads: [num_producers]std.Thread = undefined;
    for (&producer_threads, &producer_contexts) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, producer, .{ctx});
    }

    // Spawn consumer threads
    var consumer_threads: [num_consumers]std.Thread = undefined;
    for (&consumer_threads, &consumer_contexts) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, consumer, .{ctx});
    }

    // Wait for all threads to complete
    for (&producer_threads) |*thread| {
        thread.join();
    }
    for (&consumer_threads) |*thread| {
        thread.join();
    }
    const end_time = std.time.nanoTimestamp();
    std.debug.print("Multi-threaded MPMC test completed in {d} ms\n", .{@divFloor((end_time - start_time), std.time.ns_per_ms)});

    // Merge all consumer results
    var all_results = std.ArrayList(u32).init(testing.allocator);
    defer all_results.deinit();

    for (&consumer_contexts) |*ctx| {
        try all_results.appendSlice(ctx.results.items);
    }

    // Verify total count
    const expected_total = num_producers * items_per_producer;
    try testing.expectEqual(expected_total, all_results.items.len);

    // Sort results to check for gaps
    std.mem.sort(u32, all_results.items, {}, std.sort.asc(u32));

    // Verify no gaps and all values are present
    for (all_results.items, 0..) |value, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), value);
    }
}

const ThreadContext = struct {
    queue: *Queue(u32),
    thread_id: usize,
    push_count: usize = 0,
    pop_count: usize = 0,
    values_sum: usize = 0,
};

fn mixedOperations(ctx: *ThreadContext) !void {
    var prng = Random.DefaultPrng.init(@intCast(ctx.thread_id));
    const random = prng.random();

    const operations_per_thread = 100_000;
    for (0..operations_per_thread) |i| {
        if (random.boolean()) {
            // Try to push
            const value: u32 = @intCast(ctx.thread_id * operations_per_thread + i);
            ctx.queue.push(value) catch continue;
            ctx.push_count += 1;
            ctx.values_sum +%= value;
        } else {
            // Try to pop
            const value = ctx.queue.pop() catch continue;
            ctx.pop_count += 1;
            ctx.values_sum -%= value;
        }
    }
}

test "Queue: Multi-threaded Stress" {
    const size: usize = 256;
    const num_threads = 8;

    var ring: Queue(u32) = try .init(testing.allocator, size);
    defer ring.deinit();

    // Create and run threads
    var contexts: [num_threads]ThreadContext = undefined;
    var threads: [num_threads]std.Thread = undefined;

    const start_time = std.time.nanoTimestamp();
    for (&contexts, &threads, 0..) |*ctx, *thread, i| {
        ctx.* = .{
            .queue = &ring,
            .thread_id = i,
        };
        thread.* = try std.Thread.spawn(.{}, mixedOperations, .{ctx});
    }

    // Wait for completion
    for (&threads) |*thread| {
        thread.join();
    }

    // Verify push/pop balance
    var total_pushes: usize = 0;
    var total_pops: usize = 0;
    var net_sum: usize = 0;

    for (&contexts) |*ctx| {
        total_pushes += ctx.push_count;
        total_pops += ctx.pop_count;
        net_sum +%= ctx.values_sum;
    }

    // Drain any remaining items
    while (ring.pop()) |value| {
        total_pops += 1;
        net_sum -%= value;
    } else |_| {}
    const end_time = std.time.nanoTimestamp();
    std.debug.print("Multi-threaded Stress test completed in {d} ms\n", .{@divFloor((end_time - start_time), std.time.ns_per_ms)});

    // Total pushes should equal total pops
    try testing.expectEqual(total_pushes, total_pops);
    // Net sum should be zero (all pushed values were popped)
    try testing.expectEqual(@as(usize, 0), net_sum);
}
