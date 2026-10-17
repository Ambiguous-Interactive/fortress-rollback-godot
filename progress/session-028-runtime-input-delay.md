# Session 028 — Runtime input delay

## Scope and baseline

Started 2026-10-17 at 16:54 UTC with a two-hour limit. Main was clean at
`25a94d94c1c932b1d09b3e270f6c11a5f10a5f9d` with all three main workflows green and no open PRs.

Triage put player-visible work first. #104 (eight-player Firefox CI) is still runner starvation, as
session 027 found. This session delivers the first slice of #46: a player can raise input delay
mid-match. Raising delay trades responsiveness for fewer rollbacks on a worse connection.

## Upstream contract

Pinned `src/input_queue/mod.rs` (`set_frame_delay`) and `src/sessions/p2p_session.rs`
(`set_input_delay`) work like this:

- Before the first input, any delay that fits may be set.
- After it, only increases are allowed. The gap repeats the latest input.
- Decreases return `InputDelayDecreaseUnsupported`. Several local players return
  `InputDelayMidSessionMultiLocalUnsupported`.
- Gap frames go to every remote endpoint as ordinary input.
- Remote capacity is checked before the queue changes.

## Implementation

- `FortressSession.set_input_delay` / `input_delay`: validates the slot and the queue bound
  `delay + max(prediction, check_distance) + 2 <= queue_capacity`. It rejects decreases after the first
  sample with the new `UNSUPPORTED` code. It reuses the queue's atomic repeat-latest gap fill and
  advances the player's receipt.
- `FortressPeerSession.set_input_delay` / `input_delay`: requires a running match and a prior
  step. It refuses several local players and checks every endpoint's pending room
  (`NETWORK_BACKPRESSURE`) before changing anything. Then it submits each added frame to every
  endpoint. If a submit fails anyway, the session terminates with `PROTOCOL_FAILED` rather than let
  peers disagree.
- The checksum lookahead is now set once to `queue_capacity - 2`, the largest
  `max_prediction + delay` a raise can reach. Before, it was `max_prediction + input_delay` from the
  starting config.
- The peer example raises peer 1's or peer 2's delay with **1** / **2** and shows each delay.

## Evidence

`tests/unit/test_input_delay.gd`:

- `validates_changes`: ten ordered rows covering pre-sample raise and lower, remote and missing
  slots, negative and oversized delays, decrease after a sample, an unchanged delay and the largest
  supported delay.
- `repeats_latest_input`: seven matches. They raise at frame zero before input, mid-match, while
  stalled, while a correction is pending, rapidly in a 14-slot wrapping queue, to the largest
  supported delay, and per player in sync-test. An independent model folds samples and changes in
  call order. Each match must report the modelled last scheduled frame and record exactly the
  modelled inputs. Its replay must validate every checksum and reach the live final state.
- `peers_agree_after_changes`: two real peer sessions over the example's lossy, reordering link
  raise delay five times, up to 16. Neither fails nor detects a desync. Both record identical inputs
  for every common frame. A lower delay is refused on every running tick.

Mutation controls on Godot 4.7.2:

| Mutation | Result |
| --- | --- |
| Do not advance the receipt after a gap fill | Fails |
| Do not send the added frames to peers | Fails |
| Keep the old checksum lookahead without a runtime update | Passes: timing sync kept peers within the old slack even at delay 16 |

Because of the third row, the lookahead is now static and bounded instead of a runtime update that
no test exercises.
