# Retrospective: Callback and Playback Boundaries

## Evidence

Session 038 advances client configuration (#40), replay diagnostics (#45), and
spectator liveness (#47). Each boundary has a deterministic failing pre-change
case and valid controls. Exact commands and local receipts are recorded in
`progress/session-038-playback-boundaries.md`.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Callback existence does not prove it accepts the arguments supplied by the library. | `tests/unit/test_driver_callback_signatures.gd` rejects short save, extra required load, and no-argument simulation; optional-argument rollback passes. | Share configuration-time argument-count validation across driver, replay and diagnostic playback; document the parameter-type limitation in GDScript style. |
| A failure code and frame leave replay users without the compared values. | `tests/unit/test_replay_diagnostics.gd` exercises frame-zero/later mismatches, cached restore, returned-byte mutation and successful/failed reconfiguration. | Preserve owned expected/actual checksums only for real comparison mismatches; show the pair in playback and seek failures. |
| A live host can stop producing newly confirmed spectator rows. | `tests/unit/test_spectator_demo.gd` idle_host_liveness fails before kind-3 keepalives; stream tests retain deadline equality, foreign rejection and clean-tail gating. | Separate authenticated liveness from confirmed-input progress in the existing transport skill; preserve all original timeout durations. |
| Suite selection can become stale while parallel implementation adds cases. | `test_selected_suite_declarations_match_inventory` rejected newly added keepalive and diagnostic cases before launcher selection was updated. | Existing infrastructure guidance already requires exact native/Web inventories; update staged suites and preserve the fail-closed gate. |

## Prune ledger

Searched existing callback, snapshot, transport and testing guidance first.
Extended owning skills rather than adding overlapping skills or knowledge files.
Updated spectator documentation's row/END-only wording and explained optional
kind compatibility. Existing timeout, callback guard and snapshot checks remain
applicable. The earlier retrospective archive remains the home for consolidated
foundation work; this record covers distinct current boundaries.

## Verification and limits

Run `make llm-index && make lint-llm && make test-llm` after guidance updates.
Source lines remain limited to 180. Replay file bytes and existing spectator
row/END goldens remain unchanged. Earlier spectator receivers reject kind 3;
callers must agree support and provide host authentication. A keepalive cannot
repair missing input history. Configuration metadata checks argument counts,
not callback parameter types or runtime implementation correctness.
Broader #40/#45/#47 equivalence, live-network and release acceptance stays open.

Outcome: `findings-acted`.
