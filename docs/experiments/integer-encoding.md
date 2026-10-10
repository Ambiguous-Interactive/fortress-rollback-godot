# R1: integer semantics and fixed-width encoding

Research for [issue 22](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/22), measured on 2026-10-10.
The executable primitives are research helpers, not a released addon API.

## Hypothesis and audited domains

GDScript's signed64 arithmetic can represent frames and unsigned16/32 fields
without float conversion. Unsigned64 and unsigned128 values require low-first
unsigned32 limbs or bytes. A value above 2^53 must never enter a JSON numeric
field on its way to a browser. Exact byte comparison, rather than an encoder's
self-roundtrip, is the independent acceptance gate.

Pinned Fortress reference: `f13cd5c0f2815926785a395947e18da0dbea0dd8`.
Its [frame implementation](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/lib.rs)
uses signed32 frames and a negative sentinel; its general frame arithmetic
includes saturation. Our [session contract](../contracts.md) deliberately
rejects advancement at `2147483647` before a callback, instead of saturating
and simulating the same frame twice. No generic signed overflow may substitute
for this session error policy.
The pinned [messages](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/network/messages.rs)
carry a wrapping unsigned16 connection-status epoch, monotonic unsigned32
`round_seq`, and unsigned128 checksums. The research helpers distinguish
unsigned16 wrap from unsigned32 exhaustion; neither makes a freshness decision
for a live protocol. The unsigned128 encoding preserves all 16 bytes and does
not narrow a checksum to a signed integer.

## Oracle and portable representation

[integer_vectors.rs](../../scripts/reference/integer_vectors.rs) produces
[integer_vectors.json](../../tests/determinism/integer_vectors.json) using
cached pinned `rustc 1.94.0 (4a4ef493e 2026-03-02)`, with no crate dependencies.
It uses Rust wrapping signed64 add/subtract/multiply, valid signed division and
remainder, shifts, native `to_le_bytes`, and an unsigned64 FNV-1a implementation.
It does not call the GDScript helpers. Decimal values and limbs are strings;
byte strings are lowercase hex. The inventory is asserted:
116 arithmetic rows, 28 fixed-width vectors and eight FNV known answers.

[integer_codec.gd](../../tests/determinism/integer_codec.gd) writes two, four,
eight or 16 bytes in explicit little-endian order. Unsigned16 has one limb
bounded to `0..65535`; larger values use one, two or four unsigned32 limbs,
each bounded to `0..4294967295`, least significant first. Signed32 uses one
two's-complement word and rejects values outside `-2147483648..2147483647`.
The reader rejects invalid widths and insufficient buffers before indexing.
It validates the offset before subtracting it from the buffer size, avoiding
overflow in an unchecked `offset + width` test. It reports the next offset
and permits suffix bytes for parsing a larger packet.

All helpers return explicit success/error records. They never serialize a
Godot Variant or use `hash()`. Bounds tests cover every shorter buffer length
for every supported width, negative/huge offsets and widths, wrong limb counts,
out-of-range high limbs, signed32 sign boundaries, division by zero,
`INT64_MIN / -1`, shifts outside `0..63`, frame exhaustion and sequence wrap.
No packet or replay format is introduced by this experiment.

## Measured arithmetic and checksum decision

The probes evaluate signed64 operands as runtime variables, avoiding compiler
constant folding. Signed64 addition, subtraction and multiplication matched
Rust modulo-2^64 results at min/max and beyond the 2^53 float precision bound.
Signed division truncated toward zero; remainder followed the dividend sign.
Right shift sign-extended; valid left shifts preserved the wrapped bit pattern.
Invalid shift counts are rejected by the helper rather than depending on
platform masking. Division by zero and min/-1 are rejected before evaluating
the dangerous operation; the experiment does not execute those raw expressions.

