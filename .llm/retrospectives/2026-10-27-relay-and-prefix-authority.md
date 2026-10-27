# Retrospective: relay completion and replay prefix authority

## Work Under Review

- Scope: spectator relay cancellation, malformed replay prefix storage and reference-test resource cleanup.
- Trigger: production debugging and evidence-boundary sweep.
- Evidence commands: `make test-reference` (215 pass, nine expected skips), `make test-llm` (160 pass), `make lint-source` (403 files, zero violations).
- Replay red/green receipts: `progress/replay-prefix-storage-red.json` (251 assertion failures), `progress/replay-prefix-final-current.json` and `progress/replay-prefix-final-43.json` (24 cases twice per pin).
- Terminal accessor receipts: `progress/replay-terminal-storage-red.json` (44 assertion failures), `progress/replay-terminal-storage-current.json` and `progress/replay-terminal-storage-43.json` (15 cases twice per pin).
- Relay receipts: `progress/spectator-relay-cancel-red.json`, `progress/spectator-relay-boundary-red.json`, and `progress/spectator-relay-boundary{,43}-green.json` (26 cases twice per pin).
- Cleanup controls: `PYTHONPATH=scripts/reference python3 -W always::ResourceWarning -m unittest test_local_ownership`; `PYTHONPATH=scripts python3 -W always::ResourceWarning -m unittest tests.test_prune_caches.InUseTest.test_the_current_directory_inside_the_candidate_counts_as_in_use`.
- Final harness cleanup evidence: `progress/session-098-harness-final.log`; all six ownership-test temporary directories independently verified absent after suite cleanup.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A facade can reconstruct an obsolete completion heuristic after its owner gains a precise query. | `addons/fortress_rollback/transport/signalfish_spectator_relay.gd:404` accepted generic termination at the END frame; canceled empty/played boundaries returned `OK`. | Require the playback owner's `is_complete()`; exercise cancellation inside acceptance callbacks too. |
| Repairing one validation buffer leaves equivalent fabrication paths in sibling buffers. | `addons/fortress_rollback/core/replay.gd:413` bounded digest trimming but grew short inputs, statuses, flags and checksums. | Apply shrink-only trimming to every backing buffer; test complete and partial storage through export and both playback configuration APIs. |
| Ordinary and terminal checksum reads must share the complete-width contract. | `addons/fortress_rollback/core/replay.gd:327`: fresh review reproduced one-, fifteen- and seventeen-byte terminal checksum returns while export correctly refused those recordings. | Require exactly sixteen bytes and v6 before exposing terminal evidence; test empty and nonempty recordings. |
| A passing contention test can still leak its worker's resource. | `scripts/reference/test_local_ownership.py:49`: the issue #234 command passed while emitting an unclosed `ownership.lock` warning. | Scope the worker claim, assert its release record, and register temporary-directory cleanup. |
| Broader verification can reveal another test-owned resource from the same failure class. | `scripts/tests/test_prune_caches.py:219`: the harness suite and focused live-directory test emitted an unclosed stdout-pipe warning. | Close the subprocess output pipe in its existing cleanup; preserve the actual live-directory assertion. |

## Actions Taken

- Broadened the existing [networking transport](../skills/networking-transport/SKILL.md) prefix rule from digests to every backing buffer.
- Added the completion-authority rule beside the existing relay callback-completion guidance.
- Kept resource cleanup guidance unchanged: the existing context-manager procedure already covers the test defect.
- Used a table-driven replay storage matrix and expanded existing relay cases rather than adding another test subsystem.

## Prune Ledger

- Fixed at source: replaced the overly narrow digest-only prefix rule; retained its partial-storage requirement.
- Considered retirement: older retrospective evidence remains accurate historical context; no duplicate knowledge page added.
- Verified on touch: source widths, generated guidance freshness, harness lint/tests and affected deterministic suites.

## Outcome

- State: `findings-acted`.
- Follow-ups: broader replay/source/platform acceptance remains in #45; spectator live routing and authentication remain in #47 and #131.
