const std = @import("std");
const Atomic = std.atomic.Value;
const Runtime = @import("tardy").Runtime;

const FutureState = enum(u8) { pending, setting_result, ready, cancelled };

const FutureError = error{
    FutureCancelled,
    AlreadySet,
    AlreadyAwaited,
};

pub fn Future(comptime T: type, comptime E: type) type {
    return struct {
        const Self = @This();

        // TODO: Allow notifying multiple tasks?
        to_notify_plus_one: Atomic(usize) align(std.atomic.cache_line) = .{ .raw = 0 },
        notify_rt: Atomic(?*Runtime) align(std.atomic.cache_line) = .{ .raw = null },
        state: Atomic(FutureState) align(std.atomic.cache_line) = .{ .raw = .pending },

        _result: FutureResult(T, E) = .{ .actual = undefined },

        // Initializes the future to notify the current task when the future is ready. The active task will be triggered to wake up when the future is ready.
        pub fn init_with_notify(rt: *Runtime) Self {
            var future = Self{};
            future.to_notify_plus_one.raw = rt.current_task.? + 1;
            future.notify_rt.raw = rt;
            return future;
        }

        pub const ResultError = E || FutureError;

        // Returns true if result() is ready.
        pub fn done(self: *const Self) bool {
            return self.state.load(.acquire) != .pending;
        }

        // Returns true if the future has been cancelled.
        pub fn cancelled(self: *const Self) bool {
            return self.state.load(.acquire) == .cancelled;
        }

        // Blocks the current task until the result is ready. Should only be called from one task while pending.
        pub fn result(self: *Self, rt: *Runtime) ResultError!T {
            var state = self.state.load(.acquire);
            switch (state) {
                .ready => {
                    return self._result.unwrap();
                },
                .cancelled => {
                    return error.FutureCancelled;
                },
                .setting_result => {
                    while (self.state.load(.acquire) == .setting_result) {
                        // Evil spin - should be extremely short + rare, and happens only in multithreaded case.
                    }
                    return self._result.unwrap();
                },
                .pending => {
                    if (self.to_notify_plus_one.cmpxchgStrong(0, rt.current_task.? + 1, .acq_rel, .acquire)) |_| {
                        if (self.notify_rt.load(.acquire) != rt or self.to_notify_plus_one.load(.acquire) != rt.current_task.? + 1) {
                            return error.AlreadyAwaited;
                        }
                    } else {
                        self.notify_rt.store(rt, .release);
                    }
                    // Check again before awaiting to avoid missing notify in a race condition.
                    state = self.state.load(.acquire);
                    while (state == .pending or state == .setting_result) {
                        rt.scheduler.trigger_await() catch unreachable;
                        state = self.state.load(.acquire);
                    }
                    if (state == .cancelled) return error.FutureCancelled;
                    return self._result.unwrap();
                },
            }
        }

        // Sets the result of the future. This can only be called once and will notify the pending task if any.
        pub fn set(self: *Self, _result: FutureResult(T, E)) FutureError!void {
            if (self.state.cmpxchgStrong(.pending, .setting_result, .acq_rel, .acquire)) |state| {
                if (state == .cancelled) return error.FutureCancelled;
                return error.AlreadySet;
            } else {
                self._result = _result;
                self.state.store(.ready, .release);
                self.notify();
            }
        }

        // Sets the result of the future. This can only be called once and will notify the pending task if any.
        pub fn setResult(self: *Self, _result: T) FutureError!void {
            return self.set(.{ .actual = _result });
        }

        // Sets an error for the future. This can only be called once and will notify the pending task if any.
        pub fn setError(self: *Self, err: E) FutureError!void {
            return self.set(.{ .err = err });
        }

        // Cancels the future. This can only be called once and will notify the pending task if any.
        pub fn setCancelled(self: *Self) !void {
            if (self.state.cmpxchgStrong(.pending, .cancelled, .acq_rel, .acquire)) |state| {
                if (state == .cancelled) return error.FutureCancelled;
                return error.AlreadySet;
            } else {
                self.notify();
            }
        }

        fn notify(self: *Self) void {
            const to_notify_plus_one = self.to_notify_plus_one.load(.acquire);
            if (to_notify_plus_one == 0) return;
            const to_notify = to_notify_plus_one - 1;
            var rt = self.notify_rt.load(.acquire);
            while (rt == null) {
                rt = self.notify_rt.load(.acquire);
            }
            rt.?.scheduler.trigger(to_notify) catch unreachable;
            rt.?.wake() catch unreachable;
        }
    };
}

