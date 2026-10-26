# Retrospective: 2026-10-26 clean spectator completion

## Work under review

- Scope: spectator relay completion classification and browser qualification.
- Trigger: a deterministic production defect found during an independent audit.
- Evidence: the existing relay suite's `post_completion` and `terminal_failures` cases;
  native red/green receipts in the local session log; exact native/browser comparisons.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A valid inner terminal result can become a false outer transport failure. | `signalfish_spectator_relay.gd` mapped every non-OK stream result; post-END polling returned PEER_FAILURE after successful playback. | Require completed authenticated END at the exact boundary before accepting normal termination. |
| Completion can happen inside a control sender, not only between polls. | The sender-callback regression returned PEER_FAILURE before repair. | Apply the same completion distinction after the callback and test queued late traffic. |
| Browser provenance must bind the executed path and staged source, not only the original files. | Independent PATH substitution and staged-source mutations evaded the first qualification candidate. | Execute the inventoried Node path and freeze staged sources through import, native execution and export. |
| Clean playback does not prove clean continued transport service. | Existing clean-tail tests stopped before the next relay poll. | Extend the existing data-driven suite through repeated service, late ingress and SDK loss. |

## Actions taken

The [transport skill](../skills/networking-transport/SKILL.md) now requires tests after
actual playback completion, including completion inside control callbacks. Existing
input-closure guidance was replaced in place to avoid a duplicate rule and retain
its paused-tail authentication requirement. No state, replay or wire format changed.
The existing [testing evidence contract](../skills/testing/references/infrastructure.md)
already requires staged-source verification. Its enforcement belongs in the witness
and regression controls; no duplicate instruction was added.

## Prune ledger

- Fixed the incomplete transport guidance at its existing canonical paragraph.
- Retained separate clean input closure and unexpected-host-loss requirements.
- Reused the existing relay suite and ownership inventory; removed the exploratory test file.
- No unrelated knowledge entries became obsolete.

## Verification and limits

The regression fails before repair and all 26 relay cases pass twice on both engine pins.
Session delivery also requires complete source-width, harness, runtime/browser and CI gates.
The local progress log records exact commands, receipts and final outcomes.
Live authenticated spectator control deployment and broader source parity remain under issues 131 and 47.

## Outcome

Retro: findings-acted
