# Session 020 — Online terminal connection cleanup

## Scope and contract

Started 2026-10-13 at 20:07 UTC; target session duration is under two hours.
Main starts at `805fd2f89d7eb3e8c82f6d37f4ccd3523f6dcfbb`, with a clean worktree,
no open PRs, and all three merge-triggered workflows successful.
The open dependency PR scan finds only SDK typing stubs and server dependency/CI
updates (#362 in the SDK; #927/#928/#932 in the server). None supplies the caller
cleanup/order repair; the verified immutable SDK/server baselines remain pinned.

[#88](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/88)
tracks a user-facing online failure: local terminal errors detach the game and
WebRTC mesh but retain an open SignalFish socket and stop its polling. The server
can keep old room membership until the user presses Leave. Successful SDK returns
after synchronous failure signals can also overwrite the first failure or publish
readiness. The contract is terminal gameplay, first-reason preservation, physical
connection closure before Leave, and an explicit fresh-room restart.

The caller keeps SDK nodes alive during callbacks and polls the client to complete
its close handshake after failure. It performs no subsequent mesh or game service.
Every callback-capable setup operation checks the terminal state before continuing.
Editors and formatter configuration use width 180; the devcontainer ruler is
corrected from 100 to match that existing source contract.

## Verification in progress

Native red cases reproduce the missing close and overwritten readiness on the
original caller. The exported browser witness retains its original peer-departure,
short-suspension, overdue-expiry, full canonical-input, rollback and corrupted-load
gates. It adds signaling socket inventories, cleanup before Leave, actual outage
of both TLS proxy socket pairs and a fresh fourth room with a new session identity.

Native original-source regression output records 78 failed assertions across
three cases; the repaired first candidate passes all 18 online cases on both
engine pins. Logs are `.cache/tests/session-020-lobby-{red,4.3,4.7.2}.log`.
There is no earlier working pre-regression implementation of the new cleanup
contract: this repairs the behavior present since the online example was added.

The original-source browser red run is isolated in a detached temporary worktree
at `805fd2f`. Its diagnostic receipt remains `passed:false` under
`.cache/reference/results/session-020-online-red-diagnostic-retry`. Both expired
peers freeze at frames 101/102 with gaps 2.521/2.520 seconds. Each peer reports
six closed channels, four closed RTC/ICE connections, and two signaling sockets
with only one closed. This localizes the new gate's rejection to the still-open
second-room signaling socket. Old lobby SHA-256:
`d093a0c4cc60287c49e5a6a48f61a576a51939c2aa14836bff30593ef56d601c`.

The first fresh adversarial review identifies one additional production path:
an SDK binary send fails synchronously while relay/fallback polling is busy.
Their guarded detach operations preserve pending queues until the active call
unwinds. The caller needs a subsequent cleanup retry before Leave. Independent
evaluation and a real-adapter regression address that finding before final gates.
The real-adapter red retains two coordinator packets, one relay send, one accepted
addressed incoming packet and the SDK binary listener. The cleanup latch retries
detach after the outer operation unwinds; all four cleanup assertions then pass
on both pins. `.cache/tests/session-020-cleanup-{red,4.3,4.7.2}.log` retains proof.
The injected SignalFish/live probe callers were also swept: they latch failure
during callbacks and perform cleanup after their active operations finish.

The first repaired 4.3 browser execution completes all four rooms and closes all
connections, but `.cache/reference/results/session-020-online-green` remains a
failed receipt. One expired peer receives the other peer's SDK departure before
its protocol clock runs. Its observed protocol time stays at the prior timestamp,
so the existing strict elapsed-time validator rejects the run. Production ordering
is repaired; the validator is retained. The native order regression records stale
time 1,650,033 µs at exact 3,650,033 µs and overdue 3,650,034 µs resumes, including
SDK service before overdue expiry. `.cache/tests/session-020-clock-red.log`
retains that failure. Protocol deadline service now precedes SDK callbacks in
running games, without receiving gameplay packets or advancing simulation.

In-progress full native runs were explicitly interrupted before these source
changes; their partial receipts are not accepted as final evidence. A cold review
started on the earlier candidate is superseded by a fresh pass after source freeze.

## First full browser pass

```sh
python3 scripts/reference/signalfish_webrtc_probe.py --online-example \
  --version 4.3 --version 4.7.2 \
  --server .cache/reference/results/session-013-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/session-013-server-build/build-receipt.json \
  --output .cache/reference/results/session-020-online-final
```

Both selected exports pass. Receipt SHA-256:
`cfc9a60217348a372402a6a9398c3e6e0aa3b9ebbce0ebf4d0da5540573c785d`.
Each engine makes 826 independently calculated original-input canonical comparisons
across four distinct room/session identities. Short pauses measure 772–776 ms;
expired pauses measure 2.517–2.526 seconds. Every protocol gap exactly equals
the corresponding host gap, and overdue frames remain frozen.

Both actual signaling proxy socket pairs are destroyed, with zero remaining
pairs and a real refused upgrade attempt. Both sessions stay terminal across
750 ms of outage and 250 ms after reopening signaling. Before Leave, each peer
reports all nine cumulative channels, six RTC/ICE connections and three signaling
sockets closed. The fourth room plays successfully with a fresh identity. Final
teardown closes twelve channels, eight RTC/ICE connections and four sockets per
peer. Both corrupted-restore controls reject canonical frame 3.

This pass precedes the final observer initializer repair. A subsequent cold
review checks Playwright's public initialization contract: separate init-script
registration does not establish execution order. Reversed dependent observers
reproduce `TypeError: Cannot set properties of undefined (setting 'websockets')`.
The online caller registers one ordered observer script, with runtime options
passed separately as data. A persisted Node control executes the actual
initializer and verifies native socket/RTC/channel tracking.
The self-contained original four-registration control is retained at
`.cache/tests/session-020-init-red.cjs`; its actual pinned Chromium rejection is
`.cache/tests/session-020-init-red.log`. Current initializer/watchdog controls
are retained in `.cache/tests/session-020-browser-controls.log` (30 passed).

## Final local gates and review

The same browser command with output
`.cache/reference/results/session-020-online-reviewed-final` passes both engines
after the observer repair. Final receipt SHA-256:
`b5751f98cad7848bd3c22bd71ae00fc9b591f7917956e06c4a3974c037dbe4e8`.
Godot 4.3 makes 812 canonical comparisons; 4.7.2 makes 813. Each retains four
distinct rooms and identities, actual rollback and both altered-load rejection
at canonical frame 3. The outage stops both peers at frame 104 on 4.3 and frame
101 on 4.7.2. All pre-Leave and final physical resource inventories close fully.
Short gaps are 771–777 ms; expired gaps are 2.522–2.526 seconds, with exact
host/protocol gap equality and no overdue frame advance.

All six final native receipts pass: 204 unit, four integration and eight
determinism cases per engine. Each runs twice in-process and in two fresh
processes; all complete result records are equal between the two engines.
Receipts/logs are `.cache/tests/session-020-final-{4.3,4.7.2}-{unit,integration,determinism}.{json,log}`.
Each launcher uses `scripts/run_godot_tests.py`, seed 1701, and the existing
120-second per-process full-suite watchdog.

Harness checks pass 99 self-tests; reference/oracle tool controls pass 65
(three pre-existing skips) and 56 tests. The focused browser validator passes
eight controls, and Node instrumentation/watchdog controls pass all 30 cases.
`make lint-source` checks 231 source files with no violations at width 180.

The final cold adversarial review reports no FIXABLE or INVESTIGATE findings
after attacking all six surfaces. It independently validates both final browser
records, the six terminal native receipts, and 585 executed source/package files
against the final receipt with zero hash mismatches. Its recommendation is
`proceed because no concrete defect found`. Earlier findings are repaired and
re-reviewed; an interrupted earlier pass is not counted as a clean review.

Retrospective curation verifies the evidence, canonical placement and pruning
judgment. The transport skill captures physical cleanup, callback safety and
deadline ordering; the testing skill captures dependent observer initialization.
Retro: `findings-acted`.

Current-head CI, complete paginated feedback, guarded squash merge, local
synchronization and merge-triggered main verification are recorded in #88.

## Remaining scope

Actual server-process restart, transparent reconnect, ICE/direct restoration,
SDK replans, real relay congestion and the full release browser matrix remain
under #38, #75 and #39. A socket outage is not server-restart evidence. The broader
roadmap remains open; this session advances the playable caller's failure contract.
