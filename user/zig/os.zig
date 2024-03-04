const std = @import("std");
const StackTrace = std.builtin.StackTrace;
const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("user/user.h");
});
const zigmain = @import("root").main;

pub const system = struct {
    pub const fd_t = i32;
    pub const STDIN_FILENO: fd_t = 0;
    pub const STDOUT_FILENO: fd_t = 1;
    pub const STDERR_FILENO: fd_t = 1;
    pub const E = enum(u8) { SUCCESS, IO, INTR, INVAL, FAULT, AGAIN, BADF, DESTADDRREQ, DQUOT, FBIG, NOSPC, PERM, PIPE, CONNRESET, BUSY, UNEXPECTED };

    pub fn write(fd: fd_t, str: [*]const u8, count: usize) usize {
        return @intCast(c.write(fd, str, @intCast(count)));
    }
    pub fn getErrno(rc: usize) E {
        if (rc == -1) {
            return E.IO;
        }
        return E.SUCCESS;
    }
};

pub export fn _main() c_int {
    switch (@typeInfo(@typeInfo(@TypeOf(zigmain)).Fn.return_type.?)) {
        .Void => {
            zigmain();
            return 0;
        },
        .NoReturn => {
            zigmain();
        },
        .Int => {
            return zigmain();
        },
        .ErrorUnion => {
            const ret = zigmain() catch |err| {
                const stderr = std.io.getStdErr().writer();
                stderr.print("Zig main returned error:\n{s}\n", .{@errorName(err)}) catch {};
                c.exit(1);
            };
            switch (@typeInfo(@TypeOf(ret))) {
                .Void => c.exit(0),
                .Int => c.exit(@intCast(ret)),
                else => @compileError("Bad main function signature")
            }
        },
        else => @compileError("Bad main function signature"),
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*StackTrace, ret_addr: ?usize) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("Zig panic!\n{s}\n", .{msg}) catch {};
    if (ret_addr) |r| {
        stderr.print("ra: {x}\n", .{r}) catch {};
    }
    stderr.writeByte('\n') catch {};

    _ = error_return_trace;
    
    while (true) {
        @breakpoint();
    }
}
