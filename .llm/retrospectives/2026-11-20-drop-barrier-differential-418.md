# Retrospective — session 207: the differential corpus naming the carried roster digest

PR #418 (issue #414 slice 4; checklist line shared with #48/#166).

## What happened

Session 206 landed the roster-digest wire field (#416) but left #414's slice-4
remainder open: the pinned-trace differential corpus compared whole packets, so
the extended field was byte-present but unnamed, and the coordinator's
survivor-link proposal was never captured on the Godot side. Session 207
captured the proposal, named the digest under its own diagnostic on every
payload shape, tied it to the pinned prepare's participant list, and added five
per-scenario digest-corruption controls.

## Durable lessons

1. **A field inside an exact-byte comparison is not a compared field.** Without
   a diagnostic of its own and a mutation that fails under that diagnostic, a
   wire field's coverage is indistinguishable from incidental byte overlap.
   When a wire field is added, name it in the comparator and corrupt it in the
   corpus's controls — the negative-control survived check is the red gate.
2. **Derive retry-bearing wire schedules from real emissions, then classify per
   emission.** The prepare schedule has retry-dependent shapes; a single
   expected byte string would have been brittle. Two shapes' constants (the
   stage-0 final candidate) did not exist in donor scenarios at all — the
   transfer configures from the donor's inventory answer first. Assumption
   would have shipped a vacuous expectation; the wire captures caught it.
3. **Adding a capture bank touches every order-arithmetic control.** The ack
   and inventory re-timing controls (×4 scaling) and the observation-order
   uniqueness check each enumerate banks explicitly; a new bank must be added
   to every enumeration or retimed traces collide. Sweep for bank-list
   literals when a trace schema grows.
4. **Never launch a long gate while the tree is still being edited.** The
   first `make gate` failed closed on `source_changed` because CHANGELOG and
   progress edits landed mid-run; the runner's snapshot check is doing its
   job. Commit (or freeze) first, then gate.
5. **Corpus red paths are cheap regression evidence.** The two mid-run
   failures (missing trailer pre-check; order collision) were found by the
   run itself within minutes; recording them in the progress log doubles as
   the red-green narrative.

## Verification

- PR #418: `make drop-history-probes` green on 4.7.2 (16 scenarios × 2
  repeats, 1021 negative controls, 80 named digest controls); `make gate`
  green on the committed tree (131 suites, 858 cases, twice); lint-source 552
  files / 0 violations at 180 columns.
- Adversarial sub-agent review ran on the committed diff; findings triaged in
  the session log `progress/session-207-drop-barrier-differential.md`.
