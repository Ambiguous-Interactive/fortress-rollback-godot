# Native qualification and drift evidence

## Findings

- The scheduled drift job failed with `[Errno 7] Argument list too long: 'gh'`.
  Passing the actual server observation on stdin reached a second limit.
  The comment was 146,840 bytes. The fixed reporter preserves the complete
  classification with 670 records and posts one digest-linked observation.
  [Drift Report failure](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45125770752)
- The first artifact design posted observations before upload. Review found
  that a failed upload left a broken deduplicated link, and a workflow retry
  could replace the evidence. Publish from the staged report after uploading
  immutable evidence. A failed upload leaves no new observation.
- WebKit's current-main qualification passed gameplay in smaller rooms and
  then timed out proving departure in Godot 4.3 `mesh:4` and 4.7.2 `mesh:8`.
  The old failure receipt omitted the clock brackets. Poll the entire close
  proof so either an exact abort or clock order can arrive before the deadline.
  Preserve snapshots from healthy renderers when a page crashes.
  [Hosted WebKit baseline](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45231560553)
- The Linux driver fixture built endpoints from the final slot's ID. A valid
  sparse roster failed during test configuration. Deriving actual endpoint
  owners let both Godot pins confirm frame 47 after rollback with identical
  canonical state. Both rejected the wrong sample at frame 12.
- A three-CPU Firefox relay room completed control exchanges on all eight peers
  during the hold. Two peers expired after the synchronous release. With paced
  release, all peers matched 40 rows and snapshots and the largest observed
  browser send buffer fell from 199,788 to 62,474 bytes against a successful
  smaller unpaced control. The hosted baseline also failed before release, so
  the pacing result covers the burst during correction.
  [Hosted Firefox baseline](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45231576057)
- A paced Godot 4.3 room reached confirmed recovery then timed out waiting
  for browser history. The witness serialized the entire history on every
  render while capture was enabled. It now exports one requested prefix.
  The control rejects a stale receipt, a changed frame count, a wrong input
  row and a wrong canonical snapshot.

## Changes to guidance

The [GitHub operations skill](../skills/github-operations/SKILL.md) separates
process arguments from endpoint body limits and puts artifact upload before
issue publication. The workflow and staged-publication controls check both
ordering and deduplication.

The [project overview](../context.md) now describes the implemented native
browser witness. [PLAN.md](../../PLAN.md) links the remaining browser evidence
and direct-link replacement gates.

The [browser testing guide](../skills/testing/references/browser-integration.md)
keeps pre-release receipts and measures addressed relay traffic and queue peaks
before changing the release schedule.

## Remaining evidence

The release roadmap tracks direct restoration, branded Safari and signed
mobile exports. The CI iteration tracker requires 40 completed natural
candidates per event on one layout.
