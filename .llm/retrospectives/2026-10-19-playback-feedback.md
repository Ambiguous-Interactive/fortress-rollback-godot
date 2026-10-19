# Retrospective: 2026-10-19 playback feedback

## Work under review

Replay checksum coverage, spectator playback events and driver duplicate-input work.
New public behavior and source changes trigger this review.
Evidence: deterministic missing-feature controls, native suites, repeatable driver benchmark and fresh adversarial reviews.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Full-checksum fixtures hide absent validation | The checksum-free viewer formerly promised validation; the coverage scene test fails before the change | Add absent/sparse/full coverage and matched-comparison counters; update the browser testing reference |
| Host closure precedes completed delayed playback | The new spectator tests retain the tail after HOST_FINISHED and require actual TERMINATED later | Expose bounded distinct events; document local playback versus network handshake |
| Validated duplicate inputs repeated submissions | Driver's original loop resubmitted every duplicate; seven local samples show duplicate workload p50 18.23 ms before and 6.12 ms after | Submit the existing validated index once per player; retain validation and canonical-state checks |

## Prune ledger

Existing browser guidance already covers paused boundaries and exact terminal state.
Extended that owning reference instead of adding another overlapping skill.
No old contract or evidence was invalidated. Full network admission and upstream parity remain explicit open issue gates.
Benchmark numbers are local evidence, never a portable timing threshold or allocation guarantee.

## Outcome

Retro: findings-acted.
