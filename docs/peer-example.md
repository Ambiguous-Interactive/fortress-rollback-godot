# Two peer sessions with packet faults

Open `examples/peer/peer.tscn` in Godot 4.3 or later and run the scene (F6), or:

```sh
godot --path . examples/peer/peer.tscn
```

Two independent sessions simulate the same arena. Each owns one local player
and predicts the other player. Their transport routes actual encoded handshake,
input and ACK bytes in one process. This example does not connect computers.
The shipped addon and this scene require no Rust or development oracle.

| Control | Action |
| --- | --- |
| WASD | Move player 1 |
| Arrow keys | Move player 2 |
| L | Toggle dropping every seventh packet |
| T | Toggle latency between 3 and 12 physics ticks |
| O | Toggle packet reordering |
| Space | Block outgoing packets; press again before timeout to recover |
| X | Change one peer's game rules to demonstrate a desync |
| 1 / 2 | Raise peer 1's or peer 2's input delay by one frame |
| R | Reset sessions, snapshots, packets and counters |

![Two byte sessions with active packet faults](peer-example.png)

The left arena shows peer 1's corrected state; the right shows peer 2's.
The displayed frame and confirmation frontier can differ during prediction.
ACK is the newest local input acknowledged by the other endpoint. Pending
counts retained unacknowledged frames. Restores count successful snapshot loads;
stalls count physics ticks blocked by prediction or network backpressure.
The timing line shows RTT, frame advantage, interruption and the latest event.
Press Space briefly to observe interruption and resumed progress. A block lasting
over two seconds terminates the fixed-membership sessions. Press X to create a
real game checksum mismatch; the event identifies its saved frame. Press R to
start new sessions after a timeout or desync.

The transport holds at most 256 packets and drops new packets when full.
Each physics tick injects exactly 16667 microseconds into protocol timers;
latency and reordering use that clock. Simulation advances in whole frames
and never reads clocks, keyboard state or transport settings. A sample already
submitted for a stalled frame remains fixed until that frame advances; new
keyboard state applies to the next sample. The two-frame input delay provides
neutral startup frames. Press 1 or 2 to raise one peer's delay mid-match; the delay line shows it,
and both arenas keep agreeing because the added frames reach the other peer as ordinary input.

The example reuses the offline integer simulation, complete snapshots and
presentation ledger. It draws reversible pulses from corrected state after
successful steps. Reset preserves the selected latency/loss/reorder settings
and releases any active packet block.

The headless suite `tests/unit/test_peer_example.gd` exercises actual loss,
reordering, a prediction stall, partition healing, full canonical state
agreement, reset, invalid controls and scene loading. Real WebRTC transport,
connection discovery and membership repair remain separate work.
`tests/unit/test_peer_example_lifecycle.gd` exercises visible interruption,
short-partition recovery, terminal long partitions, restart and real game desync.
