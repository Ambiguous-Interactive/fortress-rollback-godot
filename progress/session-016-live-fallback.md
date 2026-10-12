# Session 016: Live mixed-path pressure recovery

## Objective and starting state

Advance GOAL.md with user-facing recovery evidence for
[#75](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75),
within two hours. Start: 2026-10-12 03:00:16 UTC.

The worktree starts clean on `main` at
`b887500294f4120344b8bf69ef2d37322088f986`. Authenticated issue and PR reads
find no open PR or draft to carry forward. All three current-main workflows
are complete and successful: Harness `38192048847`, Devcontainer `38192048822`,
Reference `38192048824`. The previous delivery made progress: #74 merged the
fallback coordinator and repaired main; this session addresses its unverified
real mixed-path boundary rather than repeating that delivery work.

## Contract and implementation

The existing exported witness now configures the production coordinator with
the same frozen membership, PeerSession, direct adapter and raw MessagePack relay.
Actual Chromium channels and a pinned local SignalFish server carry all bytes.
One source-zero outgoing channel reports injected send pressure during frames
4–15. Other links retain direct service; restoration uses the same physical
channel and rollback session. This does not simulate a physical ICE close.

Default work budgets are eight sends/eight receives; selected budgets are
32/32. Both use eight routes per coordinator poll and 50 ms fallback/restoration
grace. Refused drained batches remain caller-owned; the peer is not polled again
until that retained batch transfers. No production addon algorithm changes.

The witness compares 38 corrected canonical prefixes per peer against original
samples, requires rollback loads and monotonic frame/confirmation history, and
keeps the existing synchronized first prediction and physical teardown gates.
It independently validates a captured frame-two INPUT's header, body, session,
sender, player slot and samples. Exact bytes must occur in physical early direct
send, the recipient's early direct receipt, and later addressed relay receipt.
Physical binary counts bound addressed receipt counts. Diagnostic inventories,
owned queues and physical socket buffers have separate limits.

Disabling fallback leaves both peers stalled in the pressure interval and must
fail the actual gameplay inactivity watchdog. Structured watchdog observations
must match captured room frames and an expired gameplay deadline. Snapshot
corruption and incompatible-channel controls remain mandatory.

## Review findings and red-green evidence

Fresh review one reproduces acceptance of zero physical binary receipts and
receipts assigned only to the sending peer. It also identifies enqueue-only
overlap evidence. Two rejection mutations fail RED before the repair; physical
counts and exact original direct/remote relay packet correlation now reject them.

Fresh review two reproduces acceptance of a one-byte overlap and watchdog
suffixes `not-json` or an unrelated final-confirmation state. Nine targeted
mutations fail RED before repair. Full captured-input validation and parsed,
reconciled watchdog diagnostics now reject them. The earlier real correlated
packets and disabled-control observations independently satisfy the new checks.

These are newly introduced witness defects; no earlier passing mixed witness
exists before this session. Their regressions and meaningful live fallback-disabled
control supply negative evidence without claiming a historical production regression.
Fresh review three finds an unchecked connection-incarnation header. Two mutation
controls fail RED before repair; the validator now requires source zero's exact
initial incarnation. The final live attempt then exposes a genuine watchdog timer
firing at elapsed 20252.029343 ms against deadline 20252.224792 ms,
0.195449 ms early. A deterministic timer test fails
RED before the callback rechecks monotonic time and rearms; integer-ceiling delays
avoid fractional truncation. Existing tests with frozen clocks are rewritten to
advance to actual expiry. All 27 browser controls now pass. A fresh review and
final source-bound live run remain delivery gates.

Fresh review four finds two remaining negative-control false passes: bare stall
errors omit timing evidence, and inconsistent current evaluations/attempts are
ignored. A separate agent reproduces 23 Python assertion failures and one Node failure
RED before repair, then passes 13 probe tests and all 27 browser tests.
Both genuine rejection paths now emit structured evidence; every observation
field and named-peer completion must reconcile with the actual expired deadline. The source-bound
matrix before those repairs passes all 14 runs; its receipt remains historical
until the repaired candidate completes a fresh run. Fresh review five finds accepted samples beyond expiry, impossible round times
and two simultaneous rejected completions. Eight rejection mutations fail RED before the separate repair agent fixes the
observer's actual ordering: accepted samples precede their expiry, no-pending
round time equals the single captured clock, and only the named rejecting
completion can remain unaccepted. Fourteen probe controls, 23 watchdog controls and all 27 browser controls pass.
The sixth fresh adversarial review completes with no actionable findings and
covers all six required attack surfaces. It runs 27 Node and 14 Python controls
read-only. Recommendation: pass because the reviewed watchdog rejects expired
completions before accepting their progress. Earlier findings are repaired;
the final source-bound matrix passes as recorded below.

## Commands and candidate evidence

```sh
python3 scripts/reference/signalfish_webrtc_probe.py \
  --server .cache/reference/results/session-013-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/session-013-server-build/build-receipt.json \
  --output .cache/reference/results/session-016-release-live
PYTHONPATH=scripts/reference python3 -m unittest scripts/reference/test_signalfish_webrtc_probe.py
node --test scripts/reference/browser/*.test.cjs
gdlint scripts/reference/browser/webrtc_mixed.gd \
  scripts/reference/browser/webrtc_setup.gd scripts/reference/signalfish_webrtc_probe.gd
make lint-source test-reference test-oracle llm-index lint-llm test-llm
python3 scripts/run_godot_tests.py --godot godot --timeout 120 \
  --results .cache/tests/session-016-unit-4.7.2.json
```

The pre-final correlated run passes 14 engine/label executions on 4.3 and 4.7.2,
including 2/4/8 peers in clean, packet-fault, selected mixed and default mixed
rooms. Each engine also rejects snapshot corruption, incompatible channels and
disabled fallback at their intended boundaries. Its receipt hash is
`8babd61c810211c42912bc2fa3259822dfa3888b60e0b56e704c042716bbbf22`.
This earlier receipt is superseded for final-source acceptance: the validator
and receipt scope wording changed afterward. Final evidence will be recorded below.

The earlier mixed runs observe at most 11 coordinator packets, four addressed
relay receive packets, 333 physical direct buffered bytes and 4,452 physical
relay buffered bytes. Every mixed room observes physical relay broadcasts,
addressed recipients, corrected prefixes, actual loads and restored direct sends.
These are observations of the bounded local workload, not throughput guarantees.

The optional full native run exceeds the launcher's default 30-second budget
without emitting results. The runner guide and CI specify 120 seconds for the
complete unit category. Repeating with that documented limit passes 177 cases
in each of two fresh processes with identical results on 4.7.2. The default
failure receipt remains `.cache/tests/session-016-default-timeout.json`.

Local checks pass: 27 Node controls, 53 Python reference controls (three intentional
skips), 52 oracle controls, 99 harness controls and changed-file GDScript lint.

Final source-bound acceptance passes all 14 engine/label runs on both pins,
including all 2/4/8-player selected/default mixed rooms and intended rejection
controls. Receipt: `.cache/reference/results/session-016-release-live/signalfish-webrtc.json`.
SHA-256: `cfc38df0ef9b7c08c002fb979f9a7abc81e4b8997d5ba4e175012345ee1dba49`.
The receipt binds executed sources/tools, exports, SDK/server and owned logs.
Observed mixed maxima: 12 coordinator packets, 0 relay pending packets,
4 addressed receive packets, 332 physical direct buffered bytes and
4452 physical relay buffered bytes. Final review is clean and the curator's
requested evidence and canonical lesson fixes are applied.

## Scope and follow-up

#75 remains open for physical outages/restoration, relay congestion, lifecycle
changes and sustained workloads. S4 retains SDK channel replacement, replans,
suspension/resume and server restart; S5 retains Firefox, WebKit, mixed browsers
and release coverage. The [fallback guide](../docs/signalfish-fallback.md), PLAN
and canonical transport guidance distinguish live pressure evidence from these gaps.
No supported release, internet traversal or whole-transport parity is claimed.

Current-head CI, complete feedback/thread/annotation scans after green and
immediately before merge, guarded squash merge, local main synchronization and
merge-triggered main CI remain mandatory. Delivery evidence will be linked in
the task issue after those gates finish.

Retro: findings-acted.
