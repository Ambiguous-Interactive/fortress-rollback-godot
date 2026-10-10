# Retrospective: 2026-10-10 runtime oracle

## Work under review

New development-only Rust sync-test oracle, versioned trace validation,
independent GDScript game replay, bounded submitted-history checks and CI.
Triggers: new subsystem, external source audit and adversarial corrections.
Evidence: `make test-oracle`, minimum/current native runtime receipts,
the fresh-context review and pinned upstream `src/lib.rs`.

## Findings

| Finding | Evidence | Durable action |
| --- | --- | --- |
| Final sum equality misses reordered inputs | Adversarial temporal-permutation mutant passed trace and final-state checks | Verify every input/state prefix from submitted histories; preserve the mutant |
| Schema equality hides JSON field types | Embedded `players:2.0` equaled submitted integer 2 in Python | Independently validate embedded artifacts before identity comparison |
| Standalone entry points need their own rejection boundary | Empty Godot trace returned passed with zero operations | Validate full schema before replay; execute real-process empty/unknown-field controls |
| Bootstrap event and transport guidance invented contracts | Pinned `src/lib.rs` enums contradict the former skill lifecycle/events | Correct rollback/networking skills at source; link ADR and runtime evidence |
| Rust tagged unit variants ignored extra fields | Binary malformed-operation experiment before empty struct variants | Preserve real-process unknown-field controls alongside Python schema tests |
| A source-only recovery hypothesis did not reproduce | Missing samples at frame four, distance two, resumed through frame eight successfully | Remove the unverified defect claim; add late missing-input recovery to the runtime corpus |
| Positional mutation selection can target the wrong boundary after reordering | PR review questioned request zero; table covers save-first and load-first batches | Select loads by kind and preserve valid frame/checksum when changing payload |

## Actions and pruning

Updated existing testing guidance with prefix and embedded-artifact verification.
Retired bootstrap event names, fixed-channel promises, the unreleased replay
layout and degraded-mode advice. The reviewed ADR and task-owned protocol gates
replace those claims. No new overlapping skill was added.

Verification: regenerate index/stubs, run harness/source checks and all relevant
tests. The session progress artifact records concrete results and CI delivery.
No production session parity or release coverage is claimed.

## Outcome

State: `findings-acted`.
Follow-ups: V2 P2P/time/delivery vocabulary, actual Godot session differential
execution and post-error upstream observation remain in the linked issues.
