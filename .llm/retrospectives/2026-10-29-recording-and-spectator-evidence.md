# Retrospective: recording and spectator evidence

## Work under review

Session 110 advances driver failure diagnostics (#40), remote recording acceptance
(#45), and disconnected spectator source comparison (#47). The changes add one
peer report field, an offline viewer summary, and independently checked source
witnesses. Each workstream receives a fresh adversarial review.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Live callback metadata can disappear from saved diagnostic reports. | `PeerSession.diagnostics()` omitted `failure_kind`; the expanded real-peer SAVE/LOAD/ADVANCE matrix has nine missing-field failures on the original code. | Export the first failed callback kind and display its name/frame separately from capture and playback comparisons. Keep historical reports readable. |
| Corrected actual input rows do not imply corrected recorded checksums in the pinned source. | The remote source witness executes LOAD at 0/2/4/6, then decoded playback reports `ReplayDesync` at 1/3/5/7. Neutral inputs under identical delivery have neither LOAD nor mismatch. | Preserve exact source events and checksum pairs, document the recording-order discrepancy in `docs/oracle-replay.md`, and track reviewed resolution in #253. |
| Equal input bytes cannot establish finalized status preservation. | The reserved-slot source witness changes only DISCONNECTED to CONFIRMED; both the status transcript and independently calculated canonical state reject it. | Qualify initially reserved-slot status delivery across 2–8 players, delay, catch-up and ring reuse; retain mid-match drop and live-routing limits. |

The existing testing and networking skills already require paired controls,
status-sensitive games, original canonical histories and explicit source differences.
No duplicate skill or new general rule was needed. Durable source-specific findings
live in the owning replay and spectator guides.

## Verification

The focused witnesses run twice per engine and compare actual pinned Rust sessions
against production Godot APIs. The replay observation retains every ordered request,
input/status, snapshot and decoded replay result. The spectator witness retains
all 56 required workloads independently of the generated observations.

The diagnostic reader covers legacy reports, malformed metadata, owned snapshots,
real remote correction LOAD failure and first-cause preservation. A rendered offline
viewer confirms the extra summary fits above the game board.

Full native suites, integrated source/model gates, source widths, harness checks,
current-head CI and complete PR feedback scans are recorded in the machine-local
session log and linked issue delivery evidence. Narrow native source witnesses do
not establish exported-browser source parity or complete issue closure.

## Prune ledger

- Revised broad replay/spectator disclaimers at their source to distinguish the new
  qualified cases from remaining asymmetric delivery, mid-match drop and live work.
- Kept historical source observations and old report compatibility intact.
- Existing testing/networking guidance already covers the reusable techniques;
  considered and rejected duplicate knowledge entries.

## Outcome

- State: `findings-acted`.
- Follow-up: #253 owns source checksum ordering and reviewed baseline acceptance.
  Original broader #40/#45/#47 and browser release gates remain open.
