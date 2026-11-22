# Native migration and verified teardown

## Evidence

The native experiment passed all 12 platform jobs at `ce727fa`. The merge group
failed only Reference negative controls and its summary. In the failing case
`finish()` raised `EscapedDescendants`, then the fixture still saw the recorded
grandchild PID alive. The group log lacks kill results and stable PID identity,
so it cannot establish which Linux event produced the observation.
[Platform jobs](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45051273985) ·
[Failed group](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45057185569)

The focused original test passed locally. The new real-process control withheld
the first kill and exposed the missing post-signal verification on the original
code. It failed with `1 not greater than or equal to 2` for the number of delivery
attempts. The control also distinguishes an incomplete cleanup from an escape
that was stopped, including a process no longer found by an ownership scan.

## Findings and actions

- A kill attempt can produce a report while the process is still alive. Keep the
  original process identity from enumeration and confirm its retirement. Fresh
  ownership still authorizes each signal. Once tracked processes retire, scan
  again for children they could have started before exiting. The scripted
  control failed with only PID 81 swept and passed when the new scan found 82.
- The browser experiment's loopback bridge establishes wire and callback
  compatibility with the stock peer. Treat room admission, transport lifecycle,
  legacy recordings, and installation as individual gates. The
  [migration contract](../../docs/native-backend-migration.md) gives each one an
  owner or an acceptance check.

## Prune ledger

Updated the [infrastructure testing reference](../skills/testing/references/infrastructure.md)
where it already requires retirement checks. Replaced the experiment report's
generic migration prerequisite with a link to the contract. The current
GDScript support declaration stays accurate during the transition.

## Outcome

findings-acted
