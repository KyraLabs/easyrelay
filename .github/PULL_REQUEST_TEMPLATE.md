## What this changes

<!-- One paragraph. Why, not just what — the diff already says what. -->

## Related

<!-- Closes #123, or the roadmap phase this belongs to. -->

## Checklist

- [ ] `zig build test` passes
- [ ] `zig fmt --check .` passes
- [ ] `./scripts/check-toolchain.sh` passes, if the Zig pin changed
- [ ] New behaviour has tests. Protocol behaviour has a conformance test named after the rule.
- [ ] `docs/protocol.md` updated, if wire behaviour changed
- [ ] `docs/nips.md` updated, if a NIP's status changed
- [ ] An ADR added or amended, if this adds a dependency or changes an architectural decision
- [ ] The PR title follows Conventional Commits — it becomes the squashed commit message

## For reviewers

<!--
Reviews look at protocol correctness, memory ownership, and behaviour under untrusted
input, in that order. If your change parses anything a client controls, say here what
happens when it is malformed.
-->
