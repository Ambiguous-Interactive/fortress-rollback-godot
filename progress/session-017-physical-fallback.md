# Session 017: Preserve games after physical channel loss

## Objective and starting state

Advance GOAL.md through one reviewed session PR, including concrete gameplay
recovery work in #75 and the unfinished repair from session 016.
Initial active work starts 2026-10-12 05:12 UTC. The user pauses at about
05:20 UTC and resumes at 19:32 UTC; paused time is excluded from active work.
Target fewer than two active hours, with delivery before 21:24 UTC.

The initial clean branch is `session-016-overlap-repair` at
`8566730ce43b2395401bc162aaa9735d9493dd81`. Its reviewed validator repair
remains unmerged. Remote main is `01f4b052bda6b96329003b4870762c140a3aad12`.
Authenticated issue/PR reads find no open PR or draft. Main Harness and
Devcontainer workflows pass; Reference run `38203080272` is terminal failure.
The previous goal turn made progress: it left a reviewed repair and precise
browser-stall evidence. This session carries those changes forward.

## Physical outage contract and repair

The same exported PeerSession, membership and fallback coordinator now close
one actual unreliable WebRTC channel at source frame four. The destination
comes from the captured original packet's frozen UUID-to-peer mapping through
public SDK/engine methods. The affected pair retains real relay service through
final confirmation. Other links continue actual direct delivery. No replacement
channel, membership change or transparent reconnection is introduced.

Every successful peer still submits 40 original inputs, compares 38 corrected
canonical prefixes and exercises real rollback loads. Existing monotonic history,
owned-queue/socket limits, exact direct/relay packet overlap, corruption,
channel-policy, fallback-disabled watchdog and teardown gates remain required.
Physical closure evidence reconciles the exact pair, source initiation at frame
four, actual close events, absence of late sends on closed channels and physical
bidirectional relay receipts. Source close events cannot precede initiation.

The preliminary 4.7.2 two-peer physical run preserves gameplay but fails on
an engine error during SDK teardown. Godot automatically removes the failed peer;
the pinned SDK later removes its retained entry again. The addon now provides
`FortressSignalFishWebRTCMultiplayerPeer.create` for the SDK's public
`multiplayer_peer_factory`. It removes present peers normally and tolerates
already absent peers. #78 records the issue, reproduction and acceptance.
Installation docs and CHANGELOG name the required factory setup.

Native regression evidence uses actual engine meshes and public dynamic calls.
The ordinary engine peer emits `!peer_map.has(p_peer_id)` errors; the fail-closed
launcher rejects both processes despite their passing structured assertions.
The guarded factory passes repeated absent removal and normal present removal.
Receipts: `.cache/tests/session-017-removal-red.json`,
`.cache/tests/session-017-removal.json` and `session-017-removal-4.3.json`.
This is a newly exposed SDK integration defect; no earlier physical witness
exists to claim a pre-feature passing baseline.

## Slow service investigation

Original CI has 35 diagnostic pairs averaging 296.610 ms per transport service
turn (range 283.485–320.676 ms), slower than the 200 ms input retry interval.
The waiting loop previously polled once per rendered host turn, while the
post-step loop already used eight bounded polls. Retry inputs and their ACKs
can therefore accumulate ahead of fresh receipt gossip in the physical FIFO.
The waiting loop now also uses eight bounded polls. Clocks, default budgets,
original samples and all watchdog deadlines remain unchanged.

The controlled production-coordinator fixture models browser packet visibility
at yielded host boundaries, eight peers, default 8-send/8-receive/8-route work,
300 ms turns and caller-owned refused batches. Preliminary single-poll runs
reach stale final confirmation. Their gameplay and queue measurements are superseded:
the first measurement omitted post-step and confirmation-drain arrivals, and a
fresh review found an extra delivery boundary before successful-wait readiness.
The final helper checks readiness before yielding and samples every active
delivery boundary. It skips final confirmation after failed gameplay, matching
the actual host's immediate failure return. Final both-pin evidence stops single-poll
gameplay after 14 frames, with minimum received frame 12 and confirmed frame 12
on every peer. Its maximum per-peer incoming FIFO is 430 packets. Eight polls
finish all 16 original frames, with every peer received and confirmed at 15,
and maximum incoming FIFO 28. All four repetitions on each pin match exactly.
Its injected time is fixed inside each batch; real host service reads elapsed
monotonic time on every call. No arbitrary slow-caller throughput is promised.

