# Retrospective: replay input integrity and the trace window after a rollback

## Work under review

The replay file format moves to version 3 and ends with a digest of the final
frame's input row, so a corrupted last input stops playback with `DESYNC` at
that frame instead of ending in a wrong final state. The canonical diagnostic
trace lowers its frontier when it loads a restored frame, so a rollback that
rewinds past the window keeps recording the frames that follow it. A new
released file format, a new public accessor and a changed trace contract
trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| The trace rejected every frame of the divergence region after a rollback, because its frontier only ever rose | The trace kept its rows above the restored frame erased while the frontier stayed at the old high-water mark, so the window floor stayed above the restored frame. The new `rollback_window` case fails on the pre-fix code with five `trace records the frames that follow a rollback` failures and passes after the fix | Lower the frontier to the restored frame; the window follows the simulation back and keeps its bound |
| A re-opened window that starts at a restored boundary is unusable unless that boundary keeps its state | A fresh-context adversarial review measured the window after a rollback: its first row had no canonical state, so the trace reader and the online validator rejected the whole window. The session never re-saves the restored frame, so the trace has to receive the restored bytes | The session hands the restored bytes and checksum to the trace, the restored boundary stays restorable, and the new case fails on the pre-fix code with 21 `the restored boundary keeps its canonical state` failures |
| A machine-local cache file can block a commit | The source-width linter reads every untracked file that git does not ignore, and `.cache/` held a feedback scan whose long lines failed the pre-commit hook twice | Ignore the whole `.cache/` tree, which the workspace contract already calls machine-local |
| The last recorded input row had no integrity anchor, because each frame's state checksum covers the state *before* that frame's input | A recording of N frames protects input rows 0..N-2 through the following frame's checksum; row N-1 has no successor. The new `protects_final_input` case corrupts the final row of a real recording and expects `DESYNC` at that frame | Add the trailing digest and verify it against the row the player applies, before the game callback runs |
| A replay format version is a promise to the files people already downloaded | Version 2 shipped without the digest; version 1 never shipped. A migrated file would otherwise replay without its integrity anchor | Version 3 refuses version 1 and version 2 files with `UNSUPPORTED_VERSION`, and the guide states the rule |
| The digest must be computed the same way by the writer, the independent packer and the oracle corpus | The golden fixture, the Python packer, the oracle corpus and the online download parser each build the digest independently; a mismatch in any of them fails the golden equality check or the corpus comparison | Use the first 16 bytes of the row's SHA-256 in all four, with `HashingContext` in GDScript and `hashlib` in Python |
| The upstream replay session owns the input history and stores no digest | The pinned upstream `Replay` has one optional checksum per frame and no trailing field, so a Godot-only anchor cannot be claimed as parity | Document the anchor as a Godot-side integrity extension in the oracle contract and the integration guide |
| The upstream corpus cannot compare the anchor | The corpus corrupts checksum bytes, and the upstream side consumes the original rows; an input-row corruption has no upstream counterpart | Keep the corpus on upstream-owned behaviour and state the limitation in `docs/oracle-replay.md` |

## Actions and pruning

The replay format facts live in `docs/integration.md` and `docs/oracle-replay.md`
rather than in a new file. No existing knowledge entry became false, so nothing
was retired. The per-job CI baseline is checked in as
`docs/experiments/reference-baseline-jobs.md`, so a later change compares
against a table instead of against a single run.

## Outcome

The shipped change closes the last unprotected input row of a recording and
stops the diagnostic trace from losing the divergence region after a rollback.
The browser release matrix, the live mixed-path recovery and the remaining
Reference Baseline job time are untouched by this change; #104, #75 and #148
keep that acceptance with their measured gaps.
