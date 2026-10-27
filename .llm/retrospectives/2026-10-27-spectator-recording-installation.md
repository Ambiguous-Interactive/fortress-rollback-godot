# Retrospective: spectator recording and installed validation

## Work under review

The spectator example exports its displayed history and captures clean final
boundaries through the shared driver. The addon installation audit records
status-sensitive spectator rows and checks portable callback/expert playback.
New capability and review-driven rework trigger the full loop.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A reporting mutant does not prove checksum validation. | The audit passed with the final comparison bypassed while its status getter remained intact. `test_installed_spectator_replay_is_actually_validated` failed as expected before the corrupted-recording probe. | Add actual final-checksum corruption and a comparison-bypass mutant; strengthen the existing infrastructure evidence guidance. |
| Final capture must precede orderly spectator retirement. | `test_spectator_demo_recording.gd` compares clean empty and nonempty endings through both playback APIs. | Route both continuous and single-step completion through the same final capture. |
| Recoverable recording limits differ from session failure. | Fresh review ran 36,040 ticks, exported exactly 36,000 rows without invented terminal evidence, then completed playback. | Preserve viewing beyond recording capacity; branch on session reason rather than operation code. |

## Verification

The dedicated recording suite failed the three missing-feature controls before
implementation. Callback-failure assertions then exposed stale example status;
repair synchronizes the terminal reason without relabeling recoverable limits.
The installed comparison-bypass control passed the weak audit and now fails it
for the corrupted final checksum. Restored source passes again.
Commands and source-bound receipts are recorded in the machine-local
[session log](../../progress/session-095-spectator-recordings.md).

## Prune ledger

Existing test infrastructure guidance already covers installed archive inventories
and honest controls. Extend that authoritative paragraph rather than creating a
new skill or duplicating it in the browser guidance. No existing claim was retired.
The package documentation now describes the stronger exercised installation flow.

## Outcome

- State: `findings-acted`.
- Follow-ups: original source/platform/release acceptance remains in #44, #45 and #47.
  The example's same-process transport does not qualify live spectator networking.
