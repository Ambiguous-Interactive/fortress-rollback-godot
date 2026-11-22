# Retrospective: 2026-11-22 live lost-donor-history witness

## Work Under Review

- Scope: the exported `peer-drop-missing-lost` witness, its terminal service
  loop and row, the Python validator and its table-driven controls, the
  workflow and runner tables, docs and knowledge.
- Trigger: #188's remaining physical/live missing-history cases. The live
  `peer-drop-missing` label proved a donor transfer and a single-chunk retry,
  but nothing proved that a real match ends when the donor's bytes never
  arrive.
- Evidence base: four live cells (Chromium and Firefox, 4.3 and 4.7.2), the
  positive `peer-drop-missing` regression, the Python reference suites,
  `make gate`, `make lint-source` and two fresh-context adversarial rounds
  plus the automatic reviews.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The retry arm is a packet count, not a window: `arm_history_drop(64)` ran out inside the four-second barrier timeout, the donor then resent chunk zero and the recipient installed and committed. | design | first live run: donor `history_dropped: 64`, `history_resends: 3`, barrier `committed` |
| 2 | The terminal witness must service each survivor's own timeout after the other survivor stops. The ordinary service batch treats direct backpressure and a post-termination peer poll as fatal, so the proposer was stranded while its barrier stayed pending. | bug | second live run: proposer `barrier_pending`, donor `committed`; final custom loop records both rows |
| 3 | A row that writes `canonical_comparisons: 0`, `freeze_frame: -1` and `frozen_value: ""` as constants proves nothing. The validator accepted `prediction_gap: 99`, an unchanged confirmed prefix was never compared, and a freeze that bypassed the event would read as unfrozen. | review | adversarial round 1 findings 1 and 2; first fixture accepted `prediction_gap: 99` |
| 4 | The receipt did not bind the rows to the departed slot, the barrier participants, the coordinator or the target generation/digest. A row for a different target passed as long as role, slot, operation and donor matched. | review | adversarial round 1 finding 4 and CodeRabbit `4656283004`; mutations passed before the fix |
| 5 | `history_dropped >= 1` accepted one dropped chunk of many, and `history_resends == 0` was unreachable while the budget stayed positive. The validator presented both as evidence. | review | adversarial round 1 findings 3 and 6; live donor has one journal chunk, so a single drop and a full round are indistinguishable without a multiple |
| 6 | A confirmation frontier bounded at three is produced by the barrier ceiling, not by the withheld rows. It is a consistency check, not independent withholding evidence. | review | adversarial round 1 finding 8; `confirmation_ceiling()` caps the proposer while the barrier is pending |
| 7 | The live page saw `player_left` during the terminal wind-down because one survivor ended its session before the other published its row. The terminal label must accept that expected membership change without hiding other SDK failures. | bug | `session220-adv-fix`: survivor error `player_left` beside the barrier timeout |
| 8 | The transport poll after a same-iteration timeout returns `WRONG_STATE` because the terminal path already closed the local link; a remote closure returns `PEER_FAILURE`. Both are expected terminal wind-down, not witness failures. | bug | `session220-adv-fix`: `transport_12` and `transport_2`; the fixed loop skips the closed link and accepts the remote failure |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Arm every owned transport with a count beyond every retry round; require two full rounds and record the journal count. | `webrtc_drop.gd`, `webrtc_drop.py` | four live cells report 65-67 drops against one chunk; mutations reject one drop |
| 2 | Service peers directly in the terminal path, tolerate backpressure and terminal remote closure, count sent/received, and observe 250 ms after termination. | `webrtc_drop.gd` | four live cells report `frames_after_terminal: 0` and terminal codes 0 |
| 3 | Read the authoritative frozen frame, compare the pre-cut confirmed prefix with reconstructed inputs and record the real comparison count. | `webrtc_drop.gd` | live rows compare 2-3 frames; mutations reject a changed prefix, a frozen slot and a continuation |
| 4 | Bind both rows to the departed slot, participants, coordinator, generation and digest. | `webrtc_drop.py` | table-driven mutations reject each wrong or missing field |
| 5 | Remove the resend claim from the lost-history validator and docs; keep the runtime counter as diagnostics. | `webrtc_drop.py`, `docs/peer-lifecycle.md` | validator mutations no longer rely on it; docs name two full rounds |
| 6 | Present the confirmation frontier only as an observed status, not withholding evidence. | `docs/peer-lifecycle.md`, `signalfish_webrtc_probe.py` | live rows tie `minimum_confirmed` to `confirmed_prefix`, both checks derived |
| 7 | Ignore only `player_left` during the terminal label. | `signalfish_webrtc_probe.gd` | four live cells green with no `player_left` failure |
| 8 | Skip the local transport after a same-poll termination and accept a remote `PEER_FAILURE`. | `webrtc_drop.gd` | four live cells green; error logs no longer contain transport failures |

## Prune Ledger

- Retired: the claim that the first-chunk drop proves "every donor chunk is
  withheld". The lost-history control withholds the whole window; the positive
  label keeps its single-chunk retry.
- Retired: the claim that a low confirmation frontier proves the withholding.
  The ceiling can cap it; the receipt now binds the failed barrier, the
  repeated drop count, the unfrozen slots and the unchanged confirmed prefix.
- Verify-on-touch: `make test-llm`, `make lint-llm`, `make lint-source`, the
  Python reference suites, and the live `peer-drop-missing-lost` label on both
  pins and both browsers.
- No new abstraction: the terminal loop is a bounded local service loop in the
  existing witness; the validator reuses the existing row and identity
  helpers.

## Outcome

- State: `findings-acted`
- Follow-ups: #188 keeps the pinned-source comparison and the remaining live
  cases; #166 keeps the remaining boundary schedules.