pub fn FutureResult(comptime T: type, comptime E: type) type {
    return union(enum) {
        const Self = @This();
        actual: T,
        err: E,

        pub fn unwrap(self: *const Self) E!T {
            switch (self.*) {
                .actual => |a| return a,
                .err => |e| return e,
            }
        }
    };
}

const testing = std.testing;
const Tardy = @import("tardy").Tardy(.auto);
const Timer = @import("tardy").Timer;

test "Future: Basic init and state" {
    var future = Future(u32, anyerror){};

    // Initial state should be pending
    try testing.expect(!future.done());
    try testing.expect(!future.cancelled());
    try testing.expectEqual(FutureState.pending, future.state.load(.acquire));
}

test "Future: Set result and retrieve" {
    var future = Future(u32, anyerror){};

    // Set a result
    try future.setResult(42);

    // Future should be done
    try testing.expect(future.done());
    try testing.expect(!future.cancelled());

    // Should not be able to set again
    try testing.expectError(error.AlreadySet, future.setResult(43));
    try testing.expectError(error.AlreadySet, future.setError(error.TestError));
    try testing.expectError(error.AlreadySet, future.setCancelled());
}

test "Future: Set error and retrieve" {
    var future = Future(u32, anyerror){};

    // Set an error
    try future.setError(error.TestError);

    // Future should be done
    try testing.expect(future.done());
    try testing.expect(!future.cancelled());

    // Should not be able to set again
    try testing.expectError(error.AlreadySet, future.setResult(42));
    try testing.expectError(error.AlreadySet, future.setError(error.AnotherError));
}

test "Future: Cancel" {
    var future = Future(u32, anyerror){};

    // Cancel the future
    try future.setCancelled();

    // Future should be cancelled
    try testing.expect(future.done());
    try testing.expect(future.cancelled());

    // Should not be able to set after cancellation
    try testing.expectError(error.FutureCancelled, future.setResult(42));
    try testing.expectError(error.FutureCancelled, future.setError(error.TestError));
    try testing.expectError(error.FutureCancelled, future.setCancelled());
}

test "Future: Basic async result" {
    var tardy = try Tardy.init(testing.allocator, .{ .threading = .single });
    defer tardy.deinit();

    const Context = struct {
        future: Future(u32, anyerror) = .{},
        result: ?u32 = null,
        err: ?anyerror = null,
        producer_done: Atomic(bool) = .{ .raw = false },
        consumer_done: Atomic(bool) = .{ .raw = false },
    };

    var ctx = Context{};

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            try rt.spawn(.{ rt, c }, consumer, 1024 * 16);
            try rt.spawn(.{ rt, c }, producer, 1024 * 16);
        }

        fn producer(rt: *Runtime, c: *Context) !void {
            // Small delay to ensure consumer is waiting
            try Timer.delay(rt, .{ .nanos = std.time.ns_per_ms * 10 });
            try c.future.setResult(42);
            c.producer_done.store(true, .release);
        }

        fn consumer(rt: *Runtime, c: *Context) !void {
            c.result = c.future.result(rt) catch |err| {
                c.err = err;
                c.consumer_done.store(true, .release);
                return;
            };
            c.consumer_done.store(true, .release);
        }
    }.start);

    try testing.expect(ctx.producer_done.load(.acquire));
    try testing.expect(ctx.consumer_done.load(.acquire));
    try testing.expectEqual(@as(?u32, 42), ctx.result);
    try testing.expectEqual(@as(?anyerror, null), ctx.err);
}

test "Future: Async error propagation" {
    var tardy = try Tardy.init(testing.allocator, .{ .threading = .single });
    defer tardy.deinit();

    const Context = struct {
        future: Future(u32, anyerror) = .{},
        result: ?u32 = null,
        err: ?anyerror = null,
        done: Atomic(bool) = .{ .raw = false },
    };

    var ctx = Context{};

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            try rt.spawn(.{ rt, c }, consumer, 1024 * 16);
            try rt.spawn(.{ rt, c }, producer, 1024 * 16);
        }

        fn producer(rt: *Runtime, c: *Context) !void {
            // Small delay to ensure consumer is waiting
            try Timer.delay(rt, .{ .nanos = std.time.ns_per_ms * 10 });
            try c.future.setError(error.TestError);
        }

        fn consumer(rt: *Runtime, c: *Context) !void {
            c.result = c.future.result(rt) catch |err| {
                c.err = err;
                c.done.store(true, .release);
                return;
            };
            c.done.store(true, .release);
        }
    }.start);

    try testing.expect(ctx.done.load(.acquire));
    try testing.expectEqual(@as(?u32, null), ctx.result);
    try testing.expectEqual(@as(?anyerror, error.TestError), ctx.err);
}

