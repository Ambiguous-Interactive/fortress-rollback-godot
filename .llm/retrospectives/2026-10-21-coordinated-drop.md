# Retrospective: 2026-10-21 the coordinated peer drop

## Work Under Review

- Scope: the coordinated drop of a departed peer in the peer session, the new
  `FortressPeerDrop` helper, the `DROP_BARRIER` protocol kind with its codec,
  validation, projection and endpoint plumbing, the session's global rollback
  floor accessor and the new `test_peer_drop_barrier` suite. Seventeen files,
  about 600 changed lines.
- Trigger: a large gameplay change that changes the wire protocol and the
  lifecycle contract.
- Evidence base: the whole native suite passes in fresh processes on both
  pinned engines, the reference control suite passes (143 tests), the source
  width lint passes at 180 characters and the harness lint passes.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | The graceful drop froze the departed slot at each survivor's own confirmed frontier. Two survivors whose frontiers differed froze at different frames, simulated different frames afterwards and reported a desync, so a departure ended the match for everybody who stayed. | gap | `addons/fortress_rollback/core/peer_session.gd` `_drop_peer` before the change: `var cut: int = _core.status().confirmed_frame` |
| 2 | The frame a survivor can freeze is bounded on both sides: the newest frame it confirmed and the oldest frame its queue still retains. The lower bound is the session's global rollback floor, so the agreement window and the cross-player history protection use the same bound. | fact | `addons/fortress_rollback/core/peer_drop_barrier.gd` `observed` and `service`; `addons/fortress_rollback/core/session.gd` `rollback_floor` |
| 3 | The match must hold while the barrier runs. The session releases the frames below its floor as it advances, so a survivor that keeps simulating during the barrier loses the value the cut needs and the agreement fails. | fact | `addons/fortress_rollback/core/peer_session.gd` `_step` returns `PREDICTION_STALL` while a barrier is pending; the `held_match` case fails without the hold |
| 4 | The roster is fixed, so the lowest surviving slot names the same proposer for every survivor. That removes the multi-proposer race without a clock or a tie-break. | technique | `addons/fortress_rollback/core/peer_drop_barrier.gd` `_lowest_slot` and `_owns_lowest` |
| 5 | A survivor must observe the departure itself before it answers a proposal, otherwise one peer could drop a live peer. The proposal names the departed peer's slots and the receiver matches them against its own roster. | fact | `addons/fortress_rollback/core/peer_drop_barrier.gd` `received` stores a proposal it has not observed yet and answers it after its own detection |
| 6 | A peer that keeps answering is not departed. The departed peer's acknowledgements kept the survivors' links alive, so the first fixture never saw a departure. | technique | `tests/unit/test_peer_drop_barrier.gd` `_detect` stops delivering to the departed peer, which models a crashed process instead of a silent one |
| 7 | A typed array assignment from a conditional silently produced an empty loop, so the whole fixture played no frame and every later assertion measured nothing. | bug | `tests/unit/test_peer_drop_barrier.gd`: `var active: Array[int] = players if not players.is_empty() else range(mesh.peers.size())` iterated zero times; the fixture now builds the list explicitly |
| 8 | The packaged addon only accepts an audited list of runtime scripts, so a new addon file breaks the package builder until the list names it. The failure is a fast reference-control error, not a runtime one. | gap | `scripts/package_addon.py` `RUNTIME_SCRIPTS` now names `core/peer_drop_barrier.gd`; the CI job `Reference negative controls` failed with `unsupported addon file: core/peer_drop_barrier.gd` before the fix |
| 9 | The peer session crossed the 1000-line lint cap with the barrier, so the agreement moved into its own class. The helper reads the session's state through the host argument. | technique | `addons/fortress_rollback/core/peer_drop_barrier.gd`; `gdlint` reported `Max allowed file lines num (1000) exceeded` before the split |
| 10 | A constant is not reachable through an instance in GDScript, so the helper could not read the session's preloaded type constants and had to preload them itself. | fact | `host._Types.Code.OK` raised at runtime; `addons/fortress_rollback/core/peer_drop_barrier.gd` preloads `session_types.gd` and `lifecycle_types.gd` |
| 11 | The proposer was the owner of the lowest slot in the roster, so after the owner of the lowest slot had left, no survivor proposed and the survivors fell back to their own frontiers. The agreement degraded to the split history the change exists to stop. | bug | `addons/fortress_rollback/core/peer_drop_barrier.gd` `_lowest_slot` now skips the peers that already left; the `second_departure` case fails with the old rule |
| 12 | The quorum counted the answers of survivors that had left since they answered, so the proposer could commit without the windows of the survivors that stayed, and a lagging survivor then froze at another frame. | bug | `addons/fortress_rollback/core/peer_drop_barrier.gd` `service` counts only the answers of the survivors that are still in the match; the `second_departure` case fails with the old count |

## Distilled lessons

- The mesh-wide agreement needs a frame that every survivor can *retain*, not
  only a frame every survivor has *confirmed*. The lower bound is the same
  global rollback floor that protects cross-player history.
- A coordination barrier must hold the simulation it protects. Without the hold
  the released history silently invalidates the agreement.
- A fixed roster names a deterministic coordinator. The lowest surviving slot
  removes the multi-proposer race without a clock.
- A new file in the addon is an API change for the package builder, the
  ownership probe and the lint caps. Check them in the same change.

## Outcome

- The coordinated drop ships with a scoped Godot tier. The pinned prepare,
  backfill, certificate and commit barrier and the live SignalFish and browser
  witnesses stay open in the follow-up issue.
- The retrospective is recorded here and in the issue comments. No skill,
  knowledge or research file changed: the lessons above are specific to this
  change and the repository's existing skills already cover the general rules.
