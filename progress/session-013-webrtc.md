# Session 013 — SignalFish WebRTC byte delivery

## Contract and priorities

Advance [S3](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/37)
with direct unordered byte delivery and actual exported-browser gameplay.
Main started at `026590cd315c0e3e4e66929cb7da364020c532f2`, with a clean worktree
and no open PRs. All six main CI jobs succeeded across harness, reference and
devcontainer workflows `38116543307`, `38116543304` and `38116543295`.

Hypothesis: the SDK's public mesh byte boundary can deliver the existing peer
protocol without RPC coupling or a second rollback engine. Atomic owned batches,
per-poll work bounds, attributed sender IDs and explicit lifetime fences must
survive pressure and malformed traffic. Actual browser connections must correct
confirmed game state against the original submitted histories.

The session uses specialized implementation and browser-witness agents, followed
by fresh-context adversarial review as required by GOAL.md and the review skill.
The membership, relay and direct adapters share the existing frozen UUID slots
and core peer session. Automatic fallback, safe generation replacement and the
full browser release matrix remain separate acceptance gates.

## Channel source evidence

The pinned SDK calls `create_mesh(my_id)` and `add_peer(connection, peer_id)`.
Its introductory single-channel/native-support prose cannot establish engine
behavior. Godot's [4.3 public documentation](https://docs.godotengine.org/en/4.3/classes/class_webrtcmultiplayerpeer.html)
states that `add_peer` creates three default channels, and passes its default
one-millisecond unreliable lifetime as `maxPacketLifetime`.
The direct adapter selects transfer channel zero and unordered `UNRELIABLE` mode.
No zero-retransmit or native WebRTC support claim follows from this evidence.

## Scope boundaries

Real Chromium loopback WebRTC does not establish Firefox, WebKit, Safari/device,
internet traversal or TURN deployment. Native injected adapter tests do not
establish native ICE support. Reconnect and plan replacement need an explicit
new rollback session until S4's path-switching/lifecycle contract is implemented.

## Native implementation and review

The production adapter uses the SDK's public multiplayer peer, channel zero and
unordered mode. Dedicated direct options default to 1,200-byte packets. Accepted
batches own their bytes atomically; socket/readiness refusal preserves the FIFO
head. Receive attribution is captured before `get_packet()` advances the engine
queue. One refused incoming head and its generated handshake token remain owned
during recoverable peer publication pressure, while outgoing ACK work continues.

The first fresh review reproduced old queued bytes being sent after generation
A→B→A, and after a same-generation offerer flip, on both native pins. The pinned
SDK replaces per-peer connections while preserving its multiplayer-peer object.
The committed `plan_cycle` regression failed before repair with expected
`WRONG_STATE` but actual code zero and one sent packet. The plan adapter now
publishes a monotonic local `lifetime_revision`; direct configuration captures it.
Identical repeated plans preserve the revision; changed plans, refusal and
detach/reattach invalidate the old direct lifetime. A second cold review examined
all six attack surfaces and reported no actionable findings. Explicitly passing
an old running peer after teardown violates the documented caller-owned restart
contract; it is not automatic recovery supplied by the adapter.

Native mutation controls on both pins reject ordered delivery, shifted attribution
after packet consumption, and popping a refused SDK FIFO head. These controls
use isolated temporary projects and fail at their intended assertions without
parser/runtime errors. Fifteen new direct cases cover configuration, send and
receive bounds, byte ownership, channels, sender attribution, generation cycles,
identical plans, reentry, actual peer ACK pressure, token retries and terminal
event overflow. Initial full-suite receipts are
`.cache/tests/session-013-final-full-<version>.json`; both engine pins pass both
fresh processes and each process's in-process repetitions.
These precede the actual-browser public-getter and channel-option repairs below;
they are historical evidence, not final acceptance of the repaired adapter.

The addon-only package audits pass on both pins in
`.cache/reference/results/session-013-package-<version>/`; all runtime scripts
load without the optional SDK installed. Source widths pass at 180 characters.
Harness validation and all 99 harness self-tests pass after guidance curation.
The existing 52 oracle process-control tests pass unchanged.

## Browser integration discovery

The pinned SDK treats browser loopback pages as secure contexts and refuses
`ws://` there, with its actual `protocol_error` diagnostic. The witness keeps the
SDK unchanged and uses an ephemeral local TLS terminator for WSS signaling to
the pinned server. Test-only certificate acceptance stays in the isolated
browser launcher. Production hosting still requires trusted HTTPS/WSS endpoints.

