# Session 012 — Optional SignalFish membership

## Contract and priorities

The session advances [S1](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/35)
toward real multiplayer setup. Main started green at
`8014551c5a5176eac77ed1db8355ed3f65cc0b57`; no PR or worktree changes needed carrying forward.
The current playable example uses in-process delivery. Stable room identities,
configuration agreement and optional SDK installation are prerequisites for
real relay/WebRTC gameplay, which remain separate transport gates.

Hypothesis: every client can derive the same frozen slots from a differently
ordered UUID roster. Existing peer handshakes can reject disagreeing rosters,
configuration and session identity before gameplay. Transport plans must not
renumber slots or turn reconnection into rollback authority.

## Initial evidence

Both engine pins pass the unchanged 107-case unit baseline through the normal
runner and both deterministic repetition layers. Receipts:
`.cache/tests/session-012-baseline-4.3.json` and
`.cache/tests/session-012-baseline-4.7.2.json`.

The clean-install audit previously instantiated only its gameplay-reachable
scripts. A real unused adapter with a missing SDK preload still produced a
successful package receipt. The new regression fails before repair with
`AssertionError: ValueError not raised`; log:
`.cache/reference/session-012-package-red.log`.
The audit now loads every runtime GDScript in the addon-only installation.
This gap predates available history; there is no claimed passing pre-regression
revision. During development, the stronger audit also caught a real Godot 4.3
`PackedByteArray.sha256_buffer` parse error in the new membership code.

## Scope and delivery

The shipped seam configures the existing peer engine from an owned sorted UUID
roster. A roster/configuration digest binds full UUIDs and canonical protocol
bytes. Both core and SDK numeric identity collisions are refused. SDK plans
preserve server offerer roles and opaque generations, while lifecycle changes
require a new session. Delivery remains an application responsibility.

The first independent review reproduced a player-ID mix-up after a failed
connection initialization and an additive SDK `NewPeer` event. A separate agent
confirmed it on both pins, then added a guard before SDK mesh consumption. The
real SDK regression checks a matching retry, the differing player ID, no extra
connection creation, refused ingress and the persistent restart boundary.
The final fresh-context review found no actionable issues in all 13 candidate
files, with unchanged source inventories. It independently passed the nine seam
cases, real SDK witness, SDK-free package controls and process receipt controls
on both pins. Its broader unit attempts used a watchdog and are not counted as
passing evidence; the root runs the explicit CI budget below.

## Reproduction and evidence

For each version `4.3` and `4.7.2`, use the editor
`.cache/reference/editors/<version>/Godot_v<version>-stable_linux.arm64`:

```sh
python3 scripts/run_godot_tests.py --godot <editor> --timeout 120 --results <unit-receipt>
python3 scripts/run_godot_tests.py --godot <editor> --category determinism --results <determinism-receipt>
python3 scripts/reference/package_audit.py --godot <editor> --output <package-output>
python3 scripts/reference/test_package_audit.py --godot <editor> -v
python3 scripts/reference/signalfish_probe.py --godot <editor> --offline --output <sdk-output>
```

Focused membership receipts precede the additive event repair:
`.cache/tests/session-012-signalfish-unit-<version>.json` (eight cases, 740
assertions per in-process repetition). Both engine pins also pass three isolated
mutations at their declared digest, collision and lifecycle assertions. Commands
and retained outputs are in `.cache/session-012/mutate_membership.py` and
`.cache/session-012/*-red.log`. The additive-event red uses the pinned SDK
reproducer at `/tmp/adversarial-s1-gwhc88ek/probe.gd`; the committed regression is
`scripts/reference/signalfish_probe_new_peer.gd` and the final green receipts are
`.cache/reference/results/sdk-newpeer-green-<version>/signalfish-sdk.json`.

The SDK witness executes its actual public decoder, room/plan state, mesh
attachment and binary send/receive boundary. Exact bytes pass through the SDK
into 70 two-peer gameplay frames with confirmation through at least frame 68.
Source, executed-project and tool inventories are captured before execution and
checked before publishing success. Process controls reject failed exit,
incorrect UTF-8, timeout and changing source/tool evidence.

`make test-reference` passes 31 tests, with three engine controls explicitly
skipped in its no-engine invocation; those controls run through the commands
above. `make test-oracle` passes 52 tests. Source widths pass across 177 files
with the existing 180-character editor/formatter setting. Harness validation and
99 self-tests pass after canonical guidance curation.

Final root full-suite receipts are
`.cache/tests/session-012-final-full-<version>.json`: all 116 unit cases pass in
both fresh processes and each process's deterministic repetitions under the
explicit 120-second budget. Both determinism suites pass in
`.cache/tests/session-012-final-determinism-<version>.json`. Final SDK and clean
package receipts are under
`.cache/reference/results/session-012-final-{sdk,package}-<version>/`.
GDScript lint passes when the deliberate parse-error fixture is excluded.
The SDK witness uses the standard max-return lint exemption for sequential
fail-fast integration checks; both native witnesses were rerun afterward.

## Limits and follow-up

The SDK's public binary signal lacks server epoch metadata; application-supplied
connection identity is distinct from plan generation and rollback session ID.
Reconnection requires explicit restart. After relay selection, restoring the
mesh also requires restart; the SDK exposes no public plan-application call.
No public SDK events are synthesized to imitate restoration.

S1 remains open for its remaining integrated setup acceptance. Detailed transport
work stays in [S2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/36),
[S3](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/37),
[S4](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38) and
[S5](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/39).
The injected SDK wire witness does not prove a live server, WebRTC delivery,
real browser multiplayer or a supported release. Broader mesh fairness and
profile acceptance stay in P5.

Retrospective: [artifact](../.llm/retrospectives/2026-10-11-signalfish-membership.md).
Final current-head CI, feedback, merge and main-CI evidence belong in S1's issue
once delivery finishes. No pending check is represented as passing here.
