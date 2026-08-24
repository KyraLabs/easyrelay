//! Test vectors: fixed inputs with known-correct outputs, taken from outside
//! this project rather than produced by it (docs/testing.md).
//!
//! They do two jobs. They check easyrelay against the network's definition of
//! a correct event id and a correct signature, which is the only definition
//! that matters. And they are the tripwire on `zig-nostr`: an upgrade that
//! changes canonical serialization or signature behaviour fails here, at
//! upgrade time, rather than in production — where it would surface as clients
//! silently discarding everything the relay serves, with the relay looking
//! healthy throughout.

const std = @import("std");
const nostr = @import("nostr");

const testing = std.testing;

/// The official BIP-340 suite, verbatim. Provenance in README.md.
const bip340_csv = @embedFile("bip340.csv");
/// Real events from public relays, with their published ids.
const events_json = @embedFile("events.json");

// -- BIP-340 ----------------------------------------------------------------

const Bip340 = struct {
    index: usize,
    /// Absent for the vectors that only exercise verification.
    secret_key: ?[32]u8,
    public_key: [32]u8,
    aux_rand: ?[32]u8,
    /// The suite's messages run from 0 to 100 bytes.
    message_buf: [100]u8,
    message_len: usize,
    signature: [64]u8,
    /// What the suite says verification must return. Ten of the vectors are
    /// here to be *rejected*, and they are the valuable half.
    valid: bool,
    comment: []const u8,

    fn message(self: *const Bip340) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

const VectorError = error{MalformedVector} || std.fmt.ParseIntError || error{ InvalidCharacter, InvalidLength, NoSpaceLeft };

/// Walks the CSV. The file is fixed and in the repository, so a malformed row
/// is a broken checkout and not untrusted input: this gives up rather than
/// skipping, because a silently skipped vector is a test that passes for the
/// wrong reason.
const Bip340Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn init() Bip340Iterator {
        var lines = std.mem.splitScalar(u8, bip340_csv, '\n');
        _ = lines.next(); // header
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
    // Pins the file: a truncated CSV would otherwise pass by checking nothing.
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

// -- Canonical serialization and event ids ----------------------------------

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

    // Refreshing the corpus is fine; refreshing it into one that no longer
    // exercises these is how the suite quietly stops being worth running.
    try testing.expect(non_ascii);
    try testing.expect(newline);
    try testing.expect(quote);
    try testing.expect(backslash);
    try testing.expect(forward_slash);
    try testing.expect(empty_content);
    try testing.expect(empty_tags);
    try testing.expect(many_tags);
}

test "canonical serialization escapes exactly the seven characters NIP-01 names" {
    // Transcribed from docs/protocol.md: line break, quote, backslash,
    // carriage return, tab, backspace and form feed are escaped, and every
    // other byte is emitted verbatim — no \uXXXX, no escaped forward slash,
    // no escaped non-ASCII, and no escape for any other control character.
    // A general-purpose JSON encoder disagrees on the last three, and
    // disagreeing produces a different id.
    //
    // This is written from the specification rather than collected, because
    // tab and the raw control byte do not occur in a corpus of a few thousand
    // real events: see README.md.
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
