# Retrospective: 2026-10-17 delay agreement and suggestion

## Work under review

Session 029 makes peers agree on input limits while connecting (#108, #111) and adds a measured
input-delay suggestion (#109). The [session log](../../progress/session-029-delay-agreement-and-suggestion.md)
owns commands, red/green results and review evidence.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| #108 was one instance of a wider class: per-peer limits that bound what a peer sends, with no handshake agreement. | A sweep found `max_input_frames` checked on receive. Review found the same for `max_packet_bytes`. Both rows fail before their fixes. | Fixed all three in one wire version. Added the agree-or-exchange rule to the [networking skill](../skills/networking-transport/SKILL.md). |
| Batching every wire change into the unreleased version 2 avoided a second version bump. | #111 was first filed as a follow-up, then fixed in the same session. | Prefer finishing a wire-class sweep before a layout version ships. |
| The first suggestion HUD offered stale values forever, and a raise cannot be undone. | Review repro: a spike to 400 ms RTT left "12 (R applies)" after RTT recovered. | The example expires suggestions after 600 frames, with a boundary test. The guide says suggestions can go out of date. |
| Browser probes hard-coded the version 1 input header, and their unit tests built version 1 packets, so the tests stayed green. | Review of the #111 change. `make test-reference` passed before the fix. | `scripts/reference/wire.py` reads `VERSION` from the codec. Probes and tests use it, and the version mutation row uses `VERSION + 1`. |
| Golden digests changed with the layout. | An independent Python script reproduced both the old and the new SignalFish digest. | Keep recomputing goldens outside Godot, never by copying Godot output. |

## Prune ledger

The integration guide's statement that the handshake does not compare capacities is replaced.
The CHANGELOG `set_input_delay` entry no longer qualifies peers by equal `queue_capacity`.

## Outcome

- State: `findings-acted`.
- Follow-ups: none new; #46 stays open for its remaining validation rows.
