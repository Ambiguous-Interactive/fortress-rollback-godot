# Retrospective for 2026-11-24

## Work under review

Run two overlapping native WebRTC replacements in one exported four-player
match. Lose the first Offer for one pair and preserve the other pair's
signaling. Keep confirmation, room membership, and healthy links intact.

## Findings

| Finding | Evidence |
| --- | --- |
| A released queue's length includes deliberately discarded messages. | On the first exported Godot 4.3 Chromium run, both pairs resumed direct play. The witness failed with `2 !== 1` because the flush returned one sent ICE candidate plus one discarded Offer. The socket test counts the single actual send. |
| Missing a replacement alone cannot prove a scoped signaling fault. | Cold review showed that the old timeout branch could name only pair 2–3 even if it had forwarded an Offer or a healthy channel had closed just before the last sample. The control now requires a retry, an exact drop count, zero Offer deliveries on that pair, and progress on the other direct links. |
| Concurrent restoration needs a physical identity per pair. | The witness matches each accepted Offer's ICE credential to its replacement and requires the reciprocal credentials and gameplay counters at both endpoints. Cumulative relay addresses and original channel identities are checked through confirmed-history capture. |
| Open channels can pass a final identity check with flat gameplay counters. | The final-capture control freezes send or receive counters on an original or replacement channel. It reported `Missing expected exception` until the final check started requiring progress in both directions. |

## Actions and pruning

The [transport tooling note](../knowledge/transport-tooling.md) now records the
difference between dequeuing and forwarding signaling. The
[browser qualification guide](../../docs/experiments/upstream-binding.md#playable-web-rooms)
distinguishes input-hold cells from direct-link replacements and documents the
isolated missing-replacement control.

## Outcome

State `findings-acted`. The match uses the same room driver, history comparison,
and teardown for one or two pairs. The controller owns the fault schedule and
pair identities.
