# Session 012 — SignalFish membership and binary relay

## Contract and priorities

The session advances [S1](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/35)
and [S2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/36)
toward real multiplayer setup and binary relay delivery. Main started green at
`8014551c5a5176eac77ed1db8355ed3f65cc0b57`; no PR or worktree changes needed carrying forward.
The current playable example uses in-process delivery. Stable room identities,
configuration agreement and optional SDK installation are prerequisites for
relay gameplay. The session now implements the bounded binary relay adapter;
real WebRTC delivery and browser release validation remain separate gates.

Hypothesis: every client can derive the same frozen slots from a differently
ordered UUID roster. Existing peer handshakes can reject disagreeing rosters,
configuration and session identity before gameplay. Transport plans must not
renumber slots or turn reconnection into rollback authority.

## Initial evidence

Both engine pins pass the unchanged 107-case unit baseline through the normal
runner and both deterministic repetition layers. Receipts:
`.cache/tests/session-012-baseline-4.3.json` and
`.cache/tests/session-012-baseline-4.7.2.json`.

The clean-install audit previously instantiated only its gameplay-reachable
scripts. A real unused adapter with a missing SDK preload still produced a
successful package receipt. The new regression fails before repair with
`AssertionError: ValueError not raised`; log:
`.cache/reference/session-012-package-red.log`.
The audit now loads every runtime GDScript in the addon-only installation.
This gap predates available history; there is no claimed passing pre-regression
revision. During development, the stronger audit also caught a real Godot 4.3
`PackedByteArray.sha256_buffer` parse error in the new membership code.

## Scope and delivery

The shipped seam configures the existing peer engine from an owned sorted UUID
roster. A roster/configuration digest binds full UUIDs and canonical protocol
bytes. Both core and SDK numeric identity collisions are refused. SDK plans
preserve server offerer roles and opaque generations, while lifecycle changes
require a new session. The application supplies installed SDK objects and
drives relay polling; the production relay adapter owns accepted outbound
bytes, framing, sender checks and recipient filtering.

The first independent review reproduced a player-ID mix-up after a failed
connection initialization and an additive SDK `NewPeer` event. A separate agent
confirmed it on both pins, then added a guard before SDK mesh consumption. The
real SDK regression checks a matching retry, the differing player ID, no extra
connection creation, refused ingress and the persistent restart boundary.
The S1 fresh-context review found no actionable issues in all 13 candidate
files, with unchanged source inventories. It independently passed the nine seam
cases, real SDK witness, SDK-free package controls and process receipt controls
on both pins. Its broader unit attempts used a watchdog and are not counted as
passing evidence; the root runs the explicit CI budget below.

## Reproduction and evidence

For each version `4.3` and `4.7.2`, use the editor
`.cache/reference/editors/<version>/Godot_v<version>-stable_linux.arm64`:

```sh
python3 scripts/run_godot_tests.py --godot <editor> --timeout 120 --results <unit-receipt>
python3 scripts/run_godot_tests.py --godot <editor> --category determinism --results <determinism-receipt>
python3 scripts/reference/package_audit.py --godot <editor> --output <package-output>
python3 scripts/reference/test_package_audit.py --godot <editor> -v
python3 scripts/reference/signalfish_probe.py --godot <editor> --offline --output <sdk-output>
```

Focused membership receipts precede the additive event repair:
`.cache/tests/session-012-signalfish-unit-<version>.json` (eight cases, 740
assertions per in-process repetition). Both engine pins also pass three isolated
mutations at their declared digest, collision and lifecycle assertions. Commands
and retained outputs are in `.cache/session-012/mutate_membership.py` and
`.cache/session-012/*-red.log`. The additive-event red uses the pinned SDK
reproducer at `/tmp/adversarial-s1-gwhc88ek/probe.gd`; the committed regression is
`scripts/reference/signalfish_probe_new_peer.gd` and the final green receipts are
`.cache/reference/results/sdk-newpeer-green-<version>/signalfish-sdk.json`.

The SDK witness executes its actual public decoder, room/plan state, mesh
attachment and binary send/receive boundary. Exact bytes pass through the SDK
into 70 two-peer gameplay frames with confirmation through at least frame 68.
Source, executed-project and tool inventories are captured before execution and
checked before publishing success. Process controls reject failed exit,
incorrect UTF-8, timeout and changing source/tool evidence.

For S1, `make test-reference` passes 31 tests, with three engine controls explicitly
skipped in its no-engine invocation; those controls run through the commands
above. `make test-oracle` passes 52 tests. Source widths pass across 177 files
with the existing 180-character editor/formatter setting. Harness validation and
99 self-tests pass after canonical guidance curation.

