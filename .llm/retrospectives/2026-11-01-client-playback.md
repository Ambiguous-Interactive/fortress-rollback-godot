# Retrospective: 2026-11-01 client playback

## Work Under Review

Session 134 adds selected replay-prefix downloads and continuous spectator live
following, and repairs replacement and reentrant controls in the local peer example.
It carries forward the existing shared Rust incremental-cache setting and its test.
Triggers: new capabilities and a reproduced match-lifetime defect.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Replacing public peer arrays does not retire retained sessions. | `test_peer_example_ownership.gd` retains both old peers; main permits an old step and changes canonical state after reset. | Stage valid replacement sessions, close prior peers, and preserve the current match on invalid configuration. |
| A selected peer's guard does not protect a composed match. | The cross-peer completion control observes delay results BUSY/OK and OK/BUSY before repair. | Check both owned peers before reset, tick, rule changes and delay changes; extend the existing ownership testing guidance. |
| Removing viewing delay alone cannot catch a running host at a one-frame playback rate. | The Follow live experiment crosses a paused backlog with ongoing changing host inputs at original speeds one and four. | Set zero delay/threshold and the configured bounded capacity; compare the exact delivered frontier and independent canonical state every tick. |
| Saving an inspected prefix must not claim new validation. | Prefix tests cross v5/v6, backward cached selection, sparse checksums, frame zero and failed input history through independent decode and playback. | Reuse original owned-prefix storage; preserve only existing checksum evidence and gate unreadable empty prefixes. |

## Verification

Both supported engine pins pass focused playback and ownership suites in fresh
process pairs. Native prefix download is read back, decoded and replayed against
original canonical history. Actual spectator mouse/keyboard routing and both
changed interfaces were rendered and inspected. Fresh adversarial reviews cover
all six attack surfaces. Final full-suite and delivery results belong to the
local session log and current-head CI; focused evidence does not claim whole
upstream parity or exported spectator admission.

## Prune Ledger

Existing rollback guidance already requires retiring owned matches and staging
replacements. One sentence adds both endpoint positions and rejected replacement
state; no duplicate skill is introduced. No guidance was proved obsolete.
The cache dry run reports 2.26 GB of pre-existing reclaimable entries; no cleanup
was required. New captures and test receipts use machine-local progress paths.

## Outcome

State: `findings-acted`.
Remaining source parity, browser release qualification and production spectator
admission remain with #40, #45, #47 and their existing linked follow-up issues.
