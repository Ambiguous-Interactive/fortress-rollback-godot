# Retrospective: client ownership boundaries

## Work under review

Session 086 addresses spectator participant lifetimes, mutable replay validation,
public manual peer requests and completion guards under #131, #47, #45 and #40.
It also adds a scoped actual-source donor-history comparison under #188.
The production debugging incidents require this retrospective.
The [session log](../../progress/session-086-client-reliability.md) retains
commands, baseline failures, passing controls and delivery evidence.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A remote participant can leave without changing the local SDK role or identity. | The spectator source-departure tests advanced buffered gameplay after the selected host left; the admitted-viewer test still published after disconnection. | Observe the selected participant during setup and runtime; retain unrelated-participant controls. |
| Decoder validation cannot protect a recording changed before playback takes ownership. | Replay configuration accepted truncated storage and invalid metadata, replacing working playback. | Validate bounded representation before copying through either playback interface. |
| Structural rejection and content diagnostics have different boundaries. | The first broader replay run caught an existing missing-digest diagnostic that the new strict length gate rejected early. | Preserve safe deferred digest failure while rejecting unsafe storage before indexing. |
| A facade-local callback flag does not fence the shared peer engine. | Peer notification controls reproduced an extra advance, configuration reset and lost cancellation through another facade. | Apply shared guards before transport effects and destructive drains; refresh terminal metadata after handlers. |
| An observer can hide the status defect its comparator should detect. | Fresh review found the drop trace mapping every non-disconnected status to confirmed, including predicted and unset values. | Preserve actual status values and distinguish finalized exports from applied-request observations. |

## Durable guidance

Updated the existing [transport skill](../skills/networking-transport/SKILL.md)
with selected-participant lifetime filtering and mutable replay ownership checks.
Its replay section distinguishes structure from deferred content diagnostics.
The [rollback skill](../skills/rollback-fundamentals/SKILL.md) already requires
shared completion guards; the peer regressions enforce that existing guidance.
The [oracle guidance](../skills/testing/references/oracle-validation.md) now
requires distinct request/export status observations without confirmed defaults.
No additional knowledge topic duplicates these procedures.

## Prune ledger

Reviewed existing transport, replay and callback guidance before editing.
Condensed the replay format paragraph in place, keeping the transport skill
below its line cap. No validated contract was retired or weakened.
The initial workspace report identifies 1.03 GB of reclaimable old output;
new evidence uses existing revision-keyed caches and cache-excluding scratch.

## Outcome

State: `findings-acted`.
The existing issues retain full upstream, deployed spectator control and
platform qualification requirements; these repairs do not establish them.
