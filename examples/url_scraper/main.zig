const std = @import("std");
const builtin = @import("builtin");

const Tardy = @import("tardy").Tardy(.auto);
const UrlScraper = @import("./UrlScraper.zig");

pub const std_options: std.Options = .{ .log_level = .warn };

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        // TODO: Reenable this after we figure out the connection pool issue
        //_ = debug_allocator.deinit();
    };

    var scraper: UrlScraper = try .init(gpa);
    //defer scraper.deinit();
    //
    // TODO: Stop leaking on close
    // Right now the HTTP Client connection pool doesn't close properly; I think I need a way to fire
    // cancellations / timeouts on the Sockets to force them to bail. For now just leak to avoid error messages.
    //

    var tardy = try Tardy.init(gpa, .{ .threading = .{ .multi = UrlScraper.THREAD_COUNT } });
    defer tardy.deinit();

    try tardy.entry(&scraper, UrlScraper.start);
}
