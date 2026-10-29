# Retrospective: gameplay safety

## Work under review

Driver/manual equivalence through runtime delay changes (#40), malformed replay
prefix/checksum safety (#45), and deferred spectator publication clocks (#47).
Debugging and new acceptance evidence triggered this review.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A refusal before service must precede clock acceptance. | `signalfish_spectator_host.gd` moved `_last_poll` after host BUSY preflight; the paired `active_requests` case rejects a newer refused timestamp without blocking the original retry. | Kept the existing callback/preflight guidance; no duplicate rule added. |
| Shrink-only copying still needs dimension validation before arithmetic. | `test_replay_prefix.gd` exercises negative, zero and maximum metadata; baseline emits negative-resize errors. | Expanded the existing replay validation sentence in the transport skill to name prefix arithmetic and checksum reads. |
| Static delay parity cannot establish scheduling equivalence across a refused raise. | `test_driver_peer_parity.gd` adds `runtime_delay`, decoded repeated inputs, canonical boundaries and a skipped-ADVANCE control. | Extended the existing parity suite and exported ownership inventory. |
| A counter baseline must follow preparation when the assertion concerns later work. | Fresh review demonstrated that preparatory recovery already satisfied the original rollback-count check. | Moved the baseline immediately before the accepted raise; both pins still pass 453 assertions per repeated run. |

## Verification

The focused prefix suite passes twice on both pinned engines. The spectator host
suite passes all 16 cases twice on both pins. Fresh replay review completed with
no actionable finding. Full native and exported ownership gates run on the final
runtime snapshot; session delivery records their terminal results.

Evidence logs and receipts stay machine-local under `progress/` and
`.cache/scratch/session-116/`. GitHub issue updates carry the shared scope and
verification summary; the session PR carries the reviewed implementation.

## Prune ledger

Updated the existing replay rule at its canonical source. Existing rollback
preflight guidance already covers clocks and outer side effects; another rule
would duplicate it. No obsolete rule or conflicting behavior was found.
Initial disk report found 0.10 GB reclaimable; no whole-tree copy or new build
target directory was created.

## Outcome

Retro: findings-acted
