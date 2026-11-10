const std = @import("std");
const nostr = @import("nostr");
const easyrelay = @import("easyrelay");

const testing = std.testing;

const bip340_csv = @embedFile("bip340.csv");
const events_json = @embedFile("events.json");

const Bip340 = struct {
    index: usize,
    secret_key: ?[32]u8,
    public_key: [32]u8,
    aux_rand: ?[32]u8,
    message_buf: [100]u8,
    message_len: usize,
    signature: [64]u8,
    valid: bool,
    comment: []const u8,

    fn message(self: *const Bip340) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

const VectorError = error{MalformedVector} || std.fmt.ParseIntError || error{ InvalidCharacter, InvalidLength, NoSpaceLeft };

const Bip340Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn init() Bip340Iterator {
        var lines = std.mem.splitScalar(u8, bip340_csv, '\n');
        _ = lines.next();
        return .{ .lines = lines };
    }

    fn next(self: *Bip340Iterator) VectorError!?Bip340 {
        const line = while (self.lines.next()) |candidate| {
            const trimmed = std.mem.trimEnd(u8, candidate, "\r");
            if (trimmed.len != 0) break trimmed;
        } else return null;

        var fields = std.mem.splitScalar(u8, line, ',');
        const index = fields.next() orelse return error.MalformedVector;
        const secret_key = fields.next() orelse return error.MalformedVector;
        const public_key = fields.next() orelse return error.MalformedVector;
        const aux_rand = fields.next() orelse return error.MalformedVector;
        const message = fields.next() orelse return error.MalformedVector;
        const signature = fields.next() orelse return error.MalformedVector;
        const result = fields.next() orelse return error.MalformedVector;

        if (message.len % 2 != 0 or message.len / 2 > 100) return error.MalformedVector;

        var vector: Bip340 = .{
            .index = try std.fmt.parseInt(usize, index, 10),
            .secret_key = if (secret_key.len == 0) null else try hex32(secret_key),
            .public_key = try hex32(public_key),
            .aux_rand = if (aux_rand.len == 0) null else try hex32(aux_rand),
            .message_buf = undefined,
            .message_len = message.len / 2,
            .signature = undefined,
            .valid = std.mem.eql(u8, result, "TRUE"),
            .comment = fields.rest(),
        };
        _ = try std.fmt.hexToBytes(vector.message_buf[0..vector.message_len], message);
        _ = try std.fmt.hexToBytes(&vector.signature, signature);
        return vector;
    }
};

fn hex32(text: []const u8) VectorError![32]u8 {
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, text);
    return out;
}

test "BIP-340: every official vector verifies exactly as the suite says" {
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var vectors = Bip340Iterator.init();
    var checked: usize = 0;
    while (try vectors.next()) |vector| {
        const verified = signer.verify(vector.signature, vector.message(), vector.public_key);
        testing.expectEqual(vector.valid, verified) catch |err| {
            std.debug.print(
                "BIP-340 vector {d} disagrees with the suite: {s}\n",
                .{ vector.index, vector.comment },
            );
            return err;
        };
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 19), checked);
}

test "BIP-340: signing reproduces the published signature" {
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var vectors = Bip340Iterator.init();
    var signed: usize = 0;
    while (try vectors.next()) |vector| {
        const secret_key = vector.secret_key orelse continue;

        const keypair = try signer.keyPairFromSecretKey(secret_key);
        try testing.expectEqualSlices(u8, &vector.public_key, &keypair.public_key);

        const signature = try signer.sign(vector.message(), keypair, vector.aux_rand);
        try testing.expectEqualSlices(u8, &vector.signature, &signature);
        signed += 1;
    }
    try testing.expectEqual(@as(usize, 8), signed);
}

fn parseEvents(arena: std.mem.Allocator) ![]nostr.event.Event {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, events_json, .{});
    defer parsed.deinit();

    const values = parsed.value.array.items;
    const events = try arena.alloc(nostr.event.Event, values.len);
    for (values, events) |value, *event| {
        event.* = try nostr.event.fromValueLeaky(arena, value);
    }
    return events;
}

test "every collected event recomputes to its published id and verifies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const events = try parseEvents(arena);
    try testing.expect(events.len >= 6);

    for (events) |event| {
        const recomputed = try nostr.event.computeId(
            arena,
            event.pubkey,
            event.created_at,
            event.kind,
            event.tags,
            event.content,
        );
        try testing.expectEqualSlices(u8, &event.id, &recomputed);
        try testing.expect(signer.verifyId(event.sig, event.id, event.pubkey));
    }
}

test "the collected events still cover the cases a JSON encoder gets wrong" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var non_ascii = false;
    var newline = false;
    var quote = false;
    var backslash = false;
    var forward_slash = false;
    var empty_content = false;
    var empty_tags = false;
    var many_tags = false;

    for (try parseEvents(arena)) |event| {
        for (event.content) |byte| {
            if (byte > 127) non_ascii = true;
            if (byte == '\n') newline = true;
            if (byte == '"') quote = true;
            if (byte == '\\') backslash = true;
            if (byte == '/') forward_slash = true;
        }
        if (event.content.len == 0) empty_content = true;
        if (event.tags.len == 0) empty_tags = true;
        if (event.tags.len >= 20) many_tags = true;
    }

    try testing.expect(non_ascii);
    try testing.expect(newline);
    try testing.expect(quote);
    try testing.expect(backslash);
    try testing.expect(forward_slash);
    try testing.expect(empty_content);
    try testing.expect(empty_tags);
    try testing.expect(many_tags);
}

test "every collected event passes easyrelay's own validation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const validator = easyrelay.validation.Validator{ .signer = signer };

    const now: i64 = 2_000_000_000;

    for (try parseEvents(arena)) |*event| {
        const wire = try nostr.event.toJson(arena, event.*);
        var diagnostics: easyrelay.validation.Diagnostics = .{};
        validator.validate(arena, event, wire.len, now, &diagnostics) catch |err| {
            std.debug.print(
                "event {s} was rejected: {s}\n",
                .{ std.fmt.bytesToHex(event.id, .lower), diagnostics.message() },
            );
            return err;
        };
    }
}

test "canonical serialization escapes exactly the seven characters NIP-01 names" {
    // A general-purpose JSON encoder escapes differently, and any difference changes the id.
    const content = "\n\"\\\r\t\x08\x0c/\u{00e9}\x01";
    const expected = "[0,\"" ++ "00" ** 32 ++ "\",1700000000,1,[],\"\\n\\\"\\\\\\r\\t\\b\\f/\u{00e9}\x01\"]";

    const canonical = try nostr.event.serializeCanonical(
        testing.allocator,
        [_]u8{0} ** 32,
        1700000000,
        1,
        &.{},
        content,
    );
    defer testing.allocator.free(canonical);

    try testing.expectEqualStrings(expected, canonical);
}
