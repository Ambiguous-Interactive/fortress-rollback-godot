# Spectator Streams, Callback Results and Replay Evidence

## Work under review

The session adds confirmed-input spectator playback through the shared engine,
validates dynamic driver callback results, and compares public replay callbacks
against pinned Rust. New subsystem and regression repairs trigger this review.
Scope includes the spectator example, replay launcher and addon package audit.
Local progress notes describe work; receipts and production tests supply evidence.

## Evidence and findings

| Finding | Evidence | Durable action |
| --- | --- | --- |
| Wrapper-owned bounded storage can escape the base reservation. | `/tmp/spectator-budget-red.json` reports 192 bytes instead of 242 and accepts 241. `test_spectator_session.gd:205` now rejects one byte below the complete reservation and accepts the exact budget. | Add wrapper staging payloads and tags to the existing rollback skill's reservation guidance. |
| An input-wait override can hide terminal shared-engine checks. | `/tmp/spectator-exhaustion-red.json` returns stall code 3 at exhausted frame and request counters. `test_spectator_session.gd:270` now requires terminal code 16 and no game callbacks. | Require terminal checks before recoverable wrapper stalls; test the wrapper with unavailable input. |
| Typed assignment at a dynamic callback boundary can prevent cleanup. | `/tmp/driver-callback-red-receipt.json` records the type error at `driver.gd:108` and a held callback guard. `driver.gd:109` captures `Variant`, then validates the exact result contract. | Extend GDScript style's existing callback validation guidance to cover result types and guard release. |
| Replay callback inventories can differ even without a desync. | `scripts/oracle/replay_launch.py:75` expects Rust saves with validation enabled even when a checksum is absent. Godot saves only for present checksums; `missing-sparse-save` rejects omitted Rust evidence. | Reinforce existing oracle guidance about excluded inventory and explicit product differences; no duplicate rule. |
| Confirmed delivery can precede correction of predicted state. | `test_spectator_session.gd:251` hides affected exported input while correction is pending, then releases it after shared-driver repair. | Existing rollback guidance already owns corrected confirmation boundaries; retain it. |

Native final spectator receipts
`.cache/tests/session036-spectator-final43.json` and
`.cache/tests/session036-spectator-final472.json` pass ten cases with seed 1701,
in-process repetition and fresh-process comparison. Both
`/tmp/driver-final-4.3.json` and `/tmp/driver-final-4.7.2.json` pass.
The earlier progress note's nine-case count predates the added shape coverage.

Replay receipts at
`.cache/reference/results/session037-replay-{4.3,4.7.2}/replay.json`
pass 22 cases per implementation with equal repeated runs, seven negative
controls and four standalone rejection controls. These establish native public
callback replay evidence, with separate Rust/Godot expected inventories.
They do not establish expert replay requests, seek acceleration or network-fault replay.

Both `.cache/reference/packages/session036-{4.3,4.7.2}/package-audit.json`
receipts pass with exit zero and `FORTRESS_ADDON_PACKAGE_OK`. Their smoke covers
addon-only loading, player traffic and one confirmed spectator tick. Full live
spectator routing, late admission and browser networking remain separately gated.

## Clean-end follow-up

A later independent public-API review reproduced a finished stream remaining
RUNNING when callers executed only `recommended_steps()`. Direct advancement
had covered termination while bypassing the documented scheduling contract.

`.cache/tests/session036-clean-end-red.json` confirms four failures: empty stream,
one frame, delayed tail and gapped input. Each advice-driven loop ended with
code OK and lifecycle RUNNING instead of TERMINATED. The regression at
`tests/unit/test_spectator_session.gd:317` also requires the exact contiguous
frame count and no simulation callback for the terminal service call.

`recommended_steps()` now recommends one final service call after clean drain;
`begin_advance()` commits termination from raw stream availability. Both
`.cache/tests/session036-clean-end-green43.json` and
`.cache/tests/session036-clean-end-green472.json` pass all ten spectator cases
and three demo cases. These follow-up receipts supersede the earlier focused
spectator receipts for this lifecycle repair.

Extended the existing wrapper terminal paragraph with the distinct scheduling
lesson: completion work must remain reachable through the caller's public service
loop. No separate lifecycle skill or duplicate general terminal rule was added.

## Shared filesystem fixture incident

CI exposed a diagnostic viewer test race: fresh Godot processes shared the
constant `user://diagnostic-viewer-test.json`. A concurrent process could recreate
or truncate that file between removal and the missing-file assertion.

`.cache/tests/session036-diagnostic-race/results.json` contains controlled
before/after observations on both engine pins. The isolated control passes;
a second writer makes the old test report “Could not open diagnostic JSON.”
instead of the expected missing-file error. Both old race runs exit 1.
With process-owned fixture paths, both race runs exit 0 with twelve assertions.
`tests/unit/test_diagnostic_viewer.gd:170` now checks setup and removal I/O and
preserves equal native/Web assertion counts. Production code is unchanged.

Added the fixture ownership and checked-I/O lesson to the existing
[testing infrastructure reference](../skills/testing/references/infrastructure.md).
Prune check: existing unique result-path guidance covers receipts, while this
incident concerns shared application filesystem fixtures. Both remain necessary;
no additional skill or operational fact duplicates the procedure.

## Curation and verification

Updated existing [GDScript style](../skills/gdscript-style/SKILL.md) and
[rollback fundamentals](../skills/rollback-fundamentals/SKILL.md).
Searched `.llm/` before writing. The
[oracle reference](../skills/testing/references/oracle-validation.md) already
requires validating excluded inventories, and existing rollback guidance fences
pending correction. Those principles needed no second home.

Prune ledger: no authoritative rule was disproved or superseded. Preserved the
static-typing rule and its documented `Variant` exception; clarified the specific
dynamic boundary instead of weakening typing globally. No new skill or operational
fact store was needed. Earlier replay retrospectives remain historical evidence.

`make llm-index`, `make lint-llm`, and `make test-llm` verify these harness edits.
Full runtime delivery checks belong to the session owner; this review does not
substitute for current-head CI or final source-bound receipts.

Retro: findings-acted
