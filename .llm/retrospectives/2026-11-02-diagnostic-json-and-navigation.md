# Retrospective: 2026-11-02 diagnostic JSON and navigation

## Work Under Review

- Scope: portable diagnostic JSON, coarse replay navigation and native process supervision.
- Trigger: new controls, serialization repair and subprocess evidence changes.
- Evidence: issue #305 reproductions, strict-decoder probes, process controls and viewport-dispatched keyboard experiments.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Godot serialization and parsing agree on text that standards-strict JSON consumers reject. | `scripts/reference/diagnostic_json.py` checks actual exported metadata with Python's decoder, then replays decoded windows. | Share `FortressDiagnosticTrace.to_json` across diagnostic writers; point copy guidance to it. |
| GUI focus consumes arrow keys before unhandled shortcuts. | The focused-button viewport probe left frame zero unchanged after Right; J/L starts bounded navigation under the same focus. | Use J/L and extend the existing browser integration guidance. |
| Parent completion does not prove owned children stopped. | `scripts/reference/test_godot_runner.py` starts redirected-output children behind successful parents. | Reject surviving process groups and retain stable cleanup identity after leader exit. |
| An empty-case rejection need not load every production suite. | The runner's empty-filter control exceeded its ten-second bound; selecting its small control suite preserves `zero_matching_cases`. | Keep the existing rejection check with a bounded fixture selection. |

## Review Follow-up

- Automatic review found that the child-replacement hook stopped firing after group qualification changed.
- Added unconditional injection/leaf/group assertions and retained a separate enumeration-race mutation.
- Persisted viewport-dispatched focus checks in CI; local-only GUI evidence did not protect future routing changes.
- Both repairs passed fresh adversarial review. Testing guidance now requires fault fixtures to prove their injection ran.

## Curation and Pruning

- Updated existing testing and copy guidance rather than adding a new skill.
- Existing source-freeze guidance already covers concurrent verification; retained it.
- Existing process-supervision documentation now states detached-group limits explicitly.
- No canonical guidance was removed; no duplicate knowledge entry was created.
- Generated index/stubs remain generated; verify with `make llm-index`, `make lint-llm`, and `make test-llm`.

## Outcome

- State: `findings-acted`.
- Follow-ups: #298 retains imported Python helper identity and deliberately detached process containment; #45 retains broader replay parity and release acceptance.