The actual exported runtime rejected configuration because the native doubles
had invented a `get_max_packet_size()` method that Godot does not publicly bind.
The adapter now enforces its own 1,200-byte path limit and observes actual send
errors. The browser also showed default `maxPacketLifetime` was ignored because
the browser option is `maxPacketLifeTime`. Native configuration dictionaries and
documentation could not establish the intended unreliable behavior. A production
GDScript connection wrapper corrects the option through the SDK's public factory,
preserving actual browser connections and the one-millisecond lifetime policy.

Session start: `2026-10-11T16:38:52Z`; target finish before `18:38:52Z`.

## Callback pressure repair

A later cold review reproduced a callback supplying 16 MiB while an actual peer
was under ACK publication pressure. The original adapters retained that token
before the decoder could reject it. A table regression was added before repair
for wrong types and lengths 0, 15, 17 and 16 MiB; both direct and relay now
validate the nullable exact-16-byte contract before copying. Both pins reject
the original reproduction with no retained token. The sweep found only these
two token-factory call sites.

The next cold review combined callback reentry (`detach()` during `poll()`) with
an invalid return. Its reproduction showed `INVALID_ARGUMENT` overwriting the
already latched `WRONG_STATE` in both adapters. The repair checks the
post-callback lifetime gate before token validation. Red-green tables combine
teardown with malformed and valid tokens, proving no token is retained after
failure. Independent review reran the original reproduction on both pins and
confirmed the preserved `WRONG_STATE`, with no remaining transport findings.
Earlier source-bound receipts precede this final repair.

## Browser pacing investigation

The faulted 8-player run first stalled one peer at current frame 6, confirmed
frame 3 and pending rollback frame 4, without a transport or core refusal.
The host waited for global confirmation before submitting the next input.
`peer_session.gd` computes that bound from third-party receipt gossip;
`input_endpoint.gd` republishes pending input during retries. Once pending input
is ACKed, a confirmation wait can prevent the next submission that carries
fresh gossip. The witness must pace by endpoint input receipt instead, then
process pending correction at the next step. Final confirmed-frame, original
canonical-prefix, active comparison and rollback-load checks remain required.
No fault schedule or watchdog is relaxed for this test-driver repair.

## Actual browser resource ownership

