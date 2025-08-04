const std = @import("std");
const testing = std.testing;

test "tests" {
    testing.refAllDecls(@import("./Client.zig"));
    testing.refAllDecls(@import("./future.zig"));
    testing.refAllDecls(@import("./queue.zig"));
    testing.refAllDecls(@import("./Stream.zig"));
}
