# Retrospective: client recovery and dependency refresh

## Work under review

Session 103 advances peer-drop recovery (#188/#48), spectator completion (#47),
and online replay inspection (#45). It refreshes source, compiler, browser,
container-tool and workflow dependencies. The change triggers the large-change,
new-capability and debugging retrospective rules.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A remote donor must yield after any accepted certificate, even if another link refuses. | `peer_drop_barrier.gd` previously yielded only when `_send()` returned complete success; the new four-peer regression fails only under sustained coordinator pressure. | Move the yield into per-destination acceptance and preserve each link's retry timestamp. |
| Clean spectator completion needs no new frame or request token. | The new expert/Driver boundary test reports exhaustion on the original code; completed and unfinished controls differ only by accepted host closure. | Test completion before allocation limits, retaining all mutation guards. |
| Updating provenance can reject compatible recordings even when simulation source is unchanged. | `replay_viewer.gd` matched only `Replay.UPSTREAM_REVISION`; original-metadata regression fails before the compatibility fix and passes afterwards. | Preserve known compatible original provenance and add the general testing rule to infrastructure guidance. |
| Browser registry revision does not define archive layout. | Playwright 1.64.1 uses architecture-specific `chrome-linux64` and `chrome-linux-arm64` directories; the old artifact URLs return HTTP 400. | Pin executable paths per architecture and use them in every launcher. |
| Updated SDK cleanup calls the multiplayer test double's `has_peer`. | The real SDK probe prints its success marker then fails cleanup with a missing-method error. | Complete the test double's peer bookkeeping; the fail-closed launcher catches and verifies the repair. |

## Verification

- Both pinned engines pass 73 spectator cases in two fresh executions each.
- The new four-peer donor-pressure regression fails before repair and passes
  with the repair on both pinned engines; its no-pressure control passes.
- Current Godot passes the full replay-viewer suite, including recorded-input
  inspection, corrupted-row refusal and original-baseline imports.
- The updated Rust baseline passes queue (115), sync (8), network (3),
  repeat-trace (1) and divergence-control (1) selections twice.
- The updated SDK probe passes; the new server builds with Rust 1.99.1.
- Godot 4.3 and 4.7.2 web smoke execute with the new Chromium.
- Fresh gameplay review covers the six adversarial surfaces with no findings.
- Full session CI and delivery evidence belong to the session PR and issue
  updates; these local observations do not replace those gates.

## Prune ledger

Corrected the reference guide's obsolete claim that sources had never advanced.
Updated PLAN.md's current reference links. Frozen golden files and historical
receipts retain their original revisions; they remain useful compatibility and
provenance evidence. No additional skill or overlapping knowledge topic was added.

## Outcome

State: `findings-acted`.
The broader roadmap acceptance gates remain with #45, #47, #48, #131 and #188.
