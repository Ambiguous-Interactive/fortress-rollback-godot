# Retrospective: 2026-11-01 scene lifetimes and input domains

## Work Under Review

- Scope: example input validation, scene-owned game retirement, spectator pause controls.
- Trigger: production debugging, multiple scene owners and fresh adversarial review.
- Evidence: session 135 deterministic red/green receipts, live scene-removal witness,
  viewport pointer witness and native/browser ownership inventory checks.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Integer-to-byte conversion accepts invalid controller values by wrapping | `examples/integration/loop.gd` preflight; integration controls red case with 256 and -256 | Validate the game domain before conversion, clocks or sample mutation |
| Node departure does not retire retained RefCounted gameplay owners | Scene-exit regressions retain drivers, players and manual writers in six scenes | Terminate owned sessions/players in scene exit and preserve first cause |
| Initialization-time unit tests do not establish actual scene-exit delivery | Native runner executes before the root enters the live tree | Retain deterministic teardown coverage and verify actual removal in deferred live-tree witnesses |
| A browser host running suites inside its own ready callback blocks root child creation | PR 293 Firefox job 124767735203, diagnostic lifetime artifact reports `Parent node is busy setting up children` | Defer the existing host entry point until ready returns; preserve real scene teardown tests |
| Parallel authoring can change a selected browser case inventory | Ownership harness declares copied suites and exact case sets | Update selected declarations, staged dependencies and Web host together before source freeze |

## Actions Taken

The existing GDScript style skill now requires scene ownership retirement and
validation before integer narrowing. The testing infrastructure reference already
requires live-scene evidence for initialization-time GUI tests. It now also covers
the browser host's distinct ready-time child-creation restriction.

The existing ownership harness includes the new scene-exit suite and complete
scene dependencies. Replay and diagnostic lifetime cases remain in its exact
native/Web inventory. No parallel general-purpose test runner was added.

## Prune Ledger

- Searched the existing GDScript style and testing infrastructure guidance first.
- Extended the existing ownership rules; no new overlapping skill was created.
- Preserved the live-tree guidance because these experiments confirm it.
- Source-pin, replay-format, transport and full parity claims remain unchanged.

## Outcome

- State: `findings-acted`.
- Follow-ups: broader release and upstream acceptance remain in issues 40, 45 and 47.
