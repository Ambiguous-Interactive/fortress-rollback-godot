# Retrospective: idle service batches and transport traffic

## Work under review

The direct and relay transports report the traffic they moved, and the direct
adapter, the relay adapter and the composed fallback coordinator expose
`idle()`. The online example and the browser witness stop their bounded
eight-round service batch once the route is idle. A new public result field
and a new public method on shipped transports trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| The relay's traffic counter was structurally always zero, so the claim that a refused frame still counts as traffic was false for the relay route | The pinned SDK hands frames over from its own event pump, which runs between polls; differencing the counter at poll entry never saw them. A fresh-context adversarial review and Cursor Bugbot both reported it, and a mutation that restores the difference fails the delivered, refused and idle assertions | Count the frames the SDK hands over and drain that count in the poll; keep the direct adapter's own rule of counting the packets it pulls from the socket |
| An idle rule that ignores refused traffic can end a service batch while valid bytes sit behind the refusal | The preserved session-025 prototype decided idleness from `result.received` and the retained queue; the review that blocked it from shipping is recorded in #104 | Count refused items as traffic, and keep the caller's own retained batch in the idle rule |
| A new public contract is worth nothing until a mutation fails without it | The relay's `activity` and `idle()` were unpinned: a relay that always reported zero activity left the whole unit suite green | Pin the direct, relay and example rules with their own cases, and record the mutation that fails each one |
| Another agent session can share the working tree, and its commits and file restorations land on the current branch | During this session a concurrent session switched the checked-out branch, committed five times, merged its own pull request and left the working tree with this branch's changes reverted | Build the session branch in a dedicated worktree, keep the shared index untouched, and merge `main` into the branch before the final gate |
| The SignalFish SDK's delivery model decides how a transport can count traffic | The SDK emits `game_data_binary_received` from `client.poll()`; a transport that is polled afterwards must drain its counter rather than difference it at poll entry | Record the fact in the transport knowledge file and reference it from the transport skill |

## Actions and pruning

Added the delivery-model fact to
[transport tooling](../knowledge/transport-tooling.md) rather than creating a
new knowledge file, and pointed the networking transport skill at the same
rule. No existing knowledge entry became false, so nothing was retired.

The retrospective for the session-025 prototype stayed in the issue, and the
prototype patch stays machine-local: the shipped rule is now the drained
counter, not the prototype's `received`-based rule.

## Outcome

The shipped change reduces an idle rendered turn from eight transport polls to
one, keeps the full bounded batch for a busy, refused or mixed route, and
reports refused traffic on both routes. The eight-player Firefox and mixed
browser matrix is not qualified by this change; #104 keeps that acceptance
with the measured remaining gaps, #147 tracks the host scheduling-gap
measurement and #148 tracks the remaining browser job time.
