# Retrospective: 2026-10-11 mesh recovery and observation

## Work under review

Continue WebRTC delivery and repair the production exhausted-window gossip stall.
Evidence lives in [session 014](../../progress/session-014-stalled-mesh-recovery.md)
and the deterministic tests linked below. Both are debugging incidents;
the production change also touches prediction and protocol ownership.

## Findings and actions

| Finding | Evidence | Durable action |
| --- | --- | --- |
| A batch barrier can erase timely individual progress for deadline purposes. | The actual-module regression in `scripts/reference/browser/webrtc_watchdog.test.cjs` advances peer 0 at 15 seconds while peer 1 completes at 25 seconds; the original sampler expires peer 0 at 20 seconds. | Extend the existing browser watchdog guidance in [testing](../skills/testing/SKILL.md): apply each completion against its previous individual deadline and rearm current deadlines. |
| ACK drainage can remove the only receipt gossip carrier exactly when the game can no longer submit new frames. | `tests/unit/test_stalled_gossip.gd` exhausts a three/eight-peer prediction window, drains every ordinary input and ACK, then requires unchanged-sample recovery. Pinned Fortress `gossip_holds_confirmation_below_receipts()` specifies this policy. | Keep the conservative remote-evidence fold; provide a bounded acknowledged-input carrier while exhausted and gossip-bound. Record ownership and timer requirements in [networking](../skills/networking-transport/SKILL.md). |
| Green CI does not discharge a known deterministically reproduced defect. | Head `af1c8cd` has green hosted workflows, but #72's actual-module reproduction still fails. | Retain the existing [delivery](../skills/ship-session/SKILL.md) evidence gate. No duplicate rule needed. |
| A recovery carrier can exceed an accepted queue minimum when timers expire together. | Fresh review reproduces `max_transitions = 1` refusing empty-retry plus nudge traces, and enabled `max_outbox = 1` refusing nudge plus quality report forever. | Extend existing networking capacity guidance; coalesce redundant work and defer optional traffic while enforcing lifecycle deadlines. |
| Async rejection does not immediately stop already queued sibling reactions. | Fresh review resolves a sibling in the same turn as timeout rejection; the first repair samples and rearms after failure. | Deactivate the observation round synchronously on every rejection path; an actual-module ordering table protects the fix. |
| An unset timestamp can overflow elapsed arithmetic at the largest accepted clock. | The fresh public endpoint probe at `INT64_MAX` suppresses the first nudge because `INT64_MAX - (-1)` wraps; the sentinel guard passes both pins. | Extend the existing networking timer rule to require sentinel handling and maximum-clock coverage. |

## Prune ledger

Extend existing testing/networking guidance rather than create overlapping skills.
The earlier voluntary input-idle compatibility limit remains distinct from
exhausted-window recovery; correct its scope in the protocol/session guides.
Earlier session 013 receipts remain historical, with their source bindings intact.
The new session log supersedes delivery status only after actual merge/main gates.

## Verification and outcome

Both pinned native engines pass 157 unit cases and eight determinism cases;
the real browser witnesses and 34-case upstream comparisons pass on both pins.
Fresh-context adversarial reviews finish without revisions. Harness lint and
99 self-tests pass. Session 014 records source bindings and local evidence;
linked issues will record the hosted CI and merge gates.
Broader S3–S5 lifecycle/browser and P2P parity requirements retain their issues.

Retro: findings-acted.
