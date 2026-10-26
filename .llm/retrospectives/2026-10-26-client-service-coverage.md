# Retrospective: 2026-10-26 client service and coverage

## Work Under Review

- Scope: driver completion allocation, selected-state replay coverage and spectator service ownership.
- Trigger: new public replay observation and a reproduced callback reentry defect.
- Evidence: issue #228, focused native regressions, alternating driver benchmarks and fresh independent reviews.

## Findings

| Finding | Evidence | Durable action |
| --- | --- | --- |
| An inner BUSY result cannot undo outer service mutations. | `examples/spectator/demo.gd`: recursive tick consumed time and staged input before viewer failure; the `service_busy` case reproduces it. | Extend the existing composed-operation ownership guidance. |
| Lifetime checksum totals do not describe the displayed state. | `tests/unit/test_replay_final_coverage.gd`: advancing, sparse checksums, restored cache-only boundaries and open SAVE work require different selected-state claims. | Extend existing replay coverage guidance rather than introducing another skill. |
| A case-name filter can silently provide much narrower coverage than a suite selection. | The initial driver filter selected four matching cases; explicit selections exercised 32. The replay filename filter was invalid coverage and was stopped. | Clarify launcher help and testing guidance; inspect the actual selected inventory. |
| Removing deterministic work does not imply a timing gain on every engine. | `docs/experiments/session-hot-path-performance.md`: alternating controls improve 4.7.2 about 3–4 percent, while 4.3 results are mixed. | Preserve the existing measurement discipline and report both results. |

## Actions Taken

- Updated [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) at the existing ownership and replay sections.
- Updated [testing](../skills/testing/SKILL.md) and launcher help to distinguish suite paths from case names.
- Added all three new regression cases to the existing exact native/browser inventory.
- Preserved public status ownership and post-notification reads while removing one redundant completion snapshot.
- Recorded benchmark bounds in the existing experiment report; added no new performance framework.

## Prune Ledger

- Searched the existing skills first; extended their established sections and created no overlapping skill.
- Retained existing terminal-state coverage; selected-state coverage adds a separate observation rather than replacing it.
- No stale source claim was retired without replacement evidence.
- Workspace prune dry run reports 1.06 GB of old reclaimable caches; no deletion was needed.
- Progress and raw measurements remain machine-local. Shared behavior and measurement limits live in tracked docs.

## Outcome

- State: `findings-acted`.
- Follow-ups: broad #40/#43 performance and API acceptance, #45 source/platform parity, and #47/#131 live spectator acceptance remain open.
