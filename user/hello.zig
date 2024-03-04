const std = @import("std");
pub const os = @import("zig/os.zig");
comptime { _ = os; }


const stdout = std.io.getStdOut().writer();
pub fn main() !void {
    try stdout.print("Hello from zig!\n", .{});
}

