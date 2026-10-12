# Session 015: Transport fallback

## Objective and starting evidence

Continue GOAL.md within two hours, repairing main delivery while advancing
user-facing transport recovery in [S4](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38).
Start: 2026-10-12 00:32 UTC. Aggregate all work in
[PR #74](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/pull/74).

The clean starting branch is `session-014-main-transport-repair`, head
`81ddb85be0dfc0860293ddec9f539ea10b34e9ff`. Authenticated, paginated reads
find no open PRs before creating #74. Main remains
`0bb9a0fcb2c83170cc54ed8b09b2d4cb2d88cb7d`; its Reference Baseline run
`38178672790` failed. Session 014 records the actual slow-service FIFO
reproduction and carried-forward repair. This session preserves that work.

## Carried-forward repair verification

Fresh independent review reads the full committed diff against main, inspects
all six adversarial surfaces, and finds no defects or weakened acceptance.
The unchanged state codec and malformed-packet policy are explicitly outside
this repair diff. All 26 Node browser controls pass.

Both pinned native engines pass the production eight-peer regression through
both fresh-process and in-process repeat layers. Each repeat records 5,484
assertions. Commands:

```sh
python3 scripts/run_godot_tests.py \
  --godot .cache/reference/editors/4.3/Godot_v4.3-stable_linux.arm64 \
  --suite res://tests/unit/test_webrtc_mesh_backlog.gd --timeout 120 \
  --results .cache/tests/session-015-backlog-4.3.json
python3 scripts/run_godot_tests.py \
  --godot .cache/reference/editors/4.7.2/Godot_v4.7.2-stable_linux.arm64 \
  --suite res://tests/unit/test_webrtc_mesh_backlog.gd --timeout 120 \
  --results .cache/tests/session-015-backlog-4.7.2.json
node --test scripts/reference/browser/*.test.cjs
make test-reference test-oracle lint-llm test-llm
```

Reference controls pass 45 cases with three expected skips; oracle controls
pass 52 cases; harness self-tests pass 99 cases. Source widths pass at 180.
An initial shorthand suite selection correctly fails with zero selected cases;
the documented resource path above corrects the invocation.

The authenticated post-push backstop inventories every feedback surface and
annotation for the initial PR head. MCP reports zero review threads. No
actionable feedback exists at that snapshot; CI is still running. This is
neither a post-green scan nor a completed delivery claim.

## User-facing implementation

`FortressSignalFishFallback` owns bounded batches for one frozen peer session.
It selects relay per unready destination, preserves each destination's FIFO,
and restores ready direct delivery after accepted relay output drains.
Authenticated overlap uses the existing protocol decoder and duplicate policy.
Healthy peers retain service at the minimum routing budget. SDK identity,
room, incarnation and mesh lifetime changes remain fenced.

The [integration guide](../docs/signalfish-fallback.md) explains queue ownership,
injected clocks, shared handshake tokens and explicit peer/SDK polling.
Changelog, README, contracts and PLAN distinguish this implemented coordinator
from live mixed-browser acceptance. The latter has a detailed follow-up:
[issue #75](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75).
S4/S5 stay open for browser recovery, SDK replans and suspension.

The pinned SDK's `send_game_data_binary` and `_guard_session_send` validate
connection/authentication and negotiated binary mode without a topology gate.
The pinned server's `handle_game_data_binary_with_lifecycle` validates current
source, room, size and relay budgets before broadcast. This source audit supports
standby relay under mesh plans; it is not a live mixed-path browser witness.

## Independent review and regression evidence

The actual three-peer test fails with timeout fallback disabled in an isolated
addon copy. It requires corrected confirmed prefixes from original-input replay,
actual rollback while the direct fault remains active, unchanged session/frame
identity, conservative confirmation, overlap and physical resumed direct sends.
Final input repeats the prior sample, making final speculative state independently
canonical without another game tick. Globally confirmed prefixes are also checked.
Evidence: `.cache/tests/fallback-gameplay/`.

Fresh adversarial review finds two defects missed by the initial suites:

- Replacing the direct transport under an unchanged mesh plan can publish retained
  output through relay despite the lower adapter's terminal `WRONG_STATE`.
- A successful direct send can leave an old unavailability timer armed because
  an unsent tail remains queued, causing healthy output to switch to relay.

A separate implementation pass writes both failing cases before repairing them.
Direct lifetime refusal now remains terminal under mesh plans; explicitly accepted
relay plans remain serviceable. The actual successful direct-send prefix clears
the pre-fallback timer; a genuinely refused head can start it again.
No earlier passing coordinator exists before this newly introduced capability.

Before automatic-review repairs, an isolated mutant removes both fixes and fails the
two exact regressions on both pins, twice in process, with exit 1 and no engine
errors. Logs: `.cache/session-015/review-mutants-root/{4.3,4.7.2}.{stdout,stderr}`.
Current production passes them. A second fresh review inspects all six attack
surfaces and the full candidate, executes both fallback suites through the
fail-closed repeated launcher, and finds no defects.

## Verification before automatic-review repairs

Both engine pins pass **174 unit cases and eight determinism cases**, twice in
fresh processes and twice in process, seed 1701. Commands use the same launcher
as above, omit `--suite` for full unit selection, retain `--timeout 120`, and use
`--category determinism` for the deterministic category. Superseded candidate receipts:
`.cache/tests/session-015-{unit,determinism}-{4.3,4.7.2}.json`.

The before/after inventory covers all 81 native addon/test GDScript files.
`.cache/session-015/native-source-bound.json` retains exact inventories and
receipt hashes. Both addon-only package audits pass; all 42 archived members
matched the `aff0195` candidate files. Every runtime script loads without the optional SDK.
Package evidence: `.cache/reference/results/session-015-package-{4.3,4.7.2}/`.

Earlier full-native attempts are stopped when source changes during implementation
or review; their partial output is not acceptance. Initial package archives also
fail a current-source rehash and are superseded by the final audits above.
Changed GDScript passes gdlint. `make lint-source` passes at maximum 180;
editor and formatter settings already use that bound. Whitespace checks pass.

The [retrospective](../.llm/retrospectives/2026-10-12-transport-fallback.md)
extends existing transport guidance for composition fences, demonstrated timer
recovery and minimum-budget fairness, and prunes stale planned-fallback wording.
Harness regeneration, lint and 99 self-tests pass.
An independent curator verifies every source/receipt hash, archive member and
mutation signature. Its one stale relay-setup prerequisite is corrected to allow
standby configuration under an accepted mesh plan.

## Delivery gate

Automatic review of candidate `aff0195f7518119dbd125fce859d1b6f030ff71a`
finds two further boundary defects. Zero/already-due grace transfers fenced
output to relay before terminal refusal; an aggregate receive/send pressure
result arms timers for untried healthy destinations. Both reproduce RED with
grace 0 and 10 on 4.7.2. Runtime now fences before routing and after readiness callbacks,
and Direct reports the actual refused destination for timer attribution.
An actual inbound ACK-pressure test verifies a retained healthy send-budget tail
does not report send refusal. Raw RED/GREEN logs and exact commands are retained
in `.cache/session-015/fallback-review-reproduction.txt` and adjacent logs.
Both pins pass 61 focused transport cases, repeated in process.

A new fresh adversarial reviewer passes all six surfaces. It independently
passes 55 transport cases on both engines twice in process and twice across
fresh processes (9,525 assertions per repetition). Owned-copy probes add 78
assertions per repetition at empty/oversized input, queue/work minima/maxima,
zero/maximum grace, backward clocks and `INT64_MAX` boundaries.
Evidence: `.cache/tests/adversarial-fallback-{4.3,4.7.2}.json` and
`.cache/tests/fallback_boundary_review/boundaries.gd`.

A separate read-only budget probe reproduces the original 32-send/8-receive
stall in all four repetitions. Changing sends to default 8 invalidates that
fixture: it discards batches refused by bounded atomic ownership. Those altered
runs establish neither default liveness nor a production defect; no default
change follows. Composed fallback defaults remain outside this Direct-only
measurement. Exact source inventories, commands and refusal vectors:
`.cache/session-015/default-budget-probe/report.md`.

After all runtime/test changes freeze, both pins pass **177 unit cases and eight
determinism cases**, seed 1701, twice in process and twice across fresh processes.
The same launcher commands use final receipts
`.cache/tests/session-015-final-{unit,determinism}-{4.3,4.7.2}.json`.
All 81 source hashes remain unchanged before/after execution. The final binding
`.cache/session-015/final-native-source-bound.json` has SHA-256
`066619bb000c40219a5068c0670c53f9b94cb6248d3f492ad9def8b148dee385`.
Both final addon audits pass, including optional-SDK-free loading and all 42
archive members matching current files:
`.cache/reference/results/session-015-final-package-{4.3,4.7.2}/`.
Gdlint, source width 180, whitespace, harness regeneration/lint and 99 self-tests
pass. The earlier style-only conditional-call correction is included in this
final source binding; superseded receipts do not establish final acceptance.

All session work continues in PR #74. The original repair head's hosted live
transport jobs pass on both engines, but those checks cannot prove the new
coordinator candidate. Final-head CI, post-green and immediate pre-merge complete
feedback scans, guarded squash merge, local main synchronization and merge-triggered
main CI remain required. Final delivery evidence belongs in the linked issues,
so recording it does not create another unverified source commit.

Retro: findings-acted.
