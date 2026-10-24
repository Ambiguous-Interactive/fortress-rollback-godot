# Retrospective: startup controls and history certificates

## Work under review

Session 072 addresses spectator acceptance control (#131), independent drop-value
certification (#188), and shared executable preparation (#197). The work changes
production transport and agreement boundaries plus their deterministic tests.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Shared executable extraction can truncate a live inode even with separate output receipts. | `test_fetch.ReferenceContracts.test_engine_preparation_preserves_live_process_and_cached_bytes` reproduces `ETXTBSY` before the repair. | Replace extraction with verified member comparison and atomic publication; correct stale serialization guidance. |
| Permission checks must include special mode bits, not only ordinary permissions. | The cache review reproduced retained `04755`; the mode-only regression failed before comparing `07777`. | Extend the existing corruption table to special bits and clear them during reuse. |
| A certificate must compare supplied bytes with local retained authority, even when a sender supplies a matching digest. | `test_peer_drop_history` conflicting frozen-backfill case failed READY/certified assertions before repair. | Compare retained cut input before certification; preserve the separate explicit expert freeze contract. |
| Transport acceptance and recipient agreement require distinct evidence. | `test_signalfish_spectator_relay` control retry keeps the publisher unsynchronized until actual acceptance receipt. | Document caller control-service responsibility and retain exact refused bytes. |

## Durable guidance and pruning

Updated the existing [browser integration procedure](../skills/testing/references/browser-integration.md)
at its shared-cache rule. Atomic member publication replaces the editor/Chromium
extraction restriction; launcher project/result ownership and Firefox installation
still require serialization. No new skill or duplicate knowledge topic is needed.
Existing networking guidance already requires immutable overlap checks and callback
lifetime revalidation; the implementation now applies those rules at these boundaries.

## Verification

Focused gameplay tests pass twice in fresh processes on both pinned engines.
Cache subprocess controls and native/Chromium smoke pass. Full native and exported
suite delivery evidence is recorded in the machine-local session log and issue updates.
Fresh review found the special-mode regression, which received a failing control
before repair. No source receipt from an explicitly stopped pre-freeze probe counts
as successful verification.

## Outcome

State: `findings-acted`.
Full spectator control-service/browser acceptance and pinned drop trace comparison
remain in #131 and #188; scoped delivery does not establish complete feature parity.
