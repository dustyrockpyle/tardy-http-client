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

## Usage

```sh
zig build run_multi_fetch
```

Check out `examples/multi_fetch.zig`. tardy-http-client has nearly the same API as std.http.Client.
Client.fetch has two extra arguments; `tardy.Runtime*` and `Client.Future`, and FetchOptions has some additional arguments for bonus retry logic.
The HTTP Client will not work without running in a tardy runtime.

## Notes

Tested only on an arm64 Mac, and only on a few URLS.

Each HTTP Request coroutine requires 2MiB of stack space (for HTTPS requests, ~512KiB for HTTP). It will crash if you provide less. It might crash on URLs I haven't tested (i.e, almost all of them).

If you use this in prod you deserve jailtime (but I'm going to anyway)
