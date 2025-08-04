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
