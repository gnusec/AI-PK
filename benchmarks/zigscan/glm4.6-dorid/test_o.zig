const std = @import("std");

pub fn main() void {
    std.debug.print("Available O flags: {}\n", .{@TypeOf(std.posix.O)});
    if (@hasField(@TypeOf(std.posix.O), "NONBLOCK")) {
        std.debug.print("NONBLOCK available: {}\n", .{std.posix.O.NONBLOCK});
    }
}
