# Retrospective: peer retries and replay keys

## Work under review

Session 101 advances driver retries (#40), replay inspection (#45), and authenticated
spectator duplicates (#47/#131). Production changes stay small and share existing
publication, playback and stream validation paths. Fresh reviewers receive scoped
diffs and contracts without implementation rationale.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| GUI focus cannot be qualified by calling a handler during unit-runner initialization. | `tests/runner/run_tests.gd:50` runs suites during initialization; the attempted focus case produced engine errors before controls entered the tree. Deferred probes on both pins pass ten actual routing/focus/dialog checks. | Keep deterministic action tests; validate actual routing in a deferred scene. Add the distinction to the existing infrastructure reference. |
| Transport-specific error masking leaves custom transports with different duplicate semantics. | `spectator_stream.gd` returned old-row errors while the relay normalized them. The new obsolete-row case has three intended baseline failures. | Move the policy behind authentication and lifetime gates in the shared stream; remove relay masking. |
| New peer retry behavior must prove both original input identity and partial publication. | `test_driver_peer_parity.gd` compares callback/expert requests, encoded packets and independent original state with one/two local handles. Baseline has sixteen intended failures. | Extend the existing publication workload rather than add a parallel fixture. |

## Evidence

Machine-local log: `progress/session-101-client-progress.md`.
Native action suites and deferred UI probes cover both Godot pins. Runtime logs:
`progress/replay-keyboard-runtime-43.log` and `progress/replay-keyboard-runtime-472.log`.
The browser declaration/copy inventory guards pass with all new cases registered.
The screenshot was rendered after layout and inspected at 960 by 720.

## Prune ledger

Updated the existing testing infrastructure reference; no new skill or duplicate
knowledge page. Removed the invalid focus unit case before qualification. Replaced
adapter-local masking with one stream-owned policy. Existing historical evidence
remains valid; no other guidance is retired.

## Outcome

State: `findings-acted`. Complete source/platform replay acceptance, deployed
spectator routing, and broader driver prerequisites remain in their parent issues.
