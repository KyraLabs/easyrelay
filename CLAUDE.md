# easyrelay — working notes for Claude

A Nostr relay in Zig. Three goals in priority order: **it works**, **it is fast**, **it is
trivial to run**. Where they conflict, the earlier one wins. See
[docs/overview.md](docs/overview.md).

This file complements `~/.claude/CLAUDE.md`; that file's rules still apply. Where this file is
silent, follow it.

## Git: do not commit

**Never run `git add`, `git commit`, `git push`, or `gh pr create`. Never merge anything.**

Leave finished work in the working tree and say what changed. Staging, commits, branches, pull
requests and merges are the maintainer's, without exception and without asking. This is
stricter than the global rule, which allows them with per-action approval; here they are simply
not yours.

You may read freely: `git status`, `git diff`, `git log`, `gh pr view`, `gh run view`.

## Before you change anything

Architectural decisions are recorded, not re-litigated. Read the relevant record first:

| Touching | Read first |
| --- | --- |
| Anything | [docs/roadmap.md](docs/roadmap.md) — phase order and exit criteria |
| Wire behaviour | [docs/protocol.md](docs/protocol.md) — the behavioural contract |
| Storage, indexes | [docs/storage.md](docs/storage.md) + [ADR-0003](docs/adr/0003-storage-engine-lmdb.md) |
| The `zig-nostr` dependency | [ADR-0002](docs/adr/0002-build-on-zig-nostr.md) + the [Phase 0 spike](docs/research/2026-08-phase-0-validation.md) |
| Anything crossing into storage | [ADR-0008](docs/adr/0008-store-abstraction-boundary.md) |
| Transport, connections | [ADR-0004](docs/adr/0004-websocket-transport.md), [ADR-0005](docs/adr/0005-concurrency-model.md) |
| Defaults, CLI, deployment | [ADR-0009](docs/adr/0009-deployment-experience.md) |

