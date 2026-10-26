# Retrospective: client and playback validation

## Work under review

Session 090 addresses reusable snapshot reads (#40), replay configuration refusal (#45),
and retained local match lifetimes (#47). New API work and two debugging incidents trigger this review.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Generic object parameters allow property access to fail before returning an API result. | Replay configuration regression refuses unrelated and matching-shape objects, preserves playback and blocks foreign getters. | Validate the owning configuration script before field access; extend GDScript guidance. |
| Dropping an owner's reference leaves retained sessions and players usable. | Restart controls hold old viewer, driver, stream, host and replay handles across replacement. | Retire prior owned lifetimes; stage replacements and reject active callbacks/batches; extend rollback guidance. |
| Cancellation can hide an executing callback when its public handle is cleared. | Fresh review reproduces stop-replay then reset inside SAVE/ADVANCE callbacks, bypassing the initial restart guard. | A separate evaluator adds retained cancellation ownership and nested callback regressions before re-review. |
| Avoiding a wrapper can move copying from native code into interpreted byte loops. | Five-round reader measurements favor reusable eight-byte fields; 120-byte and 4096-byte copies favor native slices. | Document the tradeoff and retain wide native reads; promise no result wrapper, not zero allocation. |

## Prune ledger

Existing GDScript boundary and rollback lifetime instructions were extended in place.
No new skill duplicates those owners. No old claim was proved obsolete; the existing
callback guards, native copy guidance and broad source/browser qualification limits remain valid.
Machine-local pruning reports approximately 1.04 GB reclaimable; no deletion was required.

## Verification

Pre-change controls reproduce wrong-type replay failure and retained old-session playback.
The new reader capability is absent at baseline; paired existing read controls pass.
Focused reader and replay suites pass on both engine pins; separate fresh reviews find no defects in those scopes.
The initial restart review finds the nested cancellation bypass; its first candidate is superseded by the repair and fresh review.
Final runtime, exported browser and CI evidence belongs in the ignored session progress log and linked PR.
No pending gate is counted as passing here.

## Outcome

Retro: findings-acted