Final S1 root full-suite receipts are
`.cache/tests/session-012-final-full-<version>.json`: all 116 unit cases pass in
both fresh processes and each process's deterministic repetitions under the
explicit 120-second budget. Both determinism suites pass in
`.cache/tests/session-012-final-determinism-<version>.json`. Final SDK and clean
package receipts are under
`.cache/reference/results/session-012-final-{sdk,package}-<version>/`.
GDScript lint passes when the deliberate parse-error fixture is excluded.
The SDK witness uses the standard max-return lint exemption for sequential
fail-fast integration checks; both native witnesses were rerun afterward.

## S2 binary relay extension

The production adapter wraps each core packet in a versioned envelope carrying
session, sender and recipient identity. It checks the SDK-attributed sender
before accepting a broadcast, and queues only packets addressed to the local
player. A drained peer batch remains caller-owned until the adapter accepts
the whole batch; queue limits cannot consume a prefix and lose the rest.

Send refusal retains the exact FIFO head for retry. Packet/byte capacity,
SDK socket backlog and per-poll receive/send work have separate bounds.
Lifecycle changes keep the restart requirement established by membership setup.
The adapter does not replace plan generations with rollback session identity.

Both `.cache/tests/session-012-relay-unit-<version>.json` receipts pass eight
relay cases with 96 assertions per in-process repetition, repeated in two
fresh processes. Three mutations on each engine pin remove refused-head
retention, sender attribution and recipient filtering. All six controls fail
at their intended assertions, with commands and logs retained in
`.cache/session-012/mutate_relay.py` and
`.cache/session-012/{busy-head-loss,sender-attribution,recipient-filter}-<version>-red.log`.

The real pinned SDK witnesses pass on both engines in
`.cache/reference/results/sdk-relay-final-<version>/signalfish-sdk.json`.
For 2, 4 and 8 players, each submits 40 frames with varied local inputs and
compares corrected confirmed game state to an independent canonical prefix.
Each engine receipt records 76, 152 and 304 comparisons respectively (532
total), and 37,546 broadcast deliveries. These counts cover the three
scenarios within one engine run; they do not count a live server or WebRTC.
The production relay adapter and actual SDK binary decoder/send API execute
through the injected transport, with source and tool inventories retained.

The first S2 full-suite receipts
`.cache/tests/session-012-relay-full-<version>.json` have `passed: false`:
all 124 cases complete without assertion failures in each process, but the
pressure case has 16 assertions in the first fresh process and 17 in the
second. Root and fresh review isolated an added send-count assertion and
guarded indexing in that test while the processes ran; runtime code was
unchanged. The runner correctly rejected changing test evidence. Frozen reruns
are `.cache/tests/session-012-relay-frozen-full-<version>.json`; both pass all 124 unit cases through both repetition layers under the explicit
120-second budget. The S2 fresh review found no actionable issues and passed
focused cases and actual SDK witnesses on both pins, plus 66,264 envelope
truncation checks on Godot 4.3. Standard lint exemptions for public type aliases
and sequential witness checks change comments only; final source-bound SDK
receipts are `.cache/reference/results/session-012-relay-final-sdk-<version>/`
and GDScript lint passes. Native witness evidence and its subsequent review
repairs are recorded separately below.

## Native WebSocket witness and review repairs

The committed `scripts/reference/signalfish_build_server.py` builds the pinned
SignalFish server from a freshly verified archive. It cleans the server package,
uses `cargo build --locked --no-default-features --bin signal-fish-server`, and
checks source/tool inventories before and after compilation. The receipt binds
the resulting executable bytes to source revision
`9c2fb8fa635a69241b8ccf38be651d561fef7434`.
`.cache/reference/results/session-012-native-server-build/build-receipt.json`
passes; `.cache/session-012/server-build-source-control.json` confirms a changed
source tree is rejected with exit 1. Offline preparation also passed with raw
crate archives and registry indexes cached, followed by fresh source unpacking.

The native launcher `scripts/reference/signalfish_live_probe.py` requires that
build receipt and rechecks pinned source, executable and tool identity. The
GDScript witness uses actual SDK WebSocket connections to the loopback server,
production membership/relay adapters and varied gameplay inputs. Initial runs
on both pins cover 2/4/8 players, 40 submitted frames per scenario, 532 corrected
confirmed-state comparisons and 35,260 binary receives per engine run.

Fresh review exposed a late-error gap: an actual SDK protocol error injected
after the last wait still produced exit 0 and a successful result in
`.cache/session-012/live-relay/late-red-43.log`. The repair checks latched errors
after final event processing and before success, with actual protocol,
server-operation and room-join failure controls. Both
`.cache/session-012/live-relay/late-fixed-<version>/signalfish-live.json`
receipts contain the three rejected controls.

A second independent review found another omitted SDK failure signal:
`.cache/reference/results/native-final-review-auth-control.json` records an
actual late SDK authentication failure still producing exit 0 and success.
The completed repair captures the full applicable failure/lifetime event set
and checks SDK connection, authentication, player and room state before success.
The already completed native receipts under
`.cache/reference/results/session-012-final-native-relay-<version>/` contain
positive gameplay and three controls, but precede this second repair and are
historical evidence superseded by the sixteen-control runs recorded below.

