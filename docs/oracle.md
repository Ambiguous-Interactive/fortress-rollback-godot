# Upstream and production session oracle

The development oracle executes the pinned Fortress public sync-test API.
It emits actual ordered save/load/advance requests and API errors. Rust remains
development-only. Godot independently executes the same scenario operations
through its shipped session engine, then compares complete generated requests.
This advances [V2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/17)
and the sync-test portion of V3; P2P and advanced-feature evidence remain open.

## Reproduce

```sh
make test-oracle
python3 scripts/oracle/launch.py --godot /absolute/path/to/godot
```

Use `--offline` after the pinned references, Rust toolchain and crates are cached.
The launcher validates source archive integrity and every extracted file before reuse.
Cargo builds with the committed lockfile, Rust 1.94.0 and no upstream default or
optional features. The upstream default prediction window is eight frames.
Run separately with Godot 4.3 and current pinned 4.7.2. CI runs both.

The result directory contains exact scenarios, traces, process logs, mutants
and `receipt.json`. A failed attempt removes the previous success receipt first.
The receipt records source/manifest/compiler/binary/engine identity, commit,
dirty-worktree state and scenario/trace hashes. It is scoped development evidence,
not a release coverage certificate.

## Scenario versions 1 and 2

All fields are required; unknown fields fail. `format` is integer 1 or 2 and
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

## Trace versions 1 and 2

The trace format equals the scenario format. The trace contains `format`, `upstream_revision`, the exact `scenario`, one
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

Version 1 canonical state is a little-endian signed32 frame followed by one unsigned32
accumulator per player. Each advance adds that player's little-endian unsigned32
input modulo 2^32. State includes every value influencing continuation.
Version 2 appends unsigned32 PRNG and pending-event state, seeded to 8173 and
zero. Each tick first updates the PRNG with `(rng * 1664525 + 1013904223) mod 2^32`.
Each accumulator adds its input, the previous pending event, and
`(rng & 255) * (player + 1)`, modulo 2^32. The next pending event is the weighted
sum of current inputs, `sum((player + 1) * input[player]) mod 2^32`.
All fields are restored; both extra fields influence subsequent gameplay.
The version 1 corpus and serialization remain unchanged. Version 2 runs the same
21 roster/distance/delay scenarios with this stateful game. A neutral first tick
with two players encodes `0100000068000000d000000068004e6700000000`.

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
Each Rust trace, Godot game replay and production Godot session runs twice in
fresh processes. Four independent scenarios run concurrently by default;
`--jobs 1` selects serial diagnosis, with accepted bounds 1–8. Setup/build and
negative controls stay serial. Each scenario owns its logs and fixtures; final
receipts retain corpus order. Failed scenarios prevent successful receipt publication.
Production-session comparison validates its trace independently,
then compares every ordered request, input status, callback state and frame.
Only structured invalid-player/missing-local error categories and unavailable
Rust confirmation are projected. Error projection accepts only the pinned full
`InvalidRequestStructured { kind: MissingLocalInput }` diagnostic or
`InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(H), num_players: N } }`.
`H` must match the submitted player in `N..255`, and `N` must match the configured
roster in `2..8`; unrelated messages containing variant names are rejected.
Six per-case mutants reject missing completion, operations or requests, changed
input status, unknown errors and changed final checksum. Separate game controls
reject request reversal and altered load bytes. Persistent mutants attack version/revision, empty operations/bytes,
unknown fields, handle bounds, altered state/checksum, load-state injection,
request reversal and missing operations. Process tests reject nonzero exits
with plausible output, timeouts, partial completion and stale success receipts.
The shared stateful game also runs through the public driver with deliberate
PRNG and pending-event restore omissions. Constant checksum collisions still
produce `DESYNC` at the first differing saved frame. An uninterrupted run checks
canonical bytes after every successful healthy step. Restore rejection is atomic.
Persistent process-mutation controls run separately for both format versions.
State/checksum controls must consume every request before their final comparison
fails; empty-work controls must fail scenario validation with zero requests.
The load mutant selects by kind, preserves frame/checksum consistency, and must
fail at that exact load's canonical state comparison.

## Remaining requirements

V2 remains open. The scenario vocabulary currently covers sync-test public APIs;
P2P setup, injected time, packet deliveries and protocol observations still need
their implementation and tests, tracked in
[follow-up #59](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/59).
The sync-test corpus now compares two actual session implementations. V3 still
requires P2P time/delivery comparison, richer generated exploration and shrinking.
There is no browser oracle execution or full-feature differential claim.

The corpus observes missing-input errors and recovery retries through the real
API, including after rollback begins. Other error/recovery classes need their own
upstream witnesses. The adapter rejects violated save/load boundaries; it does
not normalize away missing requests or substitute game state.
