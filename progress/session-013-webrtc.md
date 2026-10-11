# Session 013 — SignalFish WebRTC byte delivery

Delivery is unfinished. PR #71 remains unmerged after a live CI confirmation
stall tracked in issue #72. Positive receipts below bind earlier candidates;
the final diagnostics patch changes witness hashes and awaits new execution.

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

The earlier source-bound browser receipt passed at
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
browser reviews found no remaining revisions in that earlier candidate.

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

## CI render-turn budget and engine concurrency

The next CI run exceeded the unchanged 180-second outer Node watchdog during
the faulted 4.3 matrix. The 2/4-peer rooms had completed all frames and
canonical checks. Every 8-peer participant had reached gameplay wait 14 or 15;
none reported an inner timeout, protocol error or final-confirmation stall.
The host yielded eight rendered Godot timer turns per input frame. The repair
keeps all eight transport polls and simulated-time advances, then yields once
after the batch. Every acceptance check, fault schedule and watchdog remains.
Independent review finds no required revisions. A real two-CPU run verifies
progress under contention.

Minimum/current engine suites now run in two independent CI jobs. Both retain
all smoke, representation, SDK, runner, unit, determinism and oracle checks.
Each selects its pinned engine for the existing per-engine command list and
uploads uniquely named artifacts. All 30-minute job watchdogs remain.

## Earlier source-bound local receipts and current CI blocker

Candidate `2e20d1c7015753550c1957deaf20fa1344cf4b04` passes all eight browser
runs under actual two-CPU affinity. Independent review verifies every log
hash and frozen helper/addon/export inventory. Receipts for that candidate:

| Engine | Receipt | SHA-256 |
| --- | --- | --- |
| 4.3 | `.cache/session-013/webrtc-ci-batched-4.3/signalfish-webrtc.json` | `acc2730014285ddcd18963897075c06f2a8cb061133436ec9a16bdbb11b8aa45` |
| 4.7.2 | `.cache/session-013/webrtc-ci-batched-4.7.2/signalfish-webrtc.json` | `618238ef176d64af9c751346a37bf148ab2f1f57ecad65fd69ebc3c07e022a0e` |

These local passes do not establish green CI. Reference workflow
[38162898633](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/38162898633)
fails its live transport job `114539356227`. Both engine unit/oracle jobs,
reference controls, pinned Rust, devcontainer checks, harness lint and the
automatic review pass. Godot 4.3's complete direct matrix passes, followed by
4.7.2's clean matrix. The faulted 4.7.2 eight-peer room then stalls.

All eight peers submit 40 frames. Peers 0/3/5/6/7 reach canonical checks;
peers 1/2/4 remain at `final_confirmation`. Node's gameplay-completion barrier
expires after 120 seconds. Its captured errors array is empty; two- and
four-peer fault rooms pass. No canonical mismatch is reported. The launcher
correctly retains a false receipt. Exact failure logs are in
[artifact 11711640644](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/38162898633/artifacts/11711640644),
under `signalfish-webrtc/4.7.2-faults.log` and `4.7.2-faults-events.log`.
Local extracted copies are `.cache/session-013/ci-third-failure/`.

