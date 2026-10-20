# Retrospective: every recorded input row, host scheduling gaps and interrupted-run progress

## Work under review

The replay file format moves to version 4 and gives every frame the digest of
its own input row, so a corrupted row is refused at the frame that owns it
instead of waiting for a later state checksum. The browser witness publishes the
host's service cadence and confirmation waits with the room state, so a starved
host can be told apart from a transport that lost bytes. The scenario runner
reports the case that was executing, so an interrupted ownership run names it.
A changed file format, a new page-state field and a changed runner contract
trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A recorded input row in front of a checksum-less frame had no integrity check | A recording of N frames protects row F through the checksum of the next frame that carries one. The golden fixture itself contains a checksum-less frame and a skipped frame, so the gap is reachable with the shipped tooling. The `protects_input_rows` case records three frames without a retained checksum, corrupts the middle row and expects `DESYNC` at frame 1 | Give every frame its own input digest and verify it against the row the player applies, before the game callback runs |
| The pre-change format silently accepted that corrupted row | The same scenario on format version 3 played back to completion: `playback code 16 failure frame -1 complete true` | The format version 4 run reports `playback code 18 failure frame 1 complete false` |
| Reporting a corrupted row at its own frame moves the failure boundary | The viewer, the checkpoint suite and the speed suite expected the following state checksum to report the failure at frame 8; the per-frame digest reports frame 7, the frame that owns the row | Update the three suites and the documented behavior; the owning frame is the useful boundary |
| A rejected browser run could not name the case that was executing | The ownership watchdog rejected a run before the page printed its inventory, and the browser errors were the only retained evidence | The scenario runner takes an optional progress callable; the exported page publishes the running case and the completed count; the browser runner retains them with the error inventory |
| The runner's progress must not change the suites it observes | The progress callback runs before each case and reports the suite, the case and the number of completed cases | The new `progress` case runs the real runner over a real suite and checks the order and the counts |
| A host that was starved and a transport that lost bytes looked identical | Both local timeouts in #125 and #132 showed a peer that stopped advancing, with no scheduling observation to separate them | The published summary carries the largest turn gap, its nominal tick count, the transport time it spans and the longest submission-to-confirmation wait |
| A published summary can be forged or omitted | The page state is the only source of the observation | The online validator requires the exact field set, non-negative integers, at least one turn and a turn count that matches the gap at the published tick rate |

## Actions and pruning

The replay format facts live in `docs/integration.md` and `docs/oracle-replay.md`
rather than in a new file. The scheduling summary is documented with the online
example, next to the service-batch contract it explains. No existing knowledge
entry became false, so nothing was retired.

## Outcome

Every recorded input row of a recording is now covered by an independent check
that names the frame that owns it, and the format version, migration rule and
golden provenance are stated. The exported witness publishes the host's
scheduling gaps so the local timeouts can be reproduced against a measured
cadence, and an interrupted ownership run names the case it was executing. The
browser release matrix, the live mixed-path recovery and the remaining
Reference Baseline job time are untouched; #104, #75 and #148 keep that
acceptance with their measured gaps.
