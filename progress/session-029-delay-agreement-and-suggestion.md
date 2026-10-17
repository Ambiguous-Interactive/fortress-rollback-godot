# Session 029 — Delay agreement and suggestion

## Scope and baseline

Started 2026-10-17 at 21:08 UTC with a two-hour limit. Main was clean at
`ce56930b1b59f2606447a9bc1b7083c106db49d0` with all main workflows green and no open PRs.

Triage put player-visible work first:

- #108: peers with different `queue_capacity` values lost the match when one raised input delay.
- #109: players had to guess a good input delay.

#104 (eight-player Firefox CI) is still runner starvation, as sessions 027 and 028 found.

## Agree input limits during the handshake (#108)

The handshake configuration now carries `queue_capacity` (u32, 2–65536). It is compared with the
Godot-only fields, so the pinned Rust handshake oracle is unchanged. `FortressPeerSession.configure`
refuses a profile whose capacity differs from the session config. The fixed configuration grows from
29 to 33 bytes, and the wire layout is now version 2, so a version 1 peer gets `UNSUPPORTED_VERSION`
instead of a confusing trailing-bytes error.

Evidence:

- `test_handshake.gd` `mismatch` gains a `queue_capacity` row. `test_peer_session.gd` `request_mismatch`
  checks that a remote offering capacity 256 ends as `incompatible: queue_capacity`, and that `configure`
  refuses a mismatched profile.
- Red: with only the agreement and `configure` lines reverted, both rows fail (`precise reason` is
  `missing`, the session stays `synchronizing`). Green with them.
- The golden fixture, codec bounds rows, and the exact-fit packet cap row (119 → 123 bytes, 44 → 48
  frames) follow the new layout. The SignalFish membership digest golden was recomputed by an
  independent Python script; the same script reproduces the old value from the old layout.

### Same failure class: unagreed send caps

A sweep for other per-peer limits found that an endpoint decoded incoming input with its own
`max_input_frames` send cap. A peer with a larger cap had catch-up batches dropped as
`INVALID_PACKET`, and the match stalled. Received batches are now checked against the protocol limit
`MAX_INPUT_FRAMES` (128). Memory stays bounded by `max_packet_bytes` and `max_received_frames`.
The new `capacity` rows fail before the fix (`INVALID_PACKET`, zero frames delivered) and pass after.

### Same failure class: packet size limits (#111)

Review found a third instance. Each peer sized input batches from its own handshake
`max_packet_bytes`, and the receiver dropped larger packets. Packet limits belong to the transport, and
peers may differ, so they are exchanged rather than compared. Synchronization messages now end with
`max_packet_bytes` (u32, 44–1048576). The handshake records the value from the remote's accepted reply,
and the endpoint sends batches that fit the smaller limit. This joins the unreleased version 2 layout.

- The `capacity` packet-cap rows now run both ways: local 127 / remote 65536 and local 65536 / remote
  127. Without the send-side cap, the second case sends 53 frames into a 127-byte receiver and fails.
- `_bounds` rejects advertised limits 0, 43, 1048577 and 2^32−1, and queue capacities 0, 1, 65537 and
  2^32−1, on decode.
- The online example now sets its handshake limit to its 1024-byte transports, and the WebRTC guide says
  to keep the handshake limit no higher than the transport's.

## Suggest an input delay (#109)

`FortressDelayAdvisor` turns the largest peer RTT into frames of one-way latency:
`ceil(rtt_ms * fps / 2000)`, clamped to `max_input_delay`. A raise must hold for 60 consecutive steps,
and the event suggests the smallest target in that window. Suggestions only rise, so nothing flaps and
an ignored value is not repeated. Sessions with several local players, no prior sample, or lifecycle
controls disabled publish none. The event is advisory: RTT comes from the game's clock and never
reaches the simulation, checksums or replays.

The online example shows the suggestion and applies it with **R**. It drops a suggestion after 600
frames, because latency can recover and a raise cannot be undone.

Evidence (`tests/unit/test_input_delay_recommendation.gd`):

- `converts_round_trip`: eight conversion rows, including zero, negative and the largest RTT and fps.
- `suggests_from_scripted_round_trip`: sixteen scripted RTT rows for spikes, dips, the window minimum,
  applied and manual raises, the clamp, the limit, several local players and no prior sample.
- `peers_apply_suggestions`: two real peers on the example link at latency 0 and 12 ticks apply each
  suggestion, stay in agreement, and publish nothing after close.
- A mutation that compares only against the current delay fails the suite.
- `test_online_example.gd` covers applying, dropping a covered suggestion, and expiry at 599 and 601
  frames of age.

## Review

Fresh adversarial reviews ran on each part. Acted on:

- Medium: unagreed `max_packet_bytes` (fixed as #111 above).
- Medium: stale HUD suggestion (expiry), and the guide not saying a refused suggestion should be kept and
  retried (documented).
- Low: missing hostile decode rows, docs that did not list `queue_capacity`, and an unclear R message.

Not changed: an advisory event can end a match on a full event queue, the same as
`wait_recommendation`. At most `max_input_delay` suggestions exist per match, and `inputs_received`
overflows long before it. Rollback depth does not feed the suggestion; RTT alone is enough for the
acceptance criteria.

## Verification

- `make test-godot` (unit, determinism and integration, fresh processes) on Godot 4.7.2.
- `make test-reference`, `make test-oracle`, `make lint-source`, `make lint-llm`.
- The Rust handshake oracle has no local toolchain. CI runs it.

## Retrospective

The [retrospective](../.llm/retrospectives/2026-10-17-delay-agreement.md) adds the agree-or-exchange
rule for per-peer limits to the networking skill.
Retro: findings-acted.
