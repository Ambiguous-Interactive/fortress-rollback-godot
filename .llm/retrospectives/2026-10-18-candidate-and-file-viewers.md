# Retrospective: Candidate packages and file viewers

## Work under review

New addon candidate builder, diagnostic file viewer and bounded replay navigation.
The session advances A5, A3 and X1; full release qualification remains open.
New capabilities and adversarial-review repairs trigger this retrospective.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Successful clean imports do not prove a complete package. | Fresh reviewer removed all transport scripts; the original audit still passed with 61 rather than 81 entries. | Require the explicit runtime script inventory; reject missing families and unknown development scripts before archive creation. |
| A navigation receipt's name does not prove its direction. | The first browser witness sought from completion to 12, then to 6; both moves were backward. | Exercise completion to 6, then 6 to 12; compare both canonical states with independent sender-input histories. |
| Exact dictionaries alone do not enforce numeric types. | Five negative controls accepted integral floats or a boolean in nested failure positions before repair. | Check exact integer types, derive every control frontier, and retain rejection mutations. |
| Seeking can stop before validating its selected state. | A corrupted input at frame7 followed by seek8 produced a mismatching checksum, Paused status and enabled Play. Boundary regression failed before repair. | Compare the selected saved boundary on seek completion, immediate targets and cancellation; latch errors without advancing that input. |
| An offline viewer action can abandon a connected game. | Automatic review found the new Inspect button stayed enabled in connected lobby, playing and failed states; three regression assertions failed. | Retain its button and apply the same connected-room disable rule as Watch replay. |
| Platform-specific I/O can silently change shared assertion records. | CI native/Web comparison differed only in the new scene test: native executed nine assertions, Web seven. | Exercise corresponding import/read-failure paths on each platform and assert their shared contracts outside the platform branch. |
| A final canonical boundary may need no further input. | Full browser output completed, then the Python state oracle indexed beyond exact-length sender history. A trimmed-history test reproduced the failure. | Bound the final frame by actual history and append one unused sentinel for the oracle's post-boundary calculation. |
| Shared helper extraction affects copied-tool controls. | Full reference tests found that argument-rejection fixtures omitted the new package builder dependency. | Update their copied-script inventory; existing infrastructure guidance already covers the procedure. |

The archive and browser lessons extend the existing testing evidence references,
without adding a competing skill. Package builder tests demonstrate the original
failures and repaired refusal. Focused browser validator tests pass after the
frontier and integer repairs. Fresh independent reviews check each repair.
Final source-bound browser and shipping evidence is recorded in the local session
log and linked task issues after execution.

## Prune ledger

No stored claim became obsolete. The infrastructure and browser evidence references
were extended in place after searching existing skills, knowledge and retrospectives.
No duplicate fact entry or new skill was needed.

## Outcome

Retro: findings-acted