Endpoint INPUT retries publish receipt gossip while pending inputs remain;
ACK-only packets do not publish refreshed gossip. This is an investigation
hypothesis, not a demonstrated root cause. The logs lack pending-bank and
endpoint receipt/status snapshots. Preserve every check and watchdog; add
bounded in-loop diagnostics before attempting a protocol or pacing repair.
[Issue #72](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/72)
records exact reproduction artifacts and all remaining delivery gates.

The final patch adds diagnostics only; it does not repair the unknown stall.
Its changed witness hashes supersede candidate `2e20d1c` for current-source
verification. The positive local receipts remain historical evidence for
their recorded sources. New current-head execution and CI remain pending.

The session's two-hour boundary prevents completing another reviewed repair,
PR CI cycle and merge-triggered main CI cycle. PR #71 remains unmerged; main
stays at previously green `026590cd315c0e3e4e66929cb7da364020c532f2`.
Continue on this existing PR, diagnose #72, then obtain green current-head CI,
complete feedback scans, guarded squash merge, local main synchronization and
main CI verification. No transport task is closed and no failed gate is waived.

## Bounded confirmation diagnostics

The final change instruments the unresolved wait; it does not claim a repair.
After a failed final-confirmation condition, the host emits an immediate public
status snapshot and at most five more at five-second wall-clock intervals.
Snapshots include current/confirmed/pending-rollback frames, endpoint submitted,
sent/received/acked frames, pending frame IDs, progress time and receipt gossip.
Only frame IDs are logged from pending banks; packet payloads are excluded.
No pacing, simulation time, transport service, acceptance or watchdog changes.

Fresh adversarial review verifies the public status fields, copied ownership,
bounded endpoint/frame/status payloads and unchanged execution conditions.
Both pinned engines parse the frozen host successfully; GDScript lint passes.
Harness verification passes 99 self-tests, all metadata/link/length checks,
fresh generated artifacts and source widths across 203 files. The five Python
probe tests (including table-driven mutations) and Node orphan control pass.
The first Python invocation used the wrong module search directory and failed
import; rerunning from `scripts/reference` passes. This is a command correction,
not a changed expectation or implementation repair.

Changing the inventoried host supersedes all earlier browser receipts for
current-source acceptance. The candidate must run a new source-bound browser
matrix and current-head CI; the production addon remains unchanged since the
reviewed initial runtime candidate. The diagnostic export is validation of
logging only, never evidence that the CI stall is fixed.

The frozen diagnostic host executes successfully in the actual Godot 4.7.2
export. Its clean four-peer log contains a parseable `FINAL_CONFIRMATION_STATUS`
with current frame 40, confirmed frame 37, pending rollback 39 and all three
endpoint pending/gossip dictionaries. Evidence:
`.cache/session-013/webrtc-diagnostic-frozen-4.7.2/4.7.2-clean-events.log`.
This establishes diagnostic execution while the condition is false, not a
repair of the CI failure or a complete current-source browser acceptance pass.

## Authorized continuation

The user extends the session limit to four hours. Continue the existing PR #71
and investigate its current diagnostic failure, rather than treating the earlier
two-hour handoff as completion. Original start is 16:38:47 UTC; the extended
session boundary is 20:38:47 UTC. Work resumes at 19:05 UTC.

The current diagnostic CI run `38164142071` finishes both engine unit/oracle
jobs successfully but rejects Godot 4.3's faulted direct browser scenario.
Artifact `11711119282` contains the endpoint snapshots needed for root-cause
localization. Preserve all confirmation, canonical state, fault and watchdog
checks. The existing runtime and browser review receipts are bounded historical
evidence; current-head delivery still requires a repaired live CI gate.

## Elapsed transport clock investigation

The current diagnostic artifact distinguishes the symptoms. Its Godot 4.3
faulted eight-peer room remains at gameplay waits 18/19; it never enters final
confirmation. All two- and four-peer frames and canonical checks pass.
The preceding Godot 4.7.2 failure reaches final confirmation, but its Node
watchdog also starts at gameplay frame zero. Neither is an independent
120-second final-confirmation timeout.

The host increments protocol time by 2,000 microseconds per rendered timer
turn. The production input endpoint retries after 200,000 microseconds.
A slow rendered turn therefore delays actual retries while the independent
Node watchdog continues measuring elapsed real time. The
[Godot 4.3 timer documentation](https://docs.godotengine.org/en/4.3/classes/class_scenetreetimer.html)
places SceneTreeTimer processing after the current frame's nodes; a requested
2ms delay does not establish that only 2ms elapses before resumption.

A deterministic native regression supplies 16ms clock samples and drops an
actual endpoint INPUT. The original host fails to retry after 13 turns and
208ms because its transport clock records only 26ms. Red logs on both pins:
`.cache/session-013/webrtc-clock-red-<version>.log`. The repaired clock reads
elapsed monotonic time from the owned handshake epoch. Both pins retry after
208ms and at least seven times over 100 turns/1.6 seconds, retaining the
original pending input. Simulation still uses the same 40 original frames and
inputs; no canonical, confirmation, fault or watchdog bound changes.

Independent protocol review excludes a receipt-generation cycle and premature
cumulative ACK removal. Frame 39 is emitted only after all remote receipts
reach 38, so its outgoing gossip protects the final target. The changed host
clock is the repair boundary; no production protocol change is justified.

A full real-export run then reaches a previously masked handshake retry.
`Peer.poll` correctly rejects its missing fresh token with INVALID_ARGUMENT.
The host must supply caller-owned tokens for polling and incoming handshake
callbacks. This is a separate demonstrated caller defect. The clock-only
cold review passed, but the token repair requires new execution and a new
fresh-context review before delivery. The new clock regression and reused
actual endpoint fixture are inventoried, executed before export, and their
logs are cleared and hashed with the complete receipt.

## Final elapsed-clock and retry-token candidate

Both frozen-source browser matrices exit zero, with all clean, faulted, corrupt
and default-factory scenarios passing their expected outcomes on both pins.
Current receipt paths and SHA-256 values:

- `.cache/session-013/webrtc-deadline-final-4.3/signalfish-webrtc.json`: `6bda63087f4a052f013a8e53b2c6c382c10ee0a1f1257cf391f3c564092616db`.
- `.cache/session-013/webrtc-deadline-final-4.7.2/signalfish-webrtc.json`: `a54b9d661d9c1d9f495acc080cb87868d8ea597de84f2d38197803487f9c59c0`.

All 56 positive peer instances preserve 38 canonical and 37 active comparisons
each, confirmed frame >=38, actual rollback, original inputs and physical
connection/channel teardown. Faulted runs drop 340/344 packets and delay
241/246 packets respectively. No watchdog or acceptance requirement changes.

Fresh-context adversarial review independently passes the elapsed-clock, epoch,
actual dropped-input retry and fresh handshake-token tests on both engines.
The zero-argument callback mutant fails; the repaired callback accepts the
public UUID argument. Exit failures and script errors remain rejected even
with a plausible success marker. Independent artifact review validates every
label, log digest and current helper/addon/SDK binding. Export inventories were
frozen during execution; temporary exports are unavailable for post-run rehash.

Verification passes 99 harness self-tests and source widths across 204 files.
Reference Python discovery reports 41 tests with three expected skips. GDScript
lint and four browser controls pass. Hosted current-head CI, feedback scans,
squash merge and merge-triggered main CI remain required; linked issue #72
records the delivery evidence without committing stale green claims.

## Hosted render-cost failure and viewport comparison

Head `24e1de6d97e218ce267bd512ac272d201621cf33` passes eight of nine
checks, including both full engine suites. The live browser job rejects
Godot 4.7.2 clean eight-peer final confirmation after all four Godot 4.3
labels pass. Run `38168114912`, job `114554824345`, artifact `11713325728`.
The event snapshots show continuing receipts/ACKs with pending inputs 38/39,
not the empty-pending gossip gap independently reproduced in issue #73.
Peer 0 executes 36 service turns in 10.194 seconds; peer 5 executes 53 in
15.486 seconds. Peers enter final confirmation at 102–119 seconds; Node's
existing 120-second whole-gameplay barrier then expires.

The current browser contexts use the default 1280x720 viewport despite a
Node-only nonvisual game. The unchanged two-CPU baseline completes its clean
2/4/8 matrix in 65.189 seconds from first engine console event to result.
Its subsequent fault run is deliberately stopped for the comparison; the
baseline receipt remains false/incomplete. Timing evidence lives in
`.cache/session-013/webrtc-viewport-baseline/render-timing.json`.

The candidate changes only the browser context viewport to 64x64. Real
Compatibility rendering, independent engine/browser processes, channels,
faults, gameplay, source guards and watchdogs remain unchanged. Node syntax
and physical orphan controls pass. Full current-source eight-label execution
is running with the same two-CPU affinity before acceptance or merge.

Independent core review also reproduces an existing exhausted-prediction
receipt gossip gap on both engines. All inputs and ACKs drain but identical
stalled samples cannot emit changed gossip. Issue #73 includes a standalone
reproduction, exact source references, pinned Rust policy audit and recovery
acceptance. It is distinct from this browser schedule and transport PR.