Reproduction uses the committed builder followed by the native launcher with
`--godot`, `--server`, `--server-source`, `--build-receipt` and `--output`.
The [relay guide](../docs/signalfish-relay.md) provides full commands.
Native loopback WebSocket evidence does not establish browser multiplayer,
real WebRTC delivery, hosted-server behavior or live queue-pressure coverage.

## Final lifetime and build-receipt checks

The production adapter now checks public SDK connection, authentication, player
and room state before processing queued bytes. Closing a connection or clearing
room/authentication state cannot leave previously queued packets accepted under
the old room. Spectator replacement and reconnection of a known roster member
also require restart. Seven actual-decoder lifetime regressions fail before
repair on both pins in `.cache/reference/results/sdk-lifetime-red-<version>/`
and pass afterward in `sdk-lifetime-green-<version>/`.

Both `.cache/tests/session-012-complete-full-<version>.json` receipts pass all
125 unit cases through both fresh-process and in-process repetition layers.
Both `.cache/reference/results/session-012-complete-native-<version>/signalfish-live.json`
receipts pass native 2/4/8-player gameplay and sixteen actual late SDK event
controls. Each positive run retains 40 frames per scenario, 532 canonical
comparisons and 35,260 binary receives.

The latest fresh review found that the native launcher accepted incomplete
server-build metadata. The evaluator reproduced four missing-field variants.
The repair requires all nine current input hashes, the builder and server
archive hashes, actual build-log bytes and both compiler-tool hashes, alongside
verified source/executable bytes and exact successful build commands.
All six metadata/control test methods in
`scripts/reference/test_signalfish_live_probe.py` pass after repair.

The rebuilt server and stricter native launcher pass in
`.cache/reference/results/session-012-shipping-native-<version>/signalfish-live.json`.
The completed native receipts above predate the stricter metadata validation;
they are positive historical evidence, not acceptance of the changed launcher.
Those shipping runs contain all sixteen controls. A subsequent receive-pressure
repair is covered by the final source-bound release checks below.

## Receive-pressure review repair

A subsequent cold review reproduced a valid small peer ACK outbox filling during
two queued input packets. The second packet returned recoverable backpressure,
left the peer running and did not commit its input frame. The relay had discarded
that packet and latched permanent failure. Draining the ACK and directly retrying
the exact payload advanced the expected frame, proving the refusal was recoverable.
The reproduction is `/tmp/relay_review_pressure.gd`; focused regression red is
`.cache/session-012/relay-pressure-red-4.7.2.json`.

The repair retains the inbound FIFO head and an owned generated handshake token
until acceptance. Terminal lifecycle event overflow still stops the relay; bounded
outgoing work continues while receives wait. The three real-peer cases pass both
pins with 87 assertions per repetition. Baseline red fails recoverable and handshake
cases on both pins while the terminal control passes. Final focused receipts are
`.cache/session-012/test_signalfish_relay_pressure-final-<version>.json`.

Both full `.cache/tests/session-012-release-full-<version>.json` receipts pass
128 cases through both repetition layers. Final SDK and SDK-free package checks
pass under `.cache/reference/results/session-012-release-{sdk,package}-<version>/`.
Source widths pass across 189 files and GDScript lint passes. Both final native
`.cache/reference/results/session-012-release-native-<version>/signalfish-live.json`
receipts pass 2/4/8-player gameplay, 532 canonical comparisons, 35,260 binary
receives and all sixteen late event controls. Source/tool/build inventories
remain unchanged. The final cold review covers all seventeen technical files,
finds no actionable defects and verifies the frozen file hashes. Reference tests
pass 37 cases (three no-engine skips); harness checks and 99 self-tests pass.
Current-head CI and merge-triggered main CI remain required delivery gates.

## Limits and follow-up

The SDK's public binary signal lacks server epoch metadata; application-supplied
connection identity is distinct from plan generation and rollback session ID.
Reconnection requires explicit restart. After relay selection, restoring the
mesh also requires restart; the SDK exposes no public plan-application call.
No public SDK events are synthesized to imitate restoration.

S1 remains open for its remaining integrated setup acceptance. Further relay delivery acceptance
stays in [S2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/36),
[S3](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/37),
[S4](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38) and
[S5](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/39).
The injected SDK wire witness does not prove a live server, WebRTC delivery,
real browser multiplayer or a supported release. Broader mesh fairness and
profile acceptance stay in P5.

Retrospective: [artifact](../.llm/retrospectives/2026-10-11-signalfish-membership.md).
Final current-head CI, feedback, merge and main-CI evidence belong in the S1 and S2 issues
once delivery finishes. No pending check is represented as passing here.
