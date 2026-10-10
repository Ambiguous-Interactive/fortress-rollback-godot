# Upstream runtime oracle and game boundary replay

The development oracle executes the pinned Fortress public sync-test API.
It emits actual ordered save/load/advance requests and API errors. Rust remains
development-only; there is no production Godot session implementation yet.
This advances [V2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/17)
and the independent game-state portion of V3 without claiming session parity.

## Reproduce

```sh
make test-oracle
python3 scripts/oracle/launch.py --godot /absolute/path/to/godot
```

Use `--offline` after the pinned references, Rust toolchain and crates are cached.
The launcher validates source archive integrity and re-extracts the references.
Cargo builds with the committed lockfile, Rust 1.94.0 and no upstream default or
optional features. The upstream default prediction window is eight frames.
Run separately with Godot 4.3 and current pinned 4.7.2. CI runs both.

The result directory contains exact scenarios, traces, process logs, mutants
and `receipt.json`. A failed attempt removes the previous success receipt first.
The receipt records source/manifest/compiler/binary/engine identity, commit,
dirty-worktree state and scenario/trace hashes. It is scoped development evidence,
not a release coverage certificate.

## Scenario version 1

All fields are required; unknown fields fail. `format` is integer 1 and
`upstream_revision` is `f13cd5c0f2815926785a395947e18da0dbea0dd8`.
`players` is 2–8; `input_width` is four bytes; `check_distance` and
`input_delay` are 0–7. `operations` contains 1–10000 ordered operations:

| Kind | Fields and behavior |
| --- | --- |
| `input` | `player` integer 0–255 and `bytes` eight lowercase hex digits; call `add_local_input` |
| `advance` | No other fields; call `advance_frame` and fulfill actual requests in return order |
| `events` | No other fields; drain the public event API |

Out-of-roster bounded handles are intentional negative inputs to the real API.
Missing local samples produce actual upstream errors. Unknown versions, empty
operations, empty/wrong-width bytes and stale revisions fail before execution.
JSON integers in this bounded schema are exact. Wide checksums use hex strings.

## Trace version 1

The trace contains `format`, `upstream_revision`, the exact `scenario`, one
`operations` record per submitted operation, and `final_state`.
Operation records contain `index`, `kind`, `result` (`ok`/`error`), `error`
(null or the upstream Debug diagnostic), `frame_before`, `frame_after`,
`confirmed_frame`, `requests` and `events`.

`confirmed_frame` is null: public sync-test exposes no confirmed-frame getter.
The pinned sync-test event drain is empty. These are explicit observation gaps,
not inferred confirmation or fabricated protocol transitions. Error diagnostics
are pinned-source strings; a revision change requires a reviewed schema/fixture
decision before comparisons use them.

Each request contains `kind`, `frame`, `state_bytes`, `checksum` and `inputs`.
Save/load frame names `S(frame)`. Advance frame names the input frame and its
bytes/checksum describe `S(frame+1)` after simulation. Snapshot requests have
empty inputs. Advance inputs use ascending player slots with four-byte hex and
the actual `confirmed`, `predicted` or `disconnected` status.

`final_state` contains `frame`, `bytes` and `checksum`. Validators reject
missing/extra operations, wrong identities, impossible frame chains, loads
without saved bytes, wrong slot ordering, and mismatched canonical state.

## Independent game and controls

Canonical state is a little-endian signed32 frame followed by one unsigned32
accumulator per player. Each advance adds that player's little-endian unsigned32
input modulo 2^32. State includes every value influencing continuation.
The diagnostic unsigned128 checksum has FNV-1a-64 in its low limb and the
bitwise complement in its high limb, encoded as 32 lowercase numeric hex digits.
This exercises unsigned values beyond signed64 without JSON number conversion.
It is a reference-game checksum, not a promised production checksum algorithm.

Rust saves owned game clones into upstream cells. GDScript starts independently
at `S(0)`, saves owned canonical bytes, restores only its own saved snapshots,
and simulates supplied request inputs. It never restores the oracle's claimed
state bytes. Every callback checks complete state bytes and checksum.
Python separately derives every frame's input and canonical state prefix from
submitted histories for the fixed corpus, accounting for initial neutral delayed
frames. A persisted temporal-permutation mutant retains the final sum but fails
the independent prefix check. Request agreement alone cannot establish correctness.

The corpus covers every player count 2–8, distance/delay pairs 0/0, 2/2 and 7/7,
twenty successful frames, wraparound sums, distinct histories, missing-input
errors before and during rollback, recovery retries and invalid handles.
Each Rust trace and Godot replay runs twice in fresh
processes. Persistent mutants attack version/revision, empty operations/bytes,
unknown fields, handle bounds, altered state/checksum, load-state injection,
request reversal and missing operations. Process tests reject nonzero exits
with plausible output, timeouts, partial completion and stale success receipts.
The load mutant selects by kind, preserves frame/checksum consistency, and must
fail at that exact load's canonical state comparison.

## Remaining requirements

V2 remains open. The scenario vocabulary currently covers sync-test public APIs;
P2P setup, injected time, packet deliveries and protocol observations still need
their implementation and tests, tracked in
[follow-up #59](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/59).
GDScript verifies game boundaries, not a second
session engine. V3 must later compare the two actual session implementations.
There is no browser oracle execution or full-feature differential claim.

The corpus observes missing-input errors and recovery retries through the real
API, including after rollback begins. Other error/recovery classes need their own
upstream witnesses. The adapter rejects violated save/load boundaries; it does
not normalize away missing requests or substitute game state.
