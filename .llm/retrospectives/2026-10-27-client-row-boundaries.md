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

## Postmerge incident

Main job 122393721262 was cancelled at its 30-minute limit after startup consumed
11m01s. Candidate job 122373118271 had passed the same verification in 20m14s,
with only 31 seconds of browser/OS setup. The combined observed phases need
31m15s before cleanup; a green warm candidate did not qualify that cold budget.
The follow-up raises the outer ownership job limit to 45 minutes, preserving
every inner watchdog, matrix partition, case, repeat and assertion. The testing
infrastructure guidance now includes cold setup in the outer job budget.
This postmerge failure requires a separate repair PR; the session PR is already
merged. Main completion remains unproven until the repair's merge CI passes.

## Verification continuation: package acquisition

The renewed verification found three jobs still installing dependencies after
30 minutes. The ownership job then reached its 45-minute limit without starting
verification. Its completed log records repeated Azure repository-index retries.
The prior log also measured 17.7 MB in 9m35s at 30.8 kB/s. The outer budget repair
covered the original measured startup but could not resolve a stalled mirror.

Runner provisioning uses a prioritized mirror file. The next repair removes only
the Azure preference before APT in all four installing job families, preserving
the existing HTTPS alternatives and source authentication. Actual CLI fixtures
cover unchanged source/keyring bytes, retained mirror metadata and permissions,
idempotence, rejection without mutation, comments and lookalike hostnames.
The testing guidance now requires localizing acquisition before further budget changes.

## Final outcome

State: `findings-acted`.

Broader replay/source and spectator/live acceptance remain in #45, #47 and #131.
The new driver case advances #40's existing equivalence requirement; it does not
close its remaining prerequisite and allocation-sensitive gates.