An earlier exploratory fake caller discarded refused batches and appeared to
stall after 12 frames with backlog 239. That evidence is superseded and cannot
support the final root-cause claim. Correcting ownership and measuring backlog
after delivery removes the false result. The slow composed test belongs in the integration tier,
with a separate unchanged 120-second process cap, rather than expanding the
ordinary unit watchdog. Both pins run that tier in CI.

The staged clock fixture directly awaits the actual host's immediately satisfied
`_wait` and verifies eight service calls. A mutation to one call fails at
`actual wait selects the tested bounded eight-poll schedule`. It also proves
third-call refusal stops the batch immediately. Both native pins pass this binding.
Evidence: `.cache/session-017/stall/clock-actual.log`, `clock-one-poll.log`,
`clock-head.log`, and terminal integration receipts under `.cache/tests/`.

## Review and validation

The first fresh adversarial pass finds two witness defects: identical payloads
cannot identify the transport recipient, and source close events at frame three
cannot precede frame-four initiation. Destination UUID selection and a strict
source event bound repair them. Collision and impossible-order controls cover
both findings. The new closure tests also reject missing events, wrong endpoints,
late closed-channel sends, failed healthy service, absent relay and incomplete
confirmation. Pressure and physical closure cannot substitute for one another.

A second fresh pass covers all six attack surfaces and verifies present/absent
engine removal on both pins. It independently passes the integration category.
It verifies the final source-bound receipt against current sources and recommends
proceeding with no actionable findings. A separate curator verifies the evidence
and requests two documentation attribution/scope corrections; both are applied.
The focused scheduling reviewer also finds the invented successful-wait boundary.
The implementation agent repairs its ordering and reruns both integration pins
and the complete unit target. The testing skill now records both readiness/yield
ordering and incoming-queue measurement across every active delivery boundary.
The new two-frame boundary control fails against the old ordering and passes
the repair; it requires actual staged packets during a successful wait. The
reviewer accepts the corrected gameplay and final-confirmation ordering with
no remaining findings across the six attack surfaces.
The rerun exposes one further model boundary: final confirmation must not run
after failed gameplay. An aborted-wait control fails before the gate and passes
after it. Fresh review accepts the final gate with no additional findings.

Local controls pass: 28 Node cases, 56 reference Python cases (three intentional
skips), 52 oracle controls and 99 harness controls. Source lint checks 217 files
at maximum 180 columns. Editor and formatter limits remain 180.
Final integration receipts pass three cases through both repeat layers:
`.cache/tests/session-017-integration-terminal-4.3.json` (197.964 seconds total)
and `session-017-integration-terminal-4.7.2.json` (178.138 seconds total).
Each fresh process remains under its unchanged 120-second watchdog.
The final `make test-godot` target passes 178 unit cases through both repeat
layers on 4.7.2 in 117.098 seconds total, with no engine errors.
Receipt: `.cache/tests/session-017-unit-terminal-4.7.2.json`.
Independent code, adversarial, scheduling and retrospective reviews have no
remaining findings. Retro: `findings-acted`.
The 4.3 physical room has passed 2/4/8 peers with corrected confirmation,
exactly the affected pair on relay, healthy direct links and clean teardown.
The final source-bound receipt passes all 16 engine/label runs, including physical
2/4/8 rooms, selected/default pressure, clean/fault rooms and intended rejection
controls. Receipt: `.cache/reference/results/session-017-physical-live/signalfish-webrtc.json`.
SHA-256: `fe5e03e22ccfc39ccc0780dbda9153aa24779ceb6b599ac1703aea2755cd5b0e`.
Physical rooms observe maximum coordinator backlog six packets, relay sends in
both directions, at least 31 actual rollback loads per peer, and minimum confirmed
frame 38 or 39. All channels/connections close without engine errors.
Current-head CI and final review/delivery remain gates.

## Remaining scope and delivery

#75 remains open for relay congestion, sustained asymmetric pressure and the
remaining live acceptance. #38 retains ICE restoration, SDK replacement/replans,
browser suspension/resume and server restart. #39 retains Firefox, WebKit,
mixed browsers and sustained release workloads. #77 remains the unrelated latest
CLI publication-delay follow-up; initial main Devcontainer CI is already green.

Current-head CI, complete feedback/thread/annotation scans after green and
immediately before merge, guarded squash merge, local main synchronization and
merge-triggered main CI remain required. Final delivery evidence belongs on the
session PR and #78, including exact heads, workflow runs and feedback dispositions.