test "Future: Async cancellation" {
    var tardy = try Tardy.init(testing.allocator, .{ .threading = .single });
    defer tardy.deinit();

    const Context = struct {
        future: Future(u32, anyerror) = .{},
        result: ?u32 = null,
        err: ?anyerror = null,
        done: Atomic(bool) = .{ .raw = false },
    };

    var ctx = Context{};

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            try rt.spawn(.{ rt, c }, consumer, 1024 * 16);
            try rt.spawn(.{ rt, c }, canceller, 1024 * 16);
        }

        fn canceller(rt: *Runtime, c: *Context) !void {
            // Small delay to ensure consumer is waiting
            try Timer.delay(rt, .{ .nanos = std.time.ns_per_ms * 10 });
            try c.future.setCancelled();
        }

        fn consumer(rt: *Runtime, c: *Context) !void {
            c.result = c.future.result(rt) catch |err| {
                c.err = err;
                c.done.store(true, .release);
                return;
            };
            c.done.store(true, .release);
        }
    }.start);

    try testing.expect(ctx.done.load(.acquire));
    try testing.expectEqual(@as(?u32, null), ctx.result);
    try testing.expectEqual(@as(?anyerror, error.FutureCancelled), ctx.err);
}

test "Future: init_with_notify" {
    var tardy = try Tardy.init(testing.allocator, .{ .threading = .single });
    defer tardy.deinit();

    const Context = struct {
        result: ?u32 = null,
        err: ?anyerror = null,
        done: Atomic(bool) = .{ .raw = false },
    };

    var ctx = Context{};

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            try rt.spawn(.{ rt, c }, worker, 1024 * 16);
        }

        fn worker(rt: *Runtime, c: *Context) !void {
            // Create a future that will notify this task
            var future = Future(u32, anyerror).init_with_notify(rt);

            // Spawn a producer that will set the result
            try rt.spawn(.{ rt, &future }, producer, 1024 * 16);

            // Yield - we should be awoken when the result is set.
            try rt.scheduler.trigger_await();

            c.result = future.result(rt) catch |err| {
                c.err = err;
                c.done.store(true, .release);
                return;
            };
            c.done.store(true, .release);
        }

        fn producer(rt: *Runtime, future: *Future(u32, anyerror)) !void {
            // Small delay to ensure worker is waiting
            try Timer.delay(rt, .{ .nanos = std.time.ns_per_ms * 10 });
            try future.setResult(123);
        }
    }.start);

    try testing.expect(ctx.done.load(.acquire));
    try testing.expectEqual(@as(?u32, 123), ctx.result);
    try testing.expectEqual(@as(?anyerror, null), ctx.err);
}

test "Future: Result retrieval after set" {
    var tardy = try Tardy.init(testing.allocator, .{ .threading = .single });
    defer tardy.deinit();

    const Context = struct {
        future: Future(u32, anyerror) = .{},
        results: [3]?u32 = [_]?u32{null} ** 3,
    };

    var ctx = Context{};

    try tardy.entry(&ctx, struct {
        fn start(rt: *Runtime, c: *Context) !void {
            // Set the result first
            try c.future.setResult(999);

            // Now spawn multiple consumers to read it
            try rt.spawn(.{ rt, c, 0 }, consumer, 1024 * 16);
            try rt.spawn(.{ rt, c, 1 }, consumer, 1024 * 16);
            try rt.spawn(.{ rt, c, 2 }, consumer, 1024 * 16);
        }

        fn consumer(rt: *Runtime, c: *Context, idx: usize) !void {
            // All should get the result immediately since it's already set
            c.results[idx] = try c.future.result(rt);
        }
    }.start);

    // All consumers should have gotten the same result
    for (ctx.results) |result| {
        try testing.expectEqual(@as(?u32, 999), result);
    }
}
