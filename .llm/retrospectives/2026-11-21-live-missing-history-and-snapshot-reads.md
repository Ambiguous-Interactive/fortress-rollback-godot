# Retrospective: 2026-11-21 live missing history and snapshot reads

## Work Under Review

- Scope: the exported `peer-drop-missing` witness, the transcript-send
  withholding seam, the snapshot-reader copy path, the read benchmark workload,
  and the eight-player partition-heal differential case.
- Trigger: large change (19 files, about 470 insertions) plus new capability
  evidence and review corrections.
- Evidence base: PR #427 Gate, four browser cells (Chromium and Firefox on
  4.3/4.7.2), the pinned `partition_heal_mesh8` receipt, `make hot-path-probes`
  on both pins, and the local `make gate`.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Withholding an entire INPUT packet that overlaps frames 4-6 also removes adjacent frames and every local slot in that packet. The first live run reported `frames: [2,3,4,5,6]` with two overlaps even though the label claimed frames 4-6. | fact | PR #427 review comments and the `session212-peer-drop-missing` report; final report is `frames: [4,5,6], overlaps: 0, unsupported: 0` |
| 2 | Counting dropped packets is not evidence of a frame-specific fault. The validator must compare the exact withheld frame set and the departing slot, not a packet count. | fact | `scripts/reference/browser/webrtc_drop.py` rejects `dropped != 3` or `frames != [4,5,6]`; four browser cells pass those checks |
| 3 | A read benchmark that always times production before the control can bias the control through the production run's retained destinations. Alternating the order and keeping each raw pair removes that order artifact. | technique | `scripts/benchmark_session_hot_path.gd::_snapshot_read` records `order` and 15 raw pairs; final p50 59.0 -> 4.4 us on 4.7.2 and 112.7 -> 11.7 us on 4.3 |
| 4 | A new lifecycle corpus case is silent unless it is also registered in `CORPUS_REQUIREMENTS`; without the entry, `p2p_validate --corpus-case` reports an unknown case and skips its observations and controls. | fact | CodeRabbit review on PR #427; `partition_heal_mesh8` now records 58 interruptions, 2 resumes and 96 repair loads plus its three controls |
| 5 | The missing-history witness cannot use the ordinary per-frame `last_received_frame` wait: the withheld link is intentionally behind, so the wait deadlocks until the departure timeout. The witness skips that wait only for the missing-history label. | fact | First `peer-drop-missing` run timed out at frame 4/5; after the labeled skip the same schedule reaches certification in 12 seconds |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Split overlapping input packets into kept segments, re-encode each segment, and withhold only the departing page's single local slot; reject unsupported packets. | `scripts/reference/browser/webrtc_setup.gd` | four browser cells report `frames: [4,5,6], overlaps: 0, unsupported: 0` |
| 2 | Require the exact frame set, dropped count, departing slot and a donor interval through frame six. | `scripts/reference/browser/webrtc_drop.py` | `test_webrtc_drop` positive and negative fixtures |
| 3 | Alternate the read benchmark order and publish the raw pairs beside the percentiles. | `scripts/benchmark_session_hot_path.gd`, `docs/experiments/session-hot-path-performance.md` | `make hot-path-probes` on 4.3 and 4.7.2 |
| 4 | Register the eight-player heal's observations and controls. | `scripts/oracle/p2p_lifecycle.py` | `partition_heal_mesh8` passed twice per side against `d124c890` |
| 5 | Document the live witness, exact-frame validator and the remaining live faults. | `docs/peer-lifecycle.md`, `docs/reference/jobs.md` | `make lint-llm` |

## Prune Ledger

- Retired / merged / fixed at source: corrected the stale "live witness does
  not exercise missing-history transfer" paragraph in `docs/peer-lifecycle.md`
  and updated the direct-job label/room counts instead of adding a second
  status page.
- Verify-on-touch: `make gate`, `make test-oracle`, `make lint-source`, the
  four browser cells, and both pinned `partition_heal_mesh8` runs were re-run
  for this change.

## Outcome

- State: `findings-acted`
- Follow-ups: the broader pinned-source comparison and other live missing-history
  cases remain in #188; room departure, process death, rollback-time departure,
  foreign proposals and a second live departure remain in #166; the wider
  allocation, sustained-memory and release-matrix gates remain in #43.
