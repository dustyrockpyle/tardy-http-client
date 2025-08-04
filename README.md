# tardy-http-client

An HTTPS client for [tardy](https://github.com/tardy-org/tardy) that's merely a patch of Zig's std.http.Client to use tardy's async socket API.

## Summary

- tardy is an asynchronous runtime for writing applications and runtimes in Zig.
- tardy (ab)uses Coroutines to abstract native async I/O APIs (io_uring, epoll, kqueue, poll, etc.) into a synchronous API similar to std.posix.socket.
- std.http.Client is Zig's built-in HTTP Client. It supports TLS 1.2/1.3, and uses std.posix.socket internally.
- This library is 99% a copy of std.http.Client with a patched Stream that uses tardy.Socket instead of std.posix.socket. After some very minor additional twiddling it seems to work.

## Installing
Compatible Zig Version: 0.14.1

```sh
zig fetch --save git+https://github.com/tardy-org/tardy#e934f66f417a8edcd044f09180caaef5d229998e
zig fetch --save git+https://github.com/dustyrockpyle/tardy-http-client
```

You can then add the dependencies in your `build.zig` file:
```zig
const tardy = b.dependency("tardy", .{
    .target = target,
    .optimize = optimize,
}).module("tardy");

const tardy_http_client = b.dependency("tardy_http_client", .{
    .target = target,
    .optimize = optimize,
}).module("tardy_http_client");

exe_mod.addImport("tardy", tardy);
exe_mod.addImport("tardy_http_client", tardy_http_client);
```

## Example Usage

```sh
zig build run_basic -- https://google.com
zig build run_multi_fetch
```

- tardy-http-client has nearly the same API as std.http.Client.
- Client.fetch has two extra arguments; `*tardy.Runtime` and `*Client.FutureFetchResult`
- `Client.FetchOptions` has some bonus arguments for retry logic.
- The HTTP Client must be running in a tardy runtime to function.

Minimal one-shot HTTP Request example:

```zig
const std = @import("std");
const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;
const Client = @import("tardy_http_client");
pub const std_options: std.Options = .{ .log_level = .warn };

const Context = struct {
    allocator: std.mem.Allocator,
};

// Queries https://api.ipify.org/ and prints the result.
fn main_frame(rt: *Runtime, context: *Context) !void {
    var client: Client = .{ .allocator = context.allocator };
    defer client.deinit();
    var response: std.ArrayList(u8) = .init(context.allocator);
    defer response.deinit();
    var future: Client.FutureFetchResult = .{};

    try client.fetch(rt, &future, .{
        .location = .{ .url = "https://api.ipify.org" },
        .response_storage = .{ .dynamic = &response },
    });

    const result = try future.result(rt);
    std.debug.print("Status: {} - {?s}\n", .{ @intFromEnum(result.status), result.status.phrase() });
    std.debug.print("Body: {s}\n", .{response.items});
}

const FRAME_SIZE = 1024 * 32; // Max size of the main_frame stack.
fn start(rt: *Runtime, c: *Context) !void {
    try rt.spawn(.{ rt, c }, main_frame, FRAME_SIZE);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var context = Context{ .allocator = gpa };
    var tardy = try Tardy.init(gpa, .{ .threading = .single });
    defer tardy.deinit();
    try tardy.entry(&context, start);
}
```

## Notes

- Tested only on an arm64 Mac, and only on a few URLS. It should have the same limitations as std.http.Client.
- Each HTTP Request coroutine requires 2MiB of stack space. It will crash if you provide less.
- If you use this in prod you deserve jailtime (but I'm going to anyway)
