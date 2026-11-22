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
| 1 | The transport-clock delay between the withheld COMMIT and its retry can read below 50 ms because the drop is stamped at the poll after publication while the retry is stamped at send. A fixed observation floor (50 ms or 40 ms) rejects a correct retry when the next poll withholds it late; no per-iteration cap proves a maximum gap. | bug | first 4.3 cell: `commit_delay_us: 48565`; final four cells: 50.0-64.7 ms; OpenAI round 2 named a valid 34 ms reading |
| 2 | The witness must arm every survivor, not a page index. Join order decides which page owns the lowest surviving slot, and the coordinator was page/slot 1 or 0 depending on the browser pair. | design | 4.7.2 Chromium coordinator slot 1; Firefox coordinator slot 0 |
| 3 | A dropped-packet count and a hex-length check are not evidence of a COMMIT retry. The receipt must keep the exact withheld and retried bytes, and the validator must decode those bytes rather than trust separately reported metadata. | review | adversarial round 1: an equal pair of 120 zero bytes passed; the hardened validator rejects it at the header |
| 4 | A proposer can never legitimately populate `commit_ack_peers` (that map is written only for a follower), so accepting the acknowledgement from either list let an impossible field satisfy the receipt. | review | adversarial round 1: moving the follower identity from `acknowledged_peers` to `commit_ack_peers` passed; it is now rejected |
| 5 | A candidate cap of 8 retries was below the protocol's own 4 s / 50 ms window, and the proposer retries a committed operation until every survivor acknowledges with no 4 s cap at all. Any upper bound would reject a correct run whose acknowledgment is repeatedly lost. | design | the final validator requires at least one retry and sets no upper cap |
| 6 | The retry was recorded when the queued packet was scanned, before the poll sent it. A refused head would report a retry that never left, and a later poll could count the same queued packet again. | review | CodeRabbit round 1; the live one-resend cell now counts only after `super.poll` reports the queue position sent |
| 7 | The 40 ms observation floor was described as tolerating one poll sample, but no per-iteration cap proves a maximum publish-to-poll gap; the second OpenAI round named a valid 34 ms reading. | review | OpenAI round 2; the floor is now a positive-delay check |
| 8 | The row's acknowledgement lists were read before the final confirmation wait, which services transport, so an acknowledgement arriving during that wait could be missing. | review | CodeRabbit round 1; the row refreshes both lists after the wait |
| 9 | The packet parser bound the identity fields but not the rest of the fixed COMMIT body, so `witnessed=2`, `chunk_count=65`, nonzero reserved bytes or a negative bound/capacity passed even though the codec rejects them. | review | adversarial round 2; each malformed body control now fails |
| 10 | The follower row was never cross-checked against the proposer's operation, session, roster, coordinator or target fields. | review | adversarial round 2; a follower with another operation/session/roster/target now fails |
| 11 | The proposer's declared coordinator was never required to equal its own slot, so a receipt could name a packet sender that was not the coordinator. | review | OpenAI round 3; the coordinator-slot mutation now fails a `commit_packet` rebuilt with the same wrong coordinator |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Require only a positive observed delay; keep the exact-byte equality and the sent-accounted retry count as the retry evidence. | `webrtc_drop.py`, `test_webrtc_drop.py` | the four live cells pass; a zero-delay mutation and a `-1` mutation fail; a 1 us receipt passes |
| 2 | Arm every owned transport; drop only `Phase.COMMIT`; record the destination slot from the real queued packet. | `webrtc_setup.gd`, `webrtc_drop.gd` | four live cells cover both coordinator slots |
| 3 | Record exact withheld/retry hex, operation, cut, digest, destination and delay; require byte equality and the follower acknowledgement. | `webrtc_setup.gd`, `webrtc_drop.gd`, `webrtc_drop.py` | four live cells; the receipt mutations and spacer controls reject the intended shapes |
| 4 | Decode the captured packet again in the validator and bind header, session, sender, coordinator, operation, target list, cut, value digest and roster digest to the row. | `webrtc_drop.py`, `test_webrtc_drop.py` | a real live packet passes; 120 zero bytes, a changed trailing byte and a changed magic fail |
| 5 | Accept the acknowledgement only from the proposer's `acknowledged_peers` and require `commit_ack_peers` empty; type-check every follower sentinel and the operation comparison. | `webrtc_drop.py`, `test_webrtc_drop.py` | the move-to-impossible-field, follower bool/float and operation-type mutations fail |
| 6 | Remove the retry-count ceiling; require at least one retry and leave the upper bound to the witness deadline. | `webrtc_drop.py` | a one-retry receipt passes; a zero-retry receipt fails |
| 7 | Record retry bytes, count and time only after `super.poll` sent their queue positions; a refused packet stays queued and is counted once on a later successful poll. | `webrtc_setup.gd` | each live delivery cell reports one resend with exact bytes |
| 8 | Replace the observation floor with a positive-delay check and state that the per-poll sample cannot prove the 50 ms interval. | `webrtc_drop.py`, `.llm/knowledge/transport-tooling.md` | zero-delay fails, 1 us passes, live cells pass |
| 9 | Refresh the row's acknowledgement lists after the final confirmation wait. | `webrtc_drop.gd` | the live cell records the follower in `acknowledged_peers` with `commit_ack_peers` empty |
| 10 | Validate the complete fixed COMMIT body: reason/reserved zero, nonnegative bound and capacity, chunk index zero, chunk count at most 64, witnessed zero. | `webrtc_drop.py` | seven malformed-body controls fail; the live 109-byte packet passes |
| 11 | Cross-check the follower's operation, coordinator, generations, session, roster and target digest against the proposer, and type-check the packet's identity fields. | `webrtc_drop.py` | nine follower-identity and type controls fail; the live packet passes |
| 12 | Add a positive high-retry receipt so a future reintroduced cap is red. | `test_webrtc_drop.py` | `commit_resends=1000` validates; zero fails |
| 13 | Require the proposer's coordinator slot to equal its own slot. | `webrtc_drop.py`, `test_webrtc_drop.py` | a rebuilt packet with coordinator 1 beside proposer slot 0 fails |
| 14 | Keep the 8-byte connection ID opaque, as the codec does, and prove a nonzero one passes. | `test_webrtc_drop.py` | an all-`7f` connection ID validates; the header's real reserved byte stays pinned by the magic |

## Prune Ledger

- Retired: the claim that a dropped COMMIT count alone witnesses a retry. The
  row now binds the phase identity and exact bytes, and the validator decodes
  the captured packet instead of trusting the metadata beside it.
- Retired: accepting the proposer acknowledgement from either list. Only
  `acknowledged_peers` can exist on a proposer.
- Retired: counting a retry when it was scanned. A queued packet counts only
  after the poll reports its queue position sent.
- Retired: every observation floor above zero. A per-poll clock sample cannot
  prove the 50 ms interval; a positive delay rejects a same-poll duplicate.
- Verify-on-touch: `make gate`, `make test-reference`, the live
  `peer-drop-commit` label on both pins and browsers, `make lint-source`.
- No new abstraction: the commit control is one bounded filter in the existing
  `DropDirect` test transport, and the validator reuses the existing row and
  identity helpers.

## Outcome

- State: `findings-acted`
- Follow-ups: #166 keeps the remaining boundary schedules; #188 keeps the
  unequal-frontier and missing-history tail.
