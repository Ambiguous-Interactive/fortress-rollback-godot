# Retrospective: 2026-10-11 input exchange

## Work Under Review

- Scope: fixed-membership byte sessions, bounded input exchange, fault example,
  upstream session oracle, native/Web probes and addon-only audit.
- Trigger: new subsystem, large change and review repairs.
- Evidence: actual integration diff and local structured receipts. This artifact
  records observed results, not final session delivery or source-oracle approval.
- Fresh curator inspected canonical guidance and evidence without author rationale
  or prior review reports.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Composed bounded queues need public drains and long healthy runs. | technique | `tests/unit/test_peer_session.gd:308`; `session-010-drain-transitions-red-{4.3,4.7.2}.json`: exit 1, packet delivery fails. |
| 2 | Partial publication consumes accepted time even when another link backpressures. | technique | `tests/unit/test_peer_session.gd:225`; `session-010-partial-clock-red-{4.3,4.7.2}.json`: expected clock 100, actual 1. |
| 3 | Active faults require corrected confirmed-prefix comparisons at callback boundaries. | technique | `tests/unit/test_peer_example.gd:94`; active-fault receipts compare 1,646 and 2,848 prefixes over 3,000 ticks on both pins. |
| 4 | Unchanged game frames can still emit meaningful save requests. | technique | `tests/unit/test_session_network_seams.gd:77`; stall-save mutants fail on both pins at the current-state save assertion. |
| 5 | Green assertions alone do not establish a clean native process. | technique | First unit receipts fail with leaked resources; final unit receipts pass 80 cases on both pins. Weak references appear at `tests/unit/test_peer_session.gd:96,287`. |
| 6 | Configuration bounds must permit continuing healthy mesh play, not only initialization. | technique | Source-only three-identity traces stall at window 0 and at window 1/delay 0; `session-010-low-window-red.json` records six accepted unusable configurations. |
| 7 | Shared normalization can erase a mismatch from both oracle sides. | technique | `session-010-p2p-stall-null-live-green.json` rejects the source-only null mutation at operation 4 with an error mismatch. |
| 8 | An integer schema needs lexical validation when a parser erases numeric token types. | technique | Both `session-010-p2p-live-controls-green-{4.3,4.7.2}.json` receipts include integral-float and exponent rejection controls. |
| 9 | A receipt must bind the sources and executables actually used throughout execution. | technique | `scripts/oracle/p2p_launch.py:175,227` captures and rechecks upstream/local inventories and Godot/Rust executable identities. |
| 10 | Packet service order determines the receipt bank published during simultaneous retries. | technique | `addons/fortress_rollback/core/peer_session.gd:132` exposes the combined `receive_and_poll` service boundary; final full source receipts remain pending. |
| 11 | Startup activation must not revoke already published confirmation. | technique | Both `session-010-confirmation-activation-red-{4.3,4.7.2}.json` receipts fail the preservation assertion; corresponding green receipts pass; rollback guidance preserves this invariant. |
| 12 | Oracle callback inputs need complete status validation before mutation; source exceptions need exact occurrence limits. | technique | Both game-status red receipts show accepted invalid statuses and mutated state; initial-save scope tests fail on duplicate or later saves before repair. |
| 13 | Source-only profile exploration must not weaken the default executable contract. | technique | `oracle-profile-regression/before.json` accepts windows 0/1 by default; `after.json` rejects them in all three programs while six explicit source audits repeat their original observations. |
| 14 | A source stall projection must preserve mismatches outside successful unchanged steps. | technique | `oracle-profile-regression/before.json` accepts a fabricated poll stall; `after.json` rejects operation 0 with an error mismatch; `scripts/oracle/p2p_contract.py:207` narrows projection. |
| 15 | Substituting expected scenario values for decoded packet fields can make an observer approve corrupted wire bytes. | technique | Eight `session-010-wire-{players,session_id,sender_id,connection_id}-red-{4.3,4.7.2}.json` receipts incorrectly pass encoded-field mutations; final receipts reject all four fields. |

Test receipt paths above are under `.cache/tests/`; profile regression evidence
is under `.cache/session-010/`. The confirmed-prefix rollback
mutant first fails at frame 5, byte 24, on both engine pins. This establishes
sensitivity during active faults rather than only after recovery.

Additional inspected evidence:

- `.cache/reference/results/ownership.json`: native and exported Web match
  across 48 cases on both pins, including intended alias failure and positive runs.
- `.cache/reference/results/package-session010-{4.3,4.7.2}/package-audit.json`:
  passed, 30 addon files, exit 0. The clean project runs real byte delivery.
- `.cache/tests/session-010-unit-{4.3,4.7.2}.json`: first-pass resource leak.
- `.cache/tests/session-010-unit-final-{4.3,4.7.2}.json`: clean earlier unit receipts.
- `.cache/tests/session-010-unit-accepted-{4.3,4.7.2}.json`: 82 cases,
  93,064 assertions per run, two fresh-process runs, passed on both pins.
- `.cache/tests/session-010-determinism-accepted-{4.3,4.7.2}.json`: eight
  cases, 520 assertions per run, passed on both pins.
- `.cache/reference/results/session-010-package-accepted-{4.3,4.7.2}/package-audit.json`:
  passed with 30 addon files on both pins.
- `.cache/reference/results/session-010-core-accepted-{4.3,4.7.2}/receipt.json`:
  passed, 42 cases on both pins.
