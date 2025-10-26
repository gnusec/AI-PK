const std = @import("std");

pub fn main() !void {
    const stdout = std.posix.STDOUT_FILENO;
    const stderr = std.posix.STDERR_FILENO;
    
    std.debug.print("STDOUT: {}\n", .{stdout});
    std.debug.print("STDERR: {}\n", .{stderr});
}
