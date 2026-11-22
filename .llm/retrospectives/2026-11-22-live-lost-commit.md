# Retrospective: 2026-11-22 live lost-COMMIT retry

## Work Under Review

- Scope: the `peer-drop-commit` exported-browser label, its send-boundary
  COMMIT control, the survivor row fields, the Python validator and its
  table-driven controls, the workflow/runner/probe tables, docs, CHANGELOG and
  PLAN.
- Trigger: #166's remaining coordinated-drop boundary schedules. The
  deterministic corpus covered a lost COMMIT, but no live room proved the
  irreversible phase survives its first emission being lost.
- Evidence base: four live cells (Chromium and Firefox, 4.3 and 4.7.2), the
  pre-existing `peer-drop` and `peer-drop-missing` regressions, the Python
  reference suites, `make gate`, `make test-reference`, and a fresh-context
  adversarial review plus the automatic reviews.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The transport-clock delay between the withheld COMMIT and its retry can read below 50 ms because the drop is stamped at the poll after publication while the retry is stamped at publication. A validator floor of exactly `RETRY_US` rejects a correct retry. | bug | first 4.3 cell: `commit_delay_us: 48565`; final four cells: 46.4-49.4 ms |
| 2 | The witness must arm every survivor, not a page index. Join order decides which page owns the lowest surviving slot, and the coordinator was page/slot 1 or 0 depending on the browser pair. | design | 4.7.2 Chromium coordinator slot 1; Firefox coordinator slot 0 |
| 3 | A dropped-packet count is not evidence of a COMMIT retry. The receipt must keep the exact withheld and retried bytes, the phase-derived operation/cut/digest, the destination slot, the observation delay and the follower acknowledgement. | review | the validator mutation table rejects a changed retry, an immediate duplicate, wrong identity and a follower-side drop |
| 4 | A candidate cap of 8 retries was below the protocol's own 4 s / 50 ms window. The cap must be derived from the barrier window so a slow runner does not fail a correct retry sequence. | design | `MAX_COMMIT_RETRIES = 80` derived from 4 s / `RETRY_US` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Lower the observed-delay floor to 40 ms with a named constant and a comment that states the sampling allowance. | `webrtc_drop.py` | the 4.3 and Firefox cells pass; a 39,999 us receipt mutation fails |
| 2 | Arm every owned transport; drop only `Phase.COMMIT`; record the destination slot from the real queued packet. | `webrtc_setup.gd`, `webrtc_drop.gd` | four live cells cover both coordinator slots |
| 3 | Record exact withheld/retry hex, operation, cut, digest, destination and delay; require byte equality plus the follower acknowledgement. | `webrtc_setup.gd`, `webrtc_drop.gd`, `webrtc_drop.py` | four live cells; 30 receipt mutations and spacer controls reject the intended shapes |
| 4 | Cap retries at the barrier window's own 80 intervals. | `webrtc_drop.py` | 81-retry mutation fails |

## Prune Ledger

- Retired: the claim that a dropped COMMIT count alone witnesses a retry. The
  row now binds the phase identity and exact bytes.
- Retired: the exact-50 ms observation floor. The protocol interval still
  bounds retry ownership; the witness allows one poll sample.
- Verify-on-touch: `make gate`, `make test-reference`, the live
  `peer-drop-commit` label on both pins and browsers, `make lint-source`.
- No new abstraction: the commit control is one bounded filter in the existing
  `DropDirect` test transport, and the validator reuses the existing row and
  identity helpers.

## Outcome

- State: `findings-acted`
- Follow-ups: #166 keeps the remaining boundary schedules; #188 keeps the
  unequal-frontier and missing-history tail.