Constructor instrumentation exposed a channel-free connection left in `new`
state after an otherwise successful two-player match. Every negotiated channel
and connection had closed, so the earlier channel-only observer missed it.
Godot 4.3's [native WebRTC implementation](https://github.com/godotengine/godot/blob/4.3/modules/webrtc/webrtc_peer_connection_js.cpp#L96-L104)
initializes a default connection in its constructor, then destroys the old
handle during another initialization. Its [browser destroy helper](https://github.com/godotengine/godot/blob/4.3/modules/webrtc/library_godot_webrtc.js#L316-L328)
removes callbacks and the handle without closing the physical connection.
The production connection wrapper must close before reinitializing. Actual
browser constructor tracking must prove every created connection closes,
including channel-free defaults. The option-normalization-disabled control
closes its initial resource too, isolating the incorrect channel lifetime.

## Final native verification

The frozen runtime passes 149 unit cases on Godot 4.3 and 4.7.2, through both
fresh-process and in-process repetitions, seed 1701. Receipts:
`.cache/tests/session-013-shipping-<version>.json`. The same core passes all
eight deterministic cases through both repetition layers in
`.cache/tests/session-013-final-determinism-<version>.json`. Final addon-only
package audits load all 41 files without the optional SDK or development tools,
in `.cache/reference/results/session-013-shipping-package-<version>/`.

Final cold transport and connection-lifetime reviews find no remaining defects.
The lifetime reviewer additionally proves wrapper destruction with retained
inner objects, safe late signal emissions and unconfigured delegate errors.
GDScript lint passes across every affected runtime, test and browser-host file.
The reference controls pass 40 tests (three intentionally skip without engines),
99 harness self-tests and 52 oracle controls pass, and source width checks
cover 202 files with zero violations at 180 characters.

The helper-inventory sweep also repairs standalone SDK receipts: complete
successful child-process observations followed by fetch-helper or pin-file
mutation failed to reject the old probe. Both controls now fail with the
inventory-change diagnostic and preserve a false receipt. Final real SDK
witnesses pass on both pins in
`.cache/reference/results/session-013-release-sdk-<version>/`.

A new source-bound server build uses compiler toolchain 1.94.0 and pinned server
`9c2fb8fa635a69241b8ccf38be651d561fef7434`; both clean/build commands succeed.
Its receipt is `.cache/reference/results/session-013-server-build/build-receipt.json`.
Using this binary, both native relay pins pass 2/4/8-client gameplay, 532
independent canonical-prefix comparisons per engine, and all sixteen late-event
negative controls. Final addon hashes match the witness inventories. Receipts:
`.cache/reference/results/session-013-release-native-<version>/signalfish-live.json`.

The new `SignalFish relay and Chromium WebRTC` CI job builds the pinned server,
runs both exported-browser engines, then uses those verified editor bytes for
native relay checks. It preserves a separate 30-minute watchdog and runs
concurrently with the existing reference matrix. Always-uploaded artifacts
retain complete build, source, tool, export and diagnostic receipts.

## Import metadata boundary

All eight browser game/control runs passed before the final source guard rejected
Godot 4.7.2 import changes. An independent import reproduction measured 47 new
`.gd.uid` sidecars and a rewrite of the pinned SDK `icon.png.import`. Authored
GDScript and PNG bytes stayed unchanged. The launcher now checks original
authored bytes across import, permits only metadata paired with existing
inputs, and freezes the complete post-import inventory through export and
browser execution. Controls reject changed sources, deleted files, orphan
metadata and unrelated additions. The earlier false receipt remains rejected.

## Final browser verification and scope

The authoritative source-bound receipt passes at
`.cache/session-013/webrtc-final-imported/signalfish-webrtc.json`. Exact editor
bytes match the pinned archives: `4.3.stable.official.77dcf97d8` and
`4.7.2.stable.official.ed1daf0bf`; Chromium is `141.0.7390.37`.
Both engines pass clean and synthetic loss/reorder 2/4/8-peer meshes, plus
independent snapshot-corruption and uncorrected-channel controls: eight runs.
Each positive peer submits 40 original varied-input frames, compares 38
corrected canonical prefixes and 37 active states, and confirms at least frame
38. Each engine totals 1,064 canonical comparisons across both positive runs.
Every peer performs actual rollback loads. All physical connections, including
constructor defaults, and all negotiated channels close. Actual input channels
are binary, unordered, SCTP ID 3, with lifetime 1 and explicit null retransmits.

The final independent reviewer validates every log digest, current helper and
addon hashes, and both exported source inventories against pinned SDK bytes.
Only paired generated import metadata differs. Eleven affected Python controls
and the Node orphan control pass; source widths cover 203 files. Native and
browser reviews agree there are no remaining revisions.

Reproduce the final browser receipt with:

```sh
python3 scripts/reference/signalfish_webrtc_probe.py \
  --server .cache/reference/results/session-013-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/session-013-server-build/build-receipt.json \
  --output .cache/session-013/webrtc-final-imported
```

The local host-ICE witness establishes Chromium direct delivery, not WAN/TURN,
native WebRTC plugins, Firefox/WebKit, automatic fallback or live reconnect.
S3 remains open for actual SDK ICE failure, asymmetric readiness and queued
traffic across live replan boundaries. S4 owns direct/relay switching and
browser suspension recovery; S5 owns the full compatibility matrix. S2 still
requires actual slow-recipient/backlog and reconnect acceptance. Detailed
follow-ups and post-green delivery evidence belong in their linked task issues.

## CI prediction coverage investigation

The first current-head transport CI run rejected its clean Godot 4.3 result.
The four-player room's peer 0 submitted all 40 frames, confirmed frame 38 and
passed all 38 canonical and 37 active comparisons, but performed zero rollback
loads. Other peers performed 39 loads. Host scheduling allowed that peer to
receive every original input before advancing. Clean gameplay correctness did
not establish the required prediction-correction coverage.

The test driver must coordinate the first predicted step before any participant
delivers its frame-zero input. This preserves actual WebRTC transport, original
inputs and every existing acceptance bound. Handshake acknowledgements must
continue until all participants are running, and negative-control terminal
results must release coordinator waits. The zero-load parser mutant remains
rejected. The earlier local receipt remains valid only for its earlier sources.

The coordinated first-step repair passes the actual clean 2/4/8-peer
reproduction: every peer performs rollback loads, including the previously
unexercised position. Independent review proves no frame-zero bytes leave
before all peers predict; handshake acknowledgements remain live. Both
coordinator waits accept terminal gameplay status so failed controls proceed
to teardown. Python/Node controls, GDScript lint and source/harness lint pass.
New source-bound runs and current-head CI provide final execution evidence.
