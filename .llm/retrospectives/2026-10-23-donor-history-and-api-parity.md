# Retrospective: donor history and API parity

## Work under review

Session 067 adds bounded missing-history transfer before coordinated peer drop,
external-input expert/driver equivalence and upstream expert replay comparison.
New capability, source investigation and debugging triggered this retrospective.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A candidate can precede its history plan. Treat missing data as pending, with expiry still enforced. | `peer_drop_barrier.gd` follower coverage gate; missing-row regression failed before the wait replaced immediate abort. | Added the ordering invariant to the networking skill. |
| A parity check must observe every claimed output, including empty events. | Fresh review found missing event comparison in `test_driver_external_parity.gd`; each step and recovery now drains and compares events. | Fixed the acceptance probe; retained existing testing guidance instead of duplicating it. |
| Missing rows need complete range installation before a certificate, rather than frozen-value substitution. | Original-main missing-row probe terminates; donor journal repairs it and preserves canonical continuation. | Replaced stale range-transfer exclusions in lifecycle, protocol, supported-feature and plan documentation. |
| Retried plans and donor data can starve each other at capacity one. | Fast and complete-history controls pass, but 50 ms donor service emitted 36 plans and one chunk before timeout; a lost-plan and remote-donor control isolated two more publication paths. | Preserve refused publication turns, yield donor rounds to certificates, and piggyback the final candidate. Add the minimum-capacity/cadence cross to the networking skill. |

| A growing full browser suite outlasted its absolute page deadline. | CI completed all 280 cases at 131.4 seconds and reported a result, but the 120-second page watchdog rejected before saving it. | Apply existing phase-budget guidance: 180 seconds for the page and 240 seconds for its subprocess, with all semantic checks and the 30-minute job bound preserved. |

## Verification

The session log records both pinned-engine runs, the original-main red control,
byte-transport fault tests, independent replay traces and review gates.
Machine-local evidence remains under `progress/` and `.cache/tests/`.
The shipping gate requires current-head PR CI, complete feedback coverage and
merge-triggered main CI before completion.

## Prune ledger

Updated the existing networking skill after searching its history/ordering rules.
No new skill or duplicate knowledge entry was needed. Removed obsolete claims
that missing-history transfer only sends a frozen value. Full source-wire parity
and expanded live fault acceptance remain tracked in issues 188, 48 and 166.

## Outcome

Retro: findings-acted.