- `.cache/reference/results/session-010-handshake-accepted-{4.3,4.7.2}/receipt.json`:
  passed, 26 cases on both pins.
- `.cache/reference/results/session-010-p2p-wire-{4.3,4.7.2}/receipt.json`:
  passed and complete, 26 cases, 35 persistent process controls, 8,394 operations
  and 7,653 semantic packets per pin. Every case repeats equally in fresh
  processes; executable/source identities remained unchanged.
- Final P2P receipt source inventories match current file hashes on both pins.
- `.cache/reference/results/p3-adversarial-wire-final/` retains 24 independent
  comparison logs and eight encoded-field controls. Binding mutations emit the
  intended outgoing-codec error; player-count mutation preserves its decoded value.
- Fresh oracle wire review reported no findings. Runtime exploratory checks
  used temporary scripts and tool-history output, not persisted acceptance
  receipts. Their results supplement the structured 82-case and 48-case gates.

## Actions Taken

| # | Action | Canonical home | Verification |
| --- | --- | --- | --- |
| 1–2 | Retain queue drains, long runs and partial-clock guidance. | [networking transport](../skills/networking-transport/SKILL.md) | Intended-boundary mutants fail on both pins; final unit receipts pass. |
| 3–4 | Retain active corrected-prefix and stalled-request guidance. | [testing](../skills/testing/SKILL.md) | Active-fault receipts and rollback/stall mutants on both pins. |
| 5 | Apply weak-reference callback graph guidance. | [GDScript style](../skills/gdscript-style/SKILL.md) | Canonical guidance at lines 51–52; first and final native unit receipts. |
| 6 | Preserve the accepted-minimum progress requirement; reject unusable mesh profiles. | [networking transport](../skills/networking-transport/SKILL.md) | Source-only traces, low-window red/green receipts and accepted unit suites on both pins. |
| 7–8 | Preserve independent nullable and integer schema validation; repair oracle boundaries. | [testing](../skills/testing/SKILL.md) | Source-only null control and standalone lexical controls on both pins. |
| 9 | Apply lexical-token validation and captured/rechecked source/tool identity guidance. | [testing](../skills/testing/SKILL.md) | Canonical guidance at lines 154–156; launcher checks and live controls. |
| 10 | Apply actual service-boundary receipt-status guidance. | [networking transport](../skills/networking-transport/SKILL.md) | Canonical guidance at lines 82–83; public combined service operation. |
| 11 | Apply nonrevocable confirmation-policy activation guidance. | [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) | Canonical guidance at lines 28–30; both-pin activation red/green receipts. |
| 12 | Validate full callback status before mutation and narrow the source-only initial-save projection. | [testing](../skills/testing/SKILL.md) | Both-pin game-status controls; initial-save scope red/green logs; 39 oracle tests. |
| 13–14 | Preserve standalone profile bounds and exact source projection boundaries. | [testing](../skills/testing/SKILL.md) | Profile regression before/after receipts, six repeated source audits and 40 oracle tests. |
| 15 | Apply decoded-field preservation and encoded-byte observer controls. | [testing](../skills/testing/SKILL.md) | Canonical guidance at lines 138–139; eight red receipts and both-pin final process controls. |
| — | Replace obsolete blanket P2P wording with byte-session scope. | [context](../context.md) | Native/Web ownership and clean-addon receipts support the narrower capability claim. |

## Prune Ledger

- Searched existing skills, knowledge and retrospectives before routing lessons.
  Transport and testing already own these procedures; no new skill is justified.
- Fixed at source: context no longer says all P2P work remains planned.
  Real transports and browser release support remain open gates.
- Retained existing intermediate-prefix guidance. Active-fault checks refine it
  with callback timing and per-peer work accounting.
- Retained nullable/schema and verified-source guidance. Follow-up repairs
  strengthen their actual boundaries; no parallel oracle-specific skill is needed.
- Service-order and confirmation lessons belong with existing transport timer
  and post-transition guidance and rollback confirmation policy. Callback validation and projection occurrence
  limits belong with existing testing schema and exact-position guidance.
- No independent fact or research note is needed; these are reusable procedures.
- Wire-observer repairs reinforce existing independent schema validation.
  Scenario metadata must not replace observation; no new oracle skill is needed.
- Owning agent removed a dangling CHANGELOG word and corrected stale probe
  receipt scope strings after curator review.
- Verify-on-touch: inspected actual receipt results and failure localization.
  `make llm-index` and `make lint-llm` passed; `make test-llm` passed 99 tests.

## Outcome

- State: `findings-acted`.
- Follow-up source-oracle process controls passed 27 controls on both pins;
  the latest repair suite passed 40 tests. Accepted full unit and determinism
  suites, addon-only audits, 42 core and 26 handshake source cases pass on both
  pins. Refreshed native/Web probes pass 48 cases in all four matrices.
- Final full 26 P2P source gates passed on both pins under
  `session-010-p2p-wire-{4.3,4.7.2}` with all 35 persistent controls. Earlier
  failed attempts remain repair evidence rather than final acceptance.
- Fresh runtime and final oracle reviews reported no findings. Structured
  acceptance rests on the final receipts above; temporary exploratory output
  is supplementary evidence.
- Accepted unit suites include low-window progress checks on both pins.
  Source-only two-identity windows 0/1 progress; a
  three-identity window 1/delay 2 trace reaches frame 4, confirmation 4.
- Current-head CI, feedback scan, merge and main CI remain session delivery gates.
