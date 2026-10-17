# Retrospective: 2026-10-17 runtime input delay

## Work under review

Session 028 adds mid-match input-delay raises (#46) to sessions, peer sessions and both playable
peer examples. The [session log](../../progress/session-028-runtime-input-delay.md) owns
commands, mutation results and review evidence.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| The first draft checked queue capacity only locally. Two peers at that limit overflowed each other's queue, and the same failure already existed for a large starting `input_delay`. | Review reproduction: capacity 24 at delay 14 and capacity 128 at delay 118 end with `PROTOCOL_FAILED`. | Added `max_input_delay` for raises and `configure`, and the remote-span rule to the [networking skill](../skills/networking-transport/SKILL.md). |
| Emitting frames outside `step` assumed endpoints matched core receipts. A backpressured step breaks that. | Review reproduction with `max_pending_frames=6`. The `raise after a backpressured step` row fails without catch-up. | Peer raises resume each endpoint from its own `last_submitted_frame`. The skill now states the rule. |
| A runtime checksum-lookahead update survived mutation, so no scenario exercised it. | Mutation M4 passed at delay 6 and at delay 16. | Replaced it with a static bound derived from `max_input_delay`. An untested runtime branch became configuration. |
| The derived delay bound is conservative, and a looser mutation still passes. | A one-sided bound of 110 passes the suite. | Recorded as a limit. The public API cannot construct the worst case. |

## Prune ledger

The integration guide's "runtime input-delay changes are not available" statement is replaced by the
new section and the Rust mapping row. No other guidance became stale.

## Outcome

- State: `findings-acted`.
- Follow-ups: #108 (agree queue capacity in the handshake), #109 (measured delay suggestion); #46 stays open.
