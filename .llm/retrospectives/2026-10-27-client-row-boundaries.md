# Retrospective: client row boundaries

## Work under review

Scoped progress for driver equivalence (#40), replay reads (#45) and spectator
closure (#47). The trigger was root-cause debugging at public client boundaries.
Evidence includes the new `recording_accessors`, `gapped_end` and
`partial_publication` cases, baseline failures, both-pin focused runs and fresh
adversarial reviews. Local receipts live in `progress/session-099-*`.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Configuration validation cannot protect direct reads from caller-edited recordings. | `replay.gd` inputs/digest reads previously sliced declared rows; missing status and metadata storage caused runtime indexing errors. | Extend existing transport guidance to require dimension and complete-row checks at public reads. |
| Clean input closure can abandon accepted history while reporting normal completion. | The old `finish_host()` accepted `[0, 2]`, completed after row 0 and made row 1 unavailable. Six new gap/start controls fail on that behavior. | Extend rollback guidance: known gaps remain recoverable until the complete accepted tail can close. |
| Delivery faults do not establish publication-pressure equivalence. | The prior driver/expert parity workload used pending capacity 128; the new capacity-one three-peer case reaches actual partial acceptance. | Add the missing scenario to the existing parity suite and exported inventory, with a skipped-ADVANCE control and independent canonical history. |

## Actions and verification

Production changes refuse malformed replay reads and gapped clean closure before
publishing invalid results. Tests preserve complete replay prefixes, verify exact
retry traffic and consume the full spectator tail. No format change or broader
source/browser release claim is made.

The spectator review ran clean and independently passed 37 cases. Replay
configuration/prefix suites pass nine cases twice per engine; spectator
session/policy suites pass 19 cases twice per engine. Aggregate gates and final
review evidence are recorded in the session log and linked issue updates.

## Prune ledger

Updated the existing transport and rollback skills rather than creating an
overlapping skill or knowledge entry. Replaced the deliberate spectator
truncation expectation with a recoverable-gap contract. No other stale rule was
identified. Regenerate guidance and run its linters/self-tests before delivery.
Cache pruning is report-only; this session creates no whole-worktree copies.

## Outcome

State: `findings-acted`.

Broader replay/source and spectator/live acceptance remain in #45, #47 and #131.
The new driver case advances #40's existing equivalence requirement; it does not
close its remaining prerequisite and allocation-sensitive gates.
