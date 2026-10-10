# Retrospective: 2026-10-10 stateful oracle and iteration

## Work under review

Added the shared version 2 Rust/Godot stateful game without removing version 1
coverage. Improved verified source reuse, focused local runs and bounded oracle
concurrency. Audited baseline packaging and prerequisite evidence. Updated CI
actions and pinned the runner image. Large change and external evidence trigger.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Rewriting identical adapter sources forces Cargo compilation | Queue build 2.84 seconds before, 0.12 seconds after; timestamp regression fails at base | Compare complete verified trees before reuse; retain timestamps only for exact matches |
| Scenario startup dominates independent oracle cases | Same 42-case receipts: serial 61.081 seconds, four workers 26.472 seconds | Bound independent workers; retain every process/repetition and corpus receipt order |
| Cargo trusts already-unpacked registry sources | Independent reviewer injected `compile_error!` into cfg-if while preserving checksum metadata; compiler reached injected source | Cache crate archives and index only; exclude registry/src and use new keys |
| Invalid worker options preserved a successful old receipt | Actual subprocess table for 0, 9, -1, bad and 1.5 fails before cleanup repair | Invalidate receipt before option validation; retain subprocess regression |
| Format-1 mutation widths failed early for format 2 | Automatic review plus real pre-fix schema-rejection log | Derive mutation state widths per version and require intended diagnostic/consumption boundary |
| A new format replaced the old persistent control witness | Final launcher coverage audit found last-witness selection | Keep one witness and execute full process controls for each supported version |
| Local stateful toy tests did not establish shared reference-game parity | Version 2 initially rejected by strict scenario validator | Add explicit version and independent history prefixes; preserve prior version serialization |
| Package inventory trusted names and skipped special entries | Independent reviewer reproduced empty notices, FIFO omission and a symlinked addon root | Validate attribution bytes and reject unsupported entry types before startup; eight controls |
| Baseline guidance claimed no addon existed | Addon-only package audit found missing runtime notices | Ship attribution with addon, execute in clean projects, correct original task evidence boundaries |

Durable iteration and cache procedures live in
[testing](../skills/testing/SKILL.md). Exact commands and measurements live in
[session evidence](../../progress/session-007-stateful-oracle-and-iteration.md).

## Prune ledger

Removed stale claims that no addon exists and that determinism suites are empty.
Kept P2P/formal/release limits explicit. Updated existing testing guidance instead
of creating another performance skill. No knowledge entries duplicate this scope.

## Verification and outcome

Harness regeneration, lint and self-tests accompany these changes. Actual native
engines, cross-language oracle cases and package candidates supply runtime evidence.
Fresh-context reviews found and repaired the cache and stale-receipt defects.
Remote timing and delivery evidence are recorded by the session PR and issues.

State: findings-acted.
Follow-ups: P2P/full-recovery, semantic audit and supported release remain their
original linked roadmap issues; local sync-test evidence does not close them.
