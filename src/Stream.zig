const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const fs = std.fs;
const io = std.io;
const native_os = builtin.os.tag;

const tardy = @import("tardy");
const Socket = tardy.Socket;

/// Whether to use libc for the POSIX API layer.
const use_libc = builtin.link_libc or switch (native_os) {
    .windows, .wasi => true,
    else => false,
};

const linux = std.os.linux;
const windows = std.os.windows;
const wasi = std.os.wasi;

pub const system = if (use_libc)
    std.c
else switch (native_os) {
    .linux => linux,
    .plan9 => std.os.plan9,
    else => struct {
        pub const ucontext_t = void;
        pub const pid_t = void;
        pub const pollfd = void;
        pub const fd_t = void;
        pub const uid_t = void;
        pub const gid_t = void;
    },
};

pub const IOV_MAX = system.IOV_MAX;

const Stream = @This();

/// Underlying platform-defined type which may or may not be
/// interchangeable with a file system file descriptor.
handle: Socket,
rt: *tardy.Runtime,

pub fn close(s: Stream) void {
    // TODO: Correctly handle or propagate stream close errors.
    s.handle.close(s.rt) catch return;
}

pub const ReadError = anyerror;
pub const WriteError = anyerror;

pub const Reader = io.Reader(Stream, ReadError, read);
pub const Writer = io.Writer(Stream, WriteError, write);

pub fn reader(self: Stream) Reader {
    return .{ .context = self };
}

pub fn writer(self: Stream) Writer {
    return .{ .context = self };
}

pub fn read(self: Stream, buffer: []u8) ReadError!usize {
    return self.handle.recv(self.rt, buffer);
}

pub fn readv(self: Stream, iovecs: []const posix.iovec) ReadError!usize {
    return self.read(iovecs[0].base[0..iovecs[0].len]);
}

/// Returns the number of bytes read. If the number read is smaller than
/// `buffer.len`, it means the stream reached the end. Reaching the end of
/// a stream is not an error condition.
pub fn readAll(self: Stream, buffer: []u8) ReadError!usize {
    return readAtLeast(self, buffer, buffer.len);
}

/// Returns the number of bytes read, calling the underlying read function
/// the minimal number of times until the buffer has at least `len` bytes
/// filled. If the number read is less than `len` it means the stream
/// reached the end. Reaching the end of the stream is not an error
/// condition.
pub fn readAtLeast(self: Stream, buffer: []u8, len: usize) ReadError!usize {
    return self.read(buffer[0..len]);
}

/// TODO in evented I/O mode, this implementation incorrectly uses the event loop's
/// file system thread instead of non-blocking. It needs to be reworked to properly
/// use non-blocking I/O.
pub fn write(self: Stream, buffer: []const u8) WriteError!usize {
    return self.handle.send(self.rt, buffer);
}

pub fn writeAll(self: Stream, bytes: []const u8) WriteError!void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try self.write(bytes[index..]);
    }
}

/// See https://github.com/ziglang/zig/issues/7699
/// See equivalent function: `std.fs.File.writev`.
pub fn writev(self: Stream, iovecs: []const posix.iovec_const) WriteError!usize {
    var total: usize = 0;
    for (iovecs[0..@min(iovecs.len, IOV_MAX)]) |iov| {
        if (iov.len == 0) continue; // Skip empty iovecs
        const amt = try self.write(iov.base[0..iov.len]);
        total += amt;
        if (amt < iov.len) return total;
    }
    return total;
}

/// The `iovecs` parameter is mutable because this function needs to mutate the fields in
/// order to handle partial writes from the underlying OS layer.
/// See https://github.com/ziglang/zig/issues/7699
/// See equivalent function: `std.fs.File.writevAll`.
pub fn writevAll(self: Stream, iovecs: []posix.iovec_const) WriteError!void {
    if (iovecs.len == 0) return;

    var i: usize = 0;
    while (true) {
        var amt = try self.writev(iovecs[i..]);
        while (amt >= iovecs[i].len) {
            amt -= iovecs[i].len;
            i += 1;
            if (i >= iovecs.len) return;
        }
        iovecs[i].base += amt;
        iovecs[i].len -= amt;
    }
}

pub fn tcpConnectToHost(rt: *tardy.Runtime, allocator: std.mem.Allocator, name: []const u8, port: u16) !Stream {
    const list = try net.getAddressList(allocator, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        return tcpConnectToAddress(rt, addr) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        };
    }
    return posix.ConnectError.ConnectionRefused;
}

pub fn tcpConnectToAddress(rt: *tardy.Runtime, address: net.Address) !Stream {
    var socket = try Socket.init_with_address(Socket.Kind.tcp, address);
    var result: Stream = .{ .rt = rt, .handle = socket };
    errdefer result.close();
    try socket.connect(rt);
    return result;
}

pub fn connectUnixSocket(rt: *tardy.Runtime, path: []const u8) !Stream {
    var socket = try Socket.init(.{ .unix = path });
    var result: Stream = .{ .rt = rt, .handle = socket };
    errdefer result.close();
    try socket.connect(rt);
    return result;
}
