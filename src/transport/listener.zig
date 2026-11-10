const std = @import("std");
const posix = std.posix;
const Threaded = std.Io.Threaded;

pub const Error = error{ AddressInUse, AddressUnavailable, AccessDenied, Unexpected };

/// `IpAddress.listen` with `reuse_address` also sets SO_REUSEPORT, which lets a second relay bind
/// the same port and take a share of the connections into a hub of its own. This sets only
/// SO_REUSEADDR, so a restart still binds past connections in TIME_WAIT.
pub fn listen(address: std.Io.net.IpAddress, backlog: u31) Error!std.Io.net.Server {
    const family: u32 = switch (address) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    // Darwin's socket() takes no flags; the relay never execs, so the descriptor needs no FD_CLOEXEC.
    const cloexec: u32 = if (Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
    const opened = posix.system.socket(family, posix.SOCK.STREAM | cloexec, posix.IPPROTO.TCP);
    if (posix.errno(opened) != .SUCCESS) return error.Unexpected;
    const handle: posix.fd_t = @intCast(opened);
    errdefer _ = posix.system.close(handle);

    const enable: c_int = 1;
    posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable)) catch return error.Unexpected;

    var storage: Threaded.PosixAddress = undefined;
    var length = Threaded.addressToPosix(&address, &storage);
    switch (posix.errno(posix.system.bind(handle, &storage.any, length))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.Unexpected,
    }
    if (posix.errno(posix.system.listen(handle, backlog)) != .SUCCESS) return error.Unexpected;

    length = @sizeOf(Threaded.PosixAddress);
    if (posix.errno(posix.system.getsockname(handle, &storage.any, &length)) != .SUCCESS) return error.Unexpected;
    return .{ .socket = .{ .handle = handle, .address = Threaded.addressFromPosix(&storage) }, .options = {} };
}

const testing = std.testing;

test "a second listener on a bound port is refused" {
    const any = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var first = try listen(any, 16);
    defer first.deinit(testing.io);
    const port = first.socket.address.getPort();
    try testing.expect(port != 0);

    const same = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    try testing.expectError(error.AddressInUse, listen(same, 16));
}

test "a listener accepts a connection" {
    const any = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try listen(any, 16);
    defer server.deinit(testing.io);

    const client = try server.socket.address.connect(testing.io, .{ .mode = .stream });
    defer client.close(testing.io);
    const accepted = try server.accept(testing.io);
    accepted.close(testing.io);
}
