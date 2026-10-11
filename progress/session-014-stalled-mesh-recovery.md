# Session 014 — Recover stalled meshes and finish WebRTC delivery

## Contract and starting evidence

Continue the existing [PR #71](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/pull/71)
and repair gameplay-impacting [#73](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/73).
Keep one aggregate session PR. Start at `af1c8cd7113aa668a7e26e5424f7760256686de4`,
with a clean worktree and local/origin main at
`026590cd315c0e3e4e66929cb7da364020c532f2`.
Session start: 2026-10-11 21:02 UTC; finish before 23:02 UTC.

The previous turn made progress: committed observation diagnostics and label
budgets, plus a deterministic reproduction that changed the next action.
Current-head workflows `38172626915`, `38172626873` and `38172626868` all succeed.
That green snapshot does not discharge the known sampler defect in #72.
No live browser/probe process remains from the previous session. Its frozen
local receipt reports success, but binds only its recorded earlier sources.

Authenticated MCP enumerates the open PR; authenticated paginated GitHub REST
fills the search's twenty-result issue limit. #61's remaining work is an
upstream observation gate; its runtime floor repair already exists. #73 is the
ready production gameplay repair. Broader S3–S5 and advanced parity acceptance
remain tracked in their existing detailed task issues.

## Hypotheses and red evidence

The browser sampler records individual completions but applies watchdog samples
only after `Promise.all`. A timely frame from peer 0 at 15 seconds cannot update
its cached 20-second deadline while peer 1 legitimately completes at 25 seconds.
The repair must sample each completion against that peer's previous deadline,
then rearm current live deadlines without relaxing any bound.

The mesh loses its last status carrier after all input ACKs drain. With an
exhausted prediction window, it cannot submit a later frame to refresh stale
third-party gossip. Pinned Fortress automatically enables a bounded duplicate
acknowledged-input carrier when confirmation lies below actual receipt and the
window is exhausted. Preserve the conservative confirmation fold and all local
samples while porting that policy.

Specialized implementation agents own these independent repairs. Fresh-context
adversarial agents review only the relevant diff, acceptance contract and rubric.
Verification and delivery evidence follow below when obtained.

## Repairs and adversarial findings

The sampler applies each completion immediately with its own observation time.
It checks that peer's previous deadline before accepting progress, then rearms
the earliest live deadline. Four actual-module regressions fail against `af1c8cd`.
No known earlier passing implementation exists: this sampler shipped with the
batch barrier. The first cold review exposes same-turn sibling mutation after
rejection. Synchronous deactivation now covers timer, evaluation and validation
failure. The additional mutation fails; all twenty combined Node controls pass.
A second fresh pass runs nineteen watchdog tests and seventeen independent
probes, finding no remaining revisions. Evidence:
`.cache/session-014/sampler-evidence/`.

The peer session derives the exhausted-window gossip predicate from confirmed
and actual receipt folds. Each endpoint owns one last acknowledged packed input,
accounted in its configured byte budget, and can send one fresh status carrier
under strict keepalive/input/nudge clocks. Both public `poll` and identical stalled
`step` retries drive recovery. The original conservative confirmation algorithm
is unchanged. Standalone endpoints default to no automatic carrier.

The original runtime fails the production recovery schedule on Godot 4.7.2
without parser/runtime errors. Tests cover three/eight identities, grouped local
slots across three identities, original-input canonical replay, dropped/reordered
carriers, ACK drainage, missing receipt and healthy cessation. The two-identity
grouped fixture could not exercise third-party stale gossip; it was corrected
to six slots and three identities before final acceptance.

Fresh review reproduces two capacity deadlocks absent from the first regression:
`max_transitions = 1` cannot fit empty retry plus nudge traces, and enabled
`max_outbox = 1` cannot fit a nudge plus simultaneous quality report. A separate
agent verifies both RED on both engines, coalesces redundant empty work and
defers optional controls without consuming their clocks/tokens. Interruption
and timeout still execute. Matrix tests cover one/two packet capacities,
ordinary pending versus acknowledged carriers and same-clock drain service.
Both endpoint suites and deterministic suites pass through both repeat layers.
Evidence: `.cache/session-014/capacity/`.

The next cold pass reproduces first-carrier suppression at `INT64_MAX` on both
engines: subtracting an unset `last_nudge_us = -1` overflows. A separate agent
guards the sentinel before subtraction. RED/GREEN tables include ordinary time,
`INT64_MAX - 1`, `INT64_MAX`, full-outbox atomic refusal and same-clock retry.
The analogous new timer state is swept; required input/ACK history initializes
its ordinary-send clock. Evidence: `.cache/session-014/clock-boundary/`.

Exact endpoint byte budgets must now reserve one extra locally packed input
frame. The API guide and breaking changelog entry record that migration.
This follows the pinned source's exhausted-window arm; disconnect-agreement
nudges and voluntary idle-tail convergence remain outside this fixed-membership
acceptance. The stalled schedule is a source audit plus production Godot test,
not a separately executed Rust reproduction.

## Verification snapshot

The pre-sentinel candidate passes 157 unit cases and eight deterministic cases
on both engine pins, through fresh-process and in-process repetitions, seed1701.
It also passes all eight real browser labels and the 34-case upstream P2P
differential corpus (8,868 operations) on Godot 4.3. Those receipts are historical
after the boundary patch; final shipping executions are restarted below.

The initial root full-unit invocation used the runner's thirty-second default,
and both processes timed out. CI explicitly uses 120 seconds for this complete
suite; the corrected command passes. Focused hang controls remain unchanged.
No production or test expectation was changed to compensate.

## Final source verification

The frozen shipping runtime passes 157 unit cases and eight determinism cases
on Godot 4.3 and 4.7.2, twice in fresh processes and twice in process, seed 1701.
Final native receipts are `session-014-shipping-{unit,determinism}-<pin>.json`
under `.cache/tests/`. A supplemental source-bound rerun inventories the executed
source families before and after all four runs and hashes their receipts:
`.cache/session-014/native-source-bound.json`.

Both final package audits pass; their 41 archive members match the current addon.
The final real-browser receipt is
`.cache/session-014/webrtc-shipping/signalfish-webrtc.json`
(SHA-256 `39bb8226bd72a78510308443651b3f855e4362baebe70a82765e5d8379ebae0a`).
All eight clean, fault, corruption and default-option labels pass across both
engines. All 56 positive peers complete 40 frames, including 38 canonical and
37 active frames, confirm at least frame 38 and perform actual rollback loads.
Owned logs, current source/tool inventories and pinned server evidence are
independently checked. Temporary exports are deleted by the probe; their
recorded inventories remain historical digests rather than rehashable files.

Both final P2P receipts under
`.cache/reference/results/session-014-shipping-p2p-<pin>/receipt.json` pass
34 cases and 8,868 operations, with twice-executed upstream/Godot equality and
negative controls. These executions cover the existing parity corpus; the new
exhausted-window schedule remains the explicitly scoped source-audit regression.

The final gameplay adversarial pass finds no remaining revisions and passes
35 focused public cases on both pins. The sampler's final cold pass is also clean.
Reference controls pass 43 tests with three expected skips; oracle controls
pass 52; combined browser Node controls pass 20. Harness regeneration, lint and
99 self-tests pass. Changed GDScript files pass gdlint; source-width lint and
whitespace checks pass.

## Delivery gate

This aggregate change continues PR #71 and closes the accepted defects #72/#73.
Post-push current-head CI, complete paginated feedback, expected-head squash merge,
local main synchronization and merge-triggered main CI must all be verified.
The final authoritative delivery record will be posted to the linked issues,
so recording the merge does not create another source commit after validation.
Broader roadmap tasks remain in their existing detailed issues.

## Hosted representation-probe repair

The first pushed head `563a7cc` fails both general Godot CI jobs in
`ownership_probes.py` at the exact inventory gate. The staged native result
contains 73 complete cases while its expected inventory still contains 70.
The added endpoint cases were omitted from that probe's explicit inventory;
root unit success could not prove the independently staged probe remained valid.
The actual offline native/Web command reproduces the same failure.

The repair updates the selected inventory and stages the five stalled-gossip cases through
both native and exported Web hosts. Independent declaration/selection/preload
checks fail before repair and protect future copied-suite changes. The validator
continues requiring exact membership, repeats, assertion evidence and intended
negative-control failures. Evidence: `.cache/session-014/ownership-fix/`.
Both native/Web positive and alias-negative pairs now pass on both pins: 78 cases
per run, with exact exported/native equality. The seven focused Python tests and
45 reference controls pass (three expected skips). A fresh review independently
executes copied positive/negative native controls, verifies the 44-source preload
closure and reports no findings. Hosted rerun evidence follows in the linked issues.

## Hosted gameplay observation investigation

Transport jobs at `563a7cc` also fail clean eight-peer rooms after successful
two/four-peer rooms. Godot 4.7.2 retains cached frame 25 and Godot 4.3 frame 34.
All peers enter the following gameplay wait; no final-confirmation or SDK errors
appear. The next observation rounds start 213/233 milliseconds after their
earliest cached deadlines, then fire with no current-round evaluations.
These artifacts do not establish a false timeout or the stalled endpoint cause.
They lack timestamped gameplay endpoint snapshots and preceding round completions.
Artifact IDs: `11715943563` (4.7.2), `11716515157` (4.3), run `38176423915`.

Investigate whether the remaining all-pages barrier suppresses resampling a ready
peer behind a slower sibling. Preserve individual deadlines and obtain actual-module
RED/GREEN evidence before any sampling repair. Add bounded gameplay-wait snapshots
to distinguish transport state from renderer/observation delay on a rerun.

The actual-module independent-observation reproduction confirms a second batch
barrier defect at `563a7cc`: peer 0 advances every second and completes at
19,000 ms; peer 1 completes its second evaluation at 19,900 ms, before its own
20,000-ms deadline. The old coordinator prevents peer 0's next observation
until the sibling finishes, then rejects at 20,150 ms after its shared pause.
The repaired coordinator finishes at 19,900 ms. This establishes an algorithm
defect without retrospectively attributing the hosted artifacts.

Per-page observation loops now keep one evaluation in flight each and preserve
the 250-ms cadence. The earliest individual deadline remains armed during
evaluations and pauses. Accepted last samples and attempt/completion clocks
remain bounded diagnostics; gameplay receipt changes do not reset frame clocks.
Completed peers remain observed for terminal regression until global completion.
All 23 combined Node controls pass; three new controls fail against `563a7cc`.
Evidence: `.cache/session-014/sampler-evidence/independent-commands.json`.

The fresh independent-loop review reproduces a pause-rejection ordering bug:
`await pause(index)` rejects to a detached observer catch one microtask later.
A queued sibling can sample and rearm in that gap, or complete the operation
before the earlier failure is processed. The standalone reproduction shows
both late mutation and false acceptance; the failure must deactivate locally
in the pause rejection continuation. A separate agent owns its RED/GREEN repair.
The first restarted browser run is interrupted before changing its frozen
source. Earlier browser receipts remain historical for their recorded helpers;
final current-source execution restarts after this review finding is repaired.

The pause repair catches rejection in the local await continuation. The old
completed-peer schedule accepts despite an earlier pause failure; repaired
execution rejects that failure with zero late samples and unchanged timer arms.
The extended failure-path table covers timeout, evaluation, validation and pause.
All 23 watchdog cases pass. Evidence remains with the independent sampler logs.

Gameplay wait diagnostics now start after five seconds, repeat every five
seconds and stop at six snapshots per wait. Final-confirmation diagnostics
remain immediate. Both inherited actual-host clock tests pass, including exact
boundaries, reset, actual endpoint metadata, truthful elapsed time and payload
exclusion. A fresh reviewer repeats both engine tests and finds no revisions.
RED/GREEN logs: `.cache/session-014/wait-diagnostics/`. The final browser matrix
is restarted at `.cache/session-014/webrtc-independent-final/` after source freeze.

The restarted final full browser execution exits zero. Receipt
`.cache/session-014/webrtc-independent-final/signalfish-webrtc.json` passes all
eight labels across both pins. Its SHA-256 is `4b181a9aad6bf1c68516362b28a4903bccb87cc1515bec143ad57e0b440d73ea`.
The last fresh sampler review passes all 23 tests plus ten independent
three-page schedules and a late-callback probe, with no actionable findings.
Combined Node controls total 24; reference controls total 45, with three
expected skips. Harness lint, 99 self-tests, source lint and whitespace checks
pass. Production runtime, native/P2P and package source bindings remain unchanged
from the verified gameplay candidate. Final hosted gates must still pass.