Work belonging to a later phase gets deferred, not built early. Deliberate
[non-goals](docs/overview.md#non-goals) get declined.

A new dependency, or a change to a recorded decision, needs an ADR in the same change. Use
[the template](docs/adr/0000-template.md). If implementation shows a record was wrong, amend it
— a stale ADR is worse than none, because it will be trusted.

## Zig 0.16 — the APIs that moved

Zig is pinned to `0.16.0`, exactly, in three files kept in agreement by
`./scripts/check-toolchain.sh`. Most Zig you have seen predates 0.16 and will not compile.
These were all verified by building against 0.16 during Phase 0:

```zig
// Entry point takes std.process.Init. No bare `pub fn main() !void`.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;                              // a real freeing allocator
    const arena = init.arena.allocator();              // never frees until process exit
    const io = init.io;                                // std.Io, passed like an Allocator
    const args = try init.minimal.args.toSlice(arena);
}

// Writers are buffered and MUST be flushed.
var buf: [4096]u8 = undefined;
var file: std.Io.File.Writer = .init(.stdout(), io, &buf);
const w = &file.interface;
try w.print("{s}\n", .{x});
try w.flush();

// Timing goes through Io. The monotonic clock is `.awake`, not `.monotonic`.
const t0 = std.Io.Timestamp.now(io, .awake);
const ns = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;

// Wall-clock time comes through Io as well, on the `.real` clock.
const unix_seconds = std.Io.Timestamp.now(io, .real).toSeconds();
```

Gone or renamed: `std.fs.cwd()` (filesystem moved under `std.Io`), `std.time.Timer`,
`std.time.timestamp()`,
`std.testing.refAllDeclsRecursive` (`refAllDecls` remains), `GeneralPurposeAllocator` (now
`DebugAllocator`), `GenericReader` / `AnyReader` / `FixedBufferStream`.

`.monotonic` still exists as an **atomic ordering** — `fetchAdd(1, .monotonic)` is correct;
`Timestamp.now(io, .monotonic)` is not.

**Never hand an arena to something that should free.** An arena never releases, so a component
holding per-connection state fed from `init.arena` looks exactly like a leak: memory grows
linearly and never returns. Phase 0 lost an hour to this and nearly reported a false leak in a
dependency. Use `init.gpa` for anything with a lifecycle.

## Build and test

```bash
zig build                    # binary into zig-out/bin/
zig build test               # all tests
zig build test --summary all
zig build test --fuzz        # fuzzing runs through the test runner, not a separate step
zig build check              # type-check without artifacts, for editor diagnostics
zig fmt --check .            # CI gate; zig fmt is the authority on style
./scripts/check-toolchain.sh
```

Run those three gates before saying a change is done. `zig build bench` arrives in Phase 6.

**On this machine, any build that links libc needs an explicit target.** The host `crt1.o`
carries an SFrame section Zig 0.16's linker cannot relocate:

```bash
zig build -Dtarget=x86_64-linux-musl   # what releases ship anyway
```

This bites as soon as the `zig-nostr` dependency lands. Details in
[docs/development.md](docs/development.md#hosts-with-an-sframe-crt1o).

## Code conventions

Naming, layout and formatting are in [docs/development.md](docs/development.md). What follows
is specific to a network service handling untrusted input.

**Build mode.** Production is **ReleaseSafe**, not ReleaseFast. Bounds checks, integer overflow
detection and assertions stay on. The cost is roughly 5–15%; the alternative is a silent
use-after-free in a process parsing hostile input, which contradicts goal 1. If profiling ever
shows a measured hot path dominated by safety checks, disable them for that block with
`@setRuntimeSafety(false)` — never globally. (Not yet an ADR. Write one if it is questioned.)

**Errors.** Declare explicit error sets at module boundaries — the storage API, the NIP-01
parser — because they document the contract and stop a new error leaking silently through the
call graph. Inferred `!T` is fine inside a module.

`catch unreachable` is only for errors you can prove impossible, and **never on any path a
client can reach**. In ReleaseSafe it panics; in ReleaseFast it is undefined behaviour.

Zig errors carry no payload, so use the Diagnostics pattern for anything that must explain
itself: pass a `*Diagnostics` the callee fills in before returning the error. The NIP-01 parser
needs this to produce `["OK", <id>, false, "invalid: ..."]` with a real reason, which
[docs/protocol.md](docs/protocol.md#machine-readable-result-prefixes) requires.

`error.OutOfMemory` is a normal error. Reject the request; do not panic.

**Allocators.** Passed explicitly as the first parameter, never global.

- `DebugAllocator` in Debug and ReleaseSafe (catches leaks and use-after-free),
  `std.heap.smp_allocator` in ReleaseFast.
- An **arena per connection** for connection-lifetime data.
- An **arena per request**, reset with `_ = arena.reset(.retain_capacity)` after each
  `EVENT`/`REQ`. This is the hot path; it must not leak or fragment.
- **Object pools** sized at startup for high-churn fixed-size things: connection slots, frame
  buffers, event objects.
- `std.testing.allocator` in every test — it fails the test on a leak.

**Bounds on everything, assertions everywhere.** Full static allocation does not fit a relay:
connections are dynamic and query sizes are unpredictable. The workable middle is explicit
limits on every resource — max connections, max event size, max results per `REQ`, timeouts,
max tag count — with pools sized from those limits and arenas for the genuinely dynamic parts.

Assertions stay **on in release**. Assert the invariants that matter: the event id equals the
hash of its canonical serialization, the signature verified before insert, an index never
exceeds the event count. For a process handling third-party signed data, crashing beats running
on corrupt state. Bound every loop. No recursion on client-controlled input — nested JSON is a
stack-overflow vector.

**Interfaces.** Use a vtable (`*anyopaque` + `*const VTable`, the `std.mem.Allocator` shape) for
open sets resolved at runtime — the storage boundary, so tests get an in-memory backend. Use
`anytype` or generics for internal performance utilities. `anytype` in a struct field makes the
whole struct generic and spreads; that is what forced Writergate.

**comptime** earns its place only when it removes real duplication or real runtime cost.
Generating with comptime what a plain function does is a cost, not a skill.

**Data-oriented design** pays in exactly one place here: the filter engine. Prefer compact
handles into the store over pointer-chasing event objects, and parallel arrays over arrays of
structs for the fields being filtered on (kind, created_at, author).

**FFI.** Prefer hand-written `extern` declarations over `@cImport`, which breaks on
function-like macros, bitfields and extern-by-macro. Wrap C return codes into Zig error sets and
manage C lifetimes with `defer`. Currently moot — `zig-nostr` owns the C boundary — and it
applies if we ever vendor.

## Testing

Unit tests colocated with the code; conformance and vectors under `tests/`.

Conformance tests are written **from the NIP text, before the implementation**, and named after
the rule they check. The three fuzz targets that matter are the ones taking untrusted bytes: the
JSON/NIP-01 parser, the filter matcher, and the WebSocket frame decoder. Assertions plus fuzzing
compound — the fuzzer finds the input, the assertion turns corruption into a visible crash.

Full strategy in [docs/testing.md](docs/testing.md).

## Measuring

Phase 0 produced two numbers that were wrong before they were right, both from sloppy setup.
Before quoting any measurement:

- **Not in Debug.** Build ReleaseSafe or ReleaseFast; Debug numbers mean nothing.
- **Not on tmpfs.** `/tmp` is tmpfs here, where `fsync` is nearly free, so every durable-write
  figure taken there is meaningless. Put the store on a real disk.
- **State the conditions** — hardware, dataset, concurrency, durability mode — and prefer
  reporting a ratio over an absolute.
- **Never publish a non-durable number** without labelling it. That is the criticism
  [docs/overview.md](docs/overview.md#2-it-is-fast) levels at prior art; repeating it would make
  our numbers worthless.

## Keeping the documentation true

| If you change | Update in the same change |
| --- | --- |
| Wire behaviour | [docs/protocol.md](docs/protocol.md) |
| A NIP's status | [docs/nips.md](docs/nips.md) — NIP-11 is generated from it |
| A recorded decision | its ADR |
| A build command | [docs/development.md](docs/development.md) — it promised `zig build fuzz` once, which never existed |
| A setting | [docs/configuration.md](docs/configuration.md) |

Documentation is English. `docs/research/` is dated background, sometimes Spanish, and is not
maintained — do not update it to match the code; it records what was true when written.
