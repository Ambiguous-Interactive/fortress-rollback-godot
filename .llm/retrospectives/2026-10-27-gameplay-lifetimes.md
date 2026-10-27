# Retrospective: gameplay lifetimes and historical recovery

## Work under review

The session repairs callback transport teardown and obsolete spectator retransmissions,
extends grouped-target Rust/Godot history comparison, and requires a valid replay
above 8 KiB through the exported online bridge. Trigger: debugging and review findings.

## Findings and actions

| Finding | Evidence | Durable action |
| --- | --- | --- |
| Latching callback failure leaves owned queues/listeners retained. | Extended callback tests fail on base: direct retains one byte, relay retains 276 ingress bytes and one observer. | Networking guidance requires automatic cleanup after unwind. |
| Cleanup alone does not prevent a getter callback from publishing one final packet. | `getter-red.json` rejects direct and relay sends after buffered-amount teardown; independent scratch probe agrees. | Recheck channel/socket query gates before sending; retain the regression. |
| A valid retransmission can outlive the viewed ring, including a clean closed tail. | Final spectator regression fails three outer-result assertions on base; canonical state, retained conflicts and malformed controls pass. | Document obsolete ingress separately from retained conflict and liveness. |
| Comparing expected operation digests misses inconsistent actual target lists. | Cold review changes the second source target generation in both emission and receipt; original comparator accepts. | Oracle guidance requires actual ordered target membership validation. |
| Envelope-boundary padding does not prove valid large replay playback. | Prior-main online artifacts contain only 7,221/7,332-byte replays. | Existing collector now requires a real >8 KiB replay; wait for frame 224 within unchanged bounds. |

## Evidence

Local receipts are retained under `.cache/scratch/session100/` and `.cache/tests/`.
The machine-local session log records exact commands, red/green receipts, review
findings and final delivery evidence. Grouped-history scope and residual gaps are
recorded in [the oracle guide](../../docs/oracle-p2p.md).

## Prune ledger

Updated existing networking and oracle guidance in place; no new overlapping skill.
The earlier busy-detach statement is replaced by the concrete automatic-unwind contract.
No other claim was retired. Harness links, generated indexes and source widths
are checked with the repository commands.

## Outcome

State: `findings-acted`. Actual live spectator admission, broader peer-drop parity,
and the remaining release/browser matrix remain tracked in their existing issues.
