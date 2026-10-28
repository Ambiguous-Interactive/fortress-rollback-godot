# Retrospective: network recovery evidence

## Work under review

Session 106 addresses terminal mixed-path failures (#75), unequal exposed-history
donor recovery (#188), and exported spectator viewing (#245). The runtime fix,
source comparisons and browser witness receive separate fresh adversarial reviews.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A composed transport can hide a latched SDK failure behind successful relay service. | `signalfish_fallback.gd` omitted SDK_FAILURE from poll handling and checked only WRONG_STATE in direct status. Three new failure cases fail before repair; ERR_BUSY passes. | Propagate terminal direct status and poll errors. Extend the existing networking skill's composition paragraph. |
| Unequal public frontiers can be produced without editing session counters. | The actual Rust/Godot grouped witness advances one coordinator through its public request API, observing frontiers [4,5] and source retained floors [3,2]. | Extend the existing source comparison and validators; preserve independent original histories and explicit wire-parity limits. |

The exported viewer work reinforced existing source/tool-freeze and final-event-drain
rules. The first import attempt included extracted duplicate SDK sources; ignoring
those extraction roots fixed staging without weakening the addon/SDK inventory.
Fresh review checked the resolved Node invocation and Playwright/browser/template
inventories. Repeated final runs replace earlier receipts invalidated by edits.

## Verification

- Both pinned engines pass all 22 fallback/mixed cases, repeated in fresh processes.
- Both pinned engines pass eight source-comparison scenarios twice with 347 negative controls.
- Both engine pins pass actual exported Chromium viewing and altered initial-state rejection.
  Healthy viewers compare 48 canonical boundaries, pause with retained rows, catch up and finish cleanly.
- The unchanged busy control distinguishes retryable refusal from terminal SDK failure.
- Source-width and harness checks pass. Existing ownership inventory tests pass 46 cases;
  harness self-tests pass 161 cases.
- Local command outputs and source-bound receipts are recorded in the machine-local
  `progress/session-106-recovery.md` delivery log.

## Prune ledger

Updated the existing terminal-composition guidance instead of adding a duplicate
transport rule. Its prior lifetime fence remains explicit alongside SDK failures.
Existing source-comparison documentation retains physical donor eviction, broader
loss/reordering schedules and full protocol parity as unqualified work.

## Outcome

State: `findings-acted`. Broader physical/live recovery and exported host/seated
browser lifetimes remain in their existing issues.
