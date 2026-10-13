# Session 021 — Safe games after server restart

## Scope and starting state

Started 2026-10-13 at 22:00 UTC; target duration is under two hours.
Main starts at `e451322fd3c6a4f5f9fdd2692d8512f8304399bb`, with a clean worktree,
no open PRs, and three successful merge-triggered workflows.
Open dependency PRs are SDK typing stubs (#362) and server dependency/CI updates
(#927/#928/#932). None supplies the caller/transport repairs; verified immutable
SDK/server baselines stay pinned.

[#90](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/90)
requires actual server-process death and explicit fresh-room recovery in the
shipped online game. Socket interruption alone cannot prove this contract.
[#91](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/91)
tracks gameplay defects exposed by the new recovery boundary.

## Repairs and regression evidence

Both byte adapters escalated well-formed foreign session/sender/incarnation
packets into permanent failures and retained their input. They now count and
discard those packets, release owned bytes/tokens, and continue bounded service.
Malformed traffic keeps the previous fatal policy.

The initial eight-case native red receipt is
`.cache/tests/session-021-stale-red.json`. Actual game packets are captured,
re-encoded with each foreign identity, and delivered through both adapters.
Six foreign cases fail; the two malformed cases preserve the fatal policy.
There is no earlier working revision of the new inert-identity contract.

Fresh adversarial review exposes a clock mutation hidden by the first test's
same-time rejection. `PeerSession._receive` consumed `now_us` and serviced
confirmation/controls even after foreign rejection. The later-clock red receipt
`.cache/tests/session-021-clock-red.json` records the exact change from
666680 to 666681 microseconds. The repaired session returns without committing
that clock or servicing confirmation/controls. All eight later-clock cases pass
in `.cache/tests/session-021-clock-green.json`, including unchanged complete
network/endpoint observations and later gameplay confirmation.

The browser red witness captures four actual SDK callbacks before server death,
then invokes them after a fifth game starts. Both new games become failed at
frames 47 and 51, with `Room baseline changed` recovery messages. Evidence is
`.cache/reference/results/session-021-callback-red-run/4.3-online.log`.
Connection revisions now fence callback dispatch through weak owner references.
Current callbacks preserve all supported failure arities; released owners remain
collectable. Native callback tests pass through both repeat layers.

A second cold review identifies the observer's weak Callable targets: replacing
`lobby._callbacks` destroys the old target unless the observer retains it.
The strict four-call browser gate correctly rejects the vacuous zero-call run.
The observer now owns each captured target, and a native test uses the actual
capture command across replacement. Removing just that ownership field in an
isolated project fails the capture assertions; `.cache/tests/session-021-capture-red.log`
retains proof. The repaired four-case receipt is
`.cache/tests/session-021-capture-green.json`.

## Browser process contract

A loopback development controller owns the SignalFish process and records every
intentional stop/start. The witness kills that exact handle with SIGKILL, requires
exit -9, then starts the same hashed binary/configuration on the same port.
Readiness polling checks both the endpoint and the new live handle. Each browser
process record must equal the controller's authoritative event inventory.
Process events also enter the owned server log; receipts hash that log.

The first graceful-termination experiment did not exit within ten seconds.
That failed receipt is retained; it is not a process-restart pass. SIGKILL models
abrupt service death and avoids accepting graceful cleanup as crash evidence.

The fourth game retains real relay sends under injected direct/relay buffer
pressure and holds one complete original INPUT per peer. Its five-second timer
must finish against closed old channels after failure. Both players preserve
the first message and frozen frontier, release queues, and close all physical
channels, ICE connections and signaling sockets before Leave.

The fifth game has new room UUID and rollback identity. Both peers physically
receive and reject one original old-room packet over the new direct channel.
All four captured old SDK callbacks execute per peer and leave fresh state,
readiness, configuration, message and canonical bytes unchanged.
Independent Python replay checks corrected prefixes against sender-owned keyboard
histories throughout all five rooms. Short/expired suspension, signaling socket
outage, physical unreliable-channel policy, actual rollback and restore-corruption
rejection remain required.

## Verification and delivery

The final exported browser command passes both pins:

```sh
python3 scripts/reference/signalfish_webrtc_probe.py --online-example \
  --version 4.3 --version 4.7.2 \
  --server .cache/reference/results/session-013-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/session-013-server-build/build-receipt.json \
  --output .cache/reference/results/session-021-final-filtered-browser
```

Receipt SHA-256: `f302529632b0352820b8721afb51c57fed54338ce9a19e0ee28747429a678813`.
Godot 4.3 makes 1,034 independent canonical comparisons; 4.7.2 makes 1,033.
Both verify five distinct rooms and identities, actual rollback, one physically
received/rejected old INPUT and four actual old caller callback invocations per
peer. Both altered-restore controls reject canonical frame 3. The two process
restarts record SIGKILL exits -9 and fresh live readiness on the same port with
identical binary/configuration hashes. All pre-Leave and final physical
inventories close fully.

Final native receipts pass 216 unit, four integration and eight determinism
cases per engine. Each runs twice in-process and in two fresh processes, and
complete result records match between engines. The 4.3 unit receipt is
`.cache/tests/session-021-final-source-4.3-unit.json`; other final receipts are
`.cache/tests/session-021-reviewed-{4.3,4.7.2}-{unit,integration,determinism}.json`.
All commands use `scripts/run_godot_tests.py`, seed 1701 and a 120-second
per-process watchdog with separately hash-verified editor copies.

Python reference controls pass 69 tests (three pre-existing skips); oracle tool
controls pass 56 tests. Node instrumentation/watchdog controls pass 30 tests.
Harness regeneration/lint and all 99 self-tests pass. `make lint-source` checks
236 sources with zero violations at width 180; editor and formatter widths are
already configured to 180.

The final cold adversarial pass reports no concrete defects after all six
surfaces and independently passes 14 Python, seven Node and 12 native cases.
Earlier findings are fixed and re-reviewed. The fresh retrospective curator
verifies evidence, canonical placement and pruning; the owned process contract
is added to the existing networking skill. Retro: `findings-acted`.

Current-head CI, complete feedback, guarded merge and main results are recorded
in #90/#91 after their terminal outcomes. Superseded native
runs were stopped explicitly; partial receipts are not final evidence.
A concurrent browser bootstrap initially encountered ETXTBSY while native tests
used its cached editor. Final native runs use separate hash-verified executable
copies; browser bootstrap is serialized. This follows existing testing guidance.

Detailed final merge, synchronized-main and merge-triggered CI evidence will be
recorded in #90/#91. Session work stays in one squash-merged PR.

## Remaining roadmap scope

Transparent reconnect, ICE/direct restoration, SDK replans, relay congestion,
WAN/NAT/TURN, Firefox/WebKit and release matrix work remain under #38, #75 and #39.
Server restart never restores an old rollback history. The broader roadmap stays
open; this session advances a verified user-facing restart flow and fixes stale
traffic that could end its fresh game.
