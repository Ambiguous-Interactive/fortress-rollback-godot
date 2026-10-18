# Retrospective: Local Inputs and Playback Checkpoints

## Work under review

Session 037 advances driver retries (#40), replay navigation (#45), and spectator
byte delivery (#47). New callback and packet boundaries require independent review.
Evidence includes deterministic red/green fixtures, focused engine-pin tests,
full native tests, explicit packaging inventory and native/Web ownership checks.
Exact commands and receipts are in local `progress/session-037-client-playback.md`.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Rejecting a malformed sample tail after committing its prefix strands corrected retries. | `tests/unit/test_driver.gd` input_validation reproduces retained frame0 and INPUT_ALREADY_SUBMITTED on the old implementation. | Shared non-mutating metadata preflight; added the prefix/retry invariant to rollback-fundamentals. |
| Checking each earlier duplicate introduces quadratic work despite a bounded player roster. | Fresh review quoted the nested loop; 100,000 valid identical samples imply 4,999,950,000 comparisons. | Reusable eight-slot indices provide one lookup per sample; a 10,000-duplicate control preserves accepted behavior. |
| Restore success requires more than a matching checksum. | `test_replay_checkpoints.gd` restore_failures covers unread/expired/underflowed readers, wrong canonical state, invalid return types and reentry. | Existing callback and snapshot guidance already owns this rule; checkpoints validate consumption and saved bytes. |
| A byte adapter can mutate time before its core rejects callback reentry. | Removing the spectator poll mutation guard fails the intended batch/callback tests; guarded control passes. | Shared mutation guard precedes clock commits; existing networking guidance already covers callback boundaries. |
| Isolated reviewers must not overwrite full-suite receipts. | One review used default latest.json; full native runs independently used explicit session-specific result paths. | Existing infrastructure guidance already requires unique result paths; retained it without duplicate instructions. |

## Prune ledger

Searched the rollback, networking, testing and GDScript skills and knowledge store.
Updated the existing rollback skill rather than adding a parallel skill.
Removed obsolete documentation that backward replay navigation always restarts.
Updated spectator documentation to distinguish shipped byte delivery/expiry from
remaining SignalFish startup, identity/routing, live relay and upstream evidence.
No historical claim was promoted to new acceptance. The approximately 15-file
retrospective budget was considered; the existing foundations archive retains
older consolidated evidence, and this artifact records distinct current boundaries.

## Verification and limits

Source widths remain 180. Regenerate and validate the harness with
`make llm-index && make lint-llm && make test-llm`.
First-time replay seeks remain bounded sequential work. Checkpoint caching is
optional and does not change replay v2. Spectator identities do not authenticate
packets; applications still own authentication, full configuration and retries.
Broader #40/#45/#47 acceptance remains in those issues.

Outcome: `findings-acted`.
