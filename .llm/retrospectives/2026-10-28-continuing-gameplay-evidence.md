# Retrospective: continuing gameplay evidence

## Work under review

Session 108 extends three player-facing acceptance boundaries: drop recovery after
COMMIT loss (#188), replay extraction during continuing gameplay (#45), and
physical exported-viewer departure with buffered playback (#131/#245).
Production behavior and portable formats remain unchanged.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| An export rebuilt after continuation cannot prove the original export stayed independent. | `tests/oracle/replay_session_trace.gd` and `scripts/oracle/rust/src/bin/replay.rs` now retain the actual decoded early object before continuing. | Extend the existing oracle-validation reference; compare retained playback, original callbacks and later extraction separately. |
| Source/product extraction semantics differ while both continue the game. | Pinned `take_replay()` disables recording; production Godot `replay()` preserves recording. The continuing-extraction corpus checks each outcome explicitly. | Preserve both contracts in the source comparison and integration evidence; do not normalize them into a false parity claim. |
| Final-state equality cannot prove a lost irreversible decision was retried. | `scripts/oracle/drop_history_contract.py` reconciles actual COMMIT emission, discard and retry receipt identities. | Extend existing donor-history accounting to first COMMIT loss, alone and combined with donor-data loss. |
| Paused browser playback must stop before accepted buffered rows can advance. | `scripts/reference/spectator_browser_viewer.gd` captures canonical state and simulation-call count around a controller-closed WebSocket. | Require physical selected-viewer departure, unchanged buffered playback, and independent continuing host state. |
| Polling can repair a missing disconnect callback before the witness attempts gameplay. | Fresh review found `relay.poll()` preceding `driver.step()` in the exported departure cell. | Attempt buffered gameplay and audit ingress before polling; extend the browser integration guidance and add a callback-only mutation. |

## Evidence and review

Exact commands, engine receipts, red controls and independent review outcomes
live in `progress/session-108-gameplay-correctness.md` and the linked task issues.
Exploratory oracle runs refused success receipts when other agents changed shared
sources. Final receipts require a frozen tree; earlier raw logs remain diagnostics.
Fresh adversarial reviews receive only the scoped diff and acceptance excerpt.

## Prune ledger

Updated the existing oracle-validation and browser-integration references instead of adding another skill.
Removed stale PLAN restrictions to prediction window two and replay versions four/five;
existing source comparisons already exercise lockstep and version six.
Kept physical eviction, full source wire parity, remote recording and exported-host
qualification gaps in their existing issues. Historical scoped receipts remain historical.

## Outcome

State: `findings-acted`. Broad release and source parity remain separately gated.
