const std = @import("std");
const posix = std.posix;

const Handle = std.Io.net.Socket.Handle;

/// Bounds every blocking read on `handle`; zero removes the bound.
pub fn setReceiveTimeout(handle: Handle, milliseconds: u32) error{Unexpected}!void {
    const timeout: posix.timeval = .{
        .sec = @intCast(milliseconds / 1000),
        .usec = @intCast((milliseconds % 1000) * 1000),
    };
    posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch return error.Unexpected;
}

pub const ReadError = error{ Timeout, ConnectionReset, Unexpected };

/// A reader over the socket that reports a receive timeout as `error.Timeout`;
/// `std.Io.net.Stream.Reader` treats one as a programming error.
pub const Reader = struct {
    handle: Handle,
    interface: std.Io.Reader,
    err: ?ReadError = null,
    deadline: ?Deadline = null,

    const Deadline = struct { io: std.Io, at: std.Io.Timestamp };

    pub fn init(handle: Handle, buffer: []u8) Reader {
        return .{
            .handle = handle,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    /// Bounds the total time of every read until cleared. A receive timeout alone restarts with
    /// each byte, so a peer sending one byte at a time would never reach it.
    pub fn setDeadline(self: *Reader, io: std.Io, milliseconds: u32) void {
        const at = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(milliseconds));
        self.deadline = .{ .io = io, .at = at };
    }

    pub fn clearDeadline(self: *Reader) error{Unexpected}!void {
        self.deadline = null;
        try setReceiveTimeout(self.handle, 0);
    }

    fn boundByDeadline(self: *Reader) ReadError!void {
        const deadline = self.deadline orelse return;
        const left = std.Io.Timestamp.now(deadline.io, .awake).durationTo(deadline.at).nanoseconds;
        if (left <= 0) return error.Timeout;
        const milliseconds = @min(std.math.maxInt(u32), @divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        try setReceiveTimeout(self.handle, @intCast(milliseconds));
    }

    fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
        self.boundByDeadline() catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        const destination = limit.slice(try io_w.writableSliceGreedy(1));
        const count = posix.read(self.handle, destination) catch |err| {
            self.err = switch (err) {
                error.WouldBlock => error.Timeout,
                error.ConnectionResetByPeer => error.ConnectionReset,
                else => error.Unexpected,
            };
            return error.ReadFailed;
        };
        if (count == 0) return error.EndOfStream;
        io_w.advance(count);
        return count;
    }
};