The original [checksum sample](../../.llm/code-samples/state_checksum.gd)
claimed FNV-1a but used incorrect constants and discarded the top bit after
every multiply. The repaired sample uses offset bit pattern
`cbf29ce484222325`, prime `100000001b3` and modulo-2^64 multiplication, matching
the [FNV specification](https://datatracker.ietf.org/doc/html/rfc9923).
Its digest is a signed64 representation of those bits, and wire bytes are
little-endian. Empty, `hello`, `a`, `foobar`, byte `ff`, eight zero bytes,
eight `ff` bytes and signed64-min bytes have independent known answers.
Incremental update, reset and signed64 little-endian updates are checked.
This remains an eight-byte checksum sample; it does not replace the contracted
16-byte upstream checksum domain or prove a session checksum algorithm.

## Red/green evidence and reproduction

Base working tree: `97c0d5bfef7eb5f746eae7bb51e6e573ff7e5e04` plus this experiment.
Seed: `1701`; each case executes twice with fresh fixtures and exact state-byte
comparison. Reproduce vector freshness offline after the reference bootstrap:

```sh
python3 scripts/reference/check_integer_vectors.py --check
godot --headless --path . --script tests/runner/run_tests.gd -- \
  --suite res://tests/determinism/test_integer_encoding.gd --category determinism --seed 1701
python3 scripts/reference/ownership_probes.py --offline --web
```

The checked-in Rust oracle source SHA-256 is
`420661ff0e290eceeb6e7d8d22db15b07f3aecdd99c6f2318dfaf2a73ddc25cc`.
The golden fixture SHA-256 is
`0bd78daea612bcc42998a2a021dd16fc453bfb433a705214d40cd305a7e32f22`.
The generator fails if the pinned cached compiler is missing, exits nonzero or
emits bytes different from the checked-in fixture. `--write` is an explicit
fixture regeneration operation, never an automatic expectation repair.

Meaningful negative controls:

| Control | Observed failure | Artifact |
| --- | --- | --- |
| Reverse byte shifts in the writer's first loop | Exit 1; first divergence unsigned16 vector 1, expected `0100`, actual `0000`, byte 0 | `.cache/reference/integer/endian-mutant.log` |
| Run new FNV known answers against the original sample | Exit 1; empty input expected `-3750763034362895579`, actual `2146281510213914321` | `.cache/reference/integer/fnv-original-red.log` |
| Restore writer and repair FNV constants/multiply | Exit 0; all four cases pass twice | `.cache/reference/integer/current-green.log` |

The original sample never implemented standard FNV, so there is no truthful
pre-regression historical version claimed to pass the new oracle. The Rust
known answers define the corrected contract independently of repository history.
The endian mutation is intentionally rejected rather than updating vectors.

Godot `4.3.stable.official.77dcf97d8` and
`4.7.2.stable.official.ed1daf0bf` both pass native and release-Web exports on
Linux arm64 with Chromium `141.0.7390.37`. R1 passes 446 assertions per
repetition: arithmetic 117, binary 197, bounds 104 and checksum 28. The same
JSON vectors load in both release exports; exact inventory checks prevent an
empty vector loop from passing. Complete native and Web result records match
exactly, including repeated state bytes. Four combined receipt rows contain
eight target results, including R2 alias-negative controls in every pair.
Receipt: `.cache/reference/results/ownership.json`, status `passed`,
`web_requested=true`, architecture `arm64`, seed `1701`; every source hash
matches the current files. CI runs the combined gate after the pinned engine
bootstrap and separately rebuilds the independent Rust vectors.

## Limits

Measured results apply to the exact minimum/current native and Chromium
release-Web builds in the receipt. They do not establish other browsers,
operating systems, future Godot releases, protocol freshness rules, collision
resistance, performance or full rollback parity. FNV is noncryptographic.
Continue requiring the independent oracle and platform matrix after engine
upgrades. Production arithmetic and allocation policies remain governed by
the explicit session contract, not by permissive raw overflow behavior.
