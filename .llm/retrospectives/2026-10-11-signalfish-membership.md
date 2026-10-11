# Retrospective: 2026-10-11 SignalFish membership and binary relay

## Work Under Review

- Scope: optional SDK-independent UUID membership and plan adapter, pinned SDK
  integration witness, package clean-load controls and CI wiring, extended with
  the production bounded binary relay adapter and 2/4/8-player SDK witnesses.
  The initial S1 review
  snapshot `/tmp/session-012-review-current.diff` contains 11 changed files;
  documentation and harness curation continue outside that snapshot.
- Trigger: new subsystem, external SDK archaeology, package-audit incident and
  an independent review finding requiring repair.
- Evidence: [session record](../../progress/session-012-signalfish-membership.md),
  actual source inspection and the local receipts below. Receipts identify
  their engine and pin; they establish local Linux ARM64 execution only.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Loading gameplay-reachable code does not prove optional SDK independence. Every shipped runtime script must load without the SDK. | technique | `scripts/reference/test_package_audit.py:62` injects an unused missing-SDK preload; `.cache/reference/session-012-package-red.log` reports `AssertionError: ValueError not raised`. |
| 2 | Validating a session plan does not fence every SDK authority path. Additive peer callbacks can create connections outside the approved roster, including after partial initialization failure. | technique | Pinned SDK `addons/signal_fish/webrtc/sf_webrtc_mesh.gd:269` calls `_open_peer` from `new_peer` without roster validation; `:360` returns after initialization failure. Candidate adapter `:32` subscribes to plans before mesh attachment but originally omitted `new_peer`. |
| 3 | Independent identity goldens and targeted mutations expose plausible self-consistent mistakes. | technique, reinforce | `tests/unit/test_signalfish_membership.gd:62` has an independent Python SHA256 roster/config golden; `:77` has a known FNV collision fixture. `.cache/session-012/mutate_membership.py` separately removes roster hashing, numeric collision rejection and lifetime fencing. |
| 4 | Real SDK integration can be deterministic without a live server, but its transport boundary must be named precisely. | technique, reinforce | `.cache/reference/results/sdk-final-4.3/signalfish-sdk.json` and `sdk-final-4.7.2/signalfish-sdk.json` report 70 confirmed two-peer steps through the pinned decoder and public binary transport with an injected wire. |
| 5 | A binary sender signal without server epoch metadata cannot establish transport-incarnation attribution. | boundary | Existing SDK public binary attribution and [membership limits](../../docs/signalfish-membership.md); the owning networking skill preserves this limit. |
| 6 | Atomic drained-batch acceptance and FIFO retry preserve ownership under bounded relay pressure. | technique | `signalfish_relay.gd:75` validates the complete batch before append; `:145` removes the FIFO head only after successful SDK send. Relay pressure/atomic cases and busy-head-loss mutations exercise these boundaries. |
| 7 | Broadcast delivery counts cannot establish correct multiplayer state; compare each peer’s corrected confirmed prefix with varied inputs. | technique | `scripts/reference/signalfish_probe_relay.gd` records nonzero comparisons for 2/4/8-player scenarios through production relay and the real SDK; both final relay receipts total 532 comparisons. |

| 8 | Late SDK failure signals must prevent witness success even when gameplay comparisons pass. | technique | Actual SDK protocol-error red log and second omitted-signal control are recorded in Native Witness Findings below. |

| 9 | Revalidate current SDK authority before consuming queued bytes; lifecycle signals can lag actual state changes. | technique | Seven actual-decoder lifetime cases fail before adapter repair on both pins and pass afterward; see Final Lifetime and Metadata Findings. |
| 10 | Consumers must require complete current build provenance, not merely matching source/executable bytes. | technique | Fresh review reproduced four accepted omissions; repaired validation requires nine known inputs and actual log/tool identities, with six control methods passing. |

## Evidence Provenance and Boundaries

The unchanged baseline receipts `.cache/tests/session-012-baseline-4.3.json`
and `session-012-baseline-4.7.2.json` pass 107 cases before the implementation.
The focused receipts `.cache/tests/session-012-signalfish-unit-4.3.json` and
`session-012-signalfish-unit-4.7.2.json` pass eight cases with 740 assertions per
in-process run, repeated inside each of two fresh processes. These receipts
precede the independent additive-peer finding and cannot certify its repair.

Each of the three mutants fails at its named assertion on both engine pins.
The collision mutant also prints repeat-divergence because failed assertions
contain distinct allocated-object IDs; its direct rejection/failure-state
assertions establish the intended failure independently of that extra error.
These are new-feature negative controls, not claims of historical regression
triple proof.

Package controls pass after repair in
`.cache/reference/session-012-package-green-4.3.log` and
`session-012-package-green-4.7.2.log`. The clean-load gap predates available
history: the red log proves the old audit accepted the defect, without claiming
a passing pre-regression revision. The stronger audit also exposed an actual
Godot 4.3 parse failure in the candidate's original hashing API, recorded in
the session record.

SDK receipts pin revision `db7d30f228d8d564adcb2eb38d5983bf6b9877ac` and archive
digest `0854f8c778a118defe95bd8887e227c8bc8c194c54d2e501c6d74094fa43ec12`.
The probe inventory checks executed addon/probe sources before and after use
(`scripts/reference/signalfish_probe.py:67`). The injected witness exercises
genuine SDK decoding, state, mesh attachment, signals and binary send/receive.
It does not prove a live SignalFish server, real WebRTC channels, browser
behavior or reconnect recovery. S2 now adds the production binary relay adapter;
its evidence is recorded separately below.

## S2 Evidence and Rework

Both `.cache/tests/session-012-relay-unit-<version>.json` receipts pass eight
cases, 96 assertions per in-process repetition, and both fresh processes.
The three named controls in `.cache/session-012/mutate_relay.py` run on each
engine: `busy-head-loss`, `sender-attribution` and `recipient-filter`. Each
retained `-red.log` contains its intended assertion failure rather than a
parse failure. These six negative controls protect actual queue retention,
SDK sender agreement and addressed broadcast delivery.

Both `.cache/reference/results/sdk-relay-final-<version>/signalfish-sdk.json`
receipts pass. Production relay code executes with the pinned SDK through
its real binary API and decoder using injected wire delivery. Each scenario
submits 40 frames with varied inputs; corrected confirmed-prefix comparisons
are 76 for two players, 152 for four and 304 for eight. Each engine run totals
532 comparisons and 37,546 broadcast deliveries. Counts apply separately to
each pin. Source, executed-project and tool inventories bind these receipts
only to their executed snapshots.

At this curation checkpoint the S2 full receipts
`.cache/tests/session-012-relay-full-<version>.json` report `passed: false`.
Both engines complete all 124 cases without assertion failures, but the relay
pressure case has 16 assertions in process one and 17 in process two.
Root and fresh review identified a send-count assertion and guarded indexing
added while those processes ran; production runtime was unchanged. The runner
correctly rejected the changing assertion inventory. Coordinate a source freeze
across reviewers and witnesses before final fresh-process verification, as the
existing testing skill already requires. The final candidate reruns are
`.cache/tests/session-012-relay-frozen-full-<version>.json`; both pass all 124
cases through both repetition layers with the explicit 120-second budget.
The earlier 116-case S1 pass remains historical evidence, not S2 validation.
S2 independent review found no actionable issues; focused cases and source-bound
SDK witnesses pass on both pins, plus 66,264 envelope truncation checks on 4.3.
Native WebSocket gameplay positives cover 2/4/8 on both pins; witness failures
found afterward and the remaining final checks are recorded below.

## Native Witness Findings

The server builder now produces an executable-bound receipt after verifying
fresh pinned source, cleaning the server package and compiling with locked
commands. `.cache/reference/results/session-012-native-server-build/build-receipt.json`
passes for server revision `9c2fb8fa635a69241b8ccf38be651d561fef7434`.
`.cache/session-012/server-build-source-control.json` records rejection of a
source mismatch with exit 1 and no passing replacement receipt. Cached raw
crate archives and indexes permit offline preparation while source trees are
unpacked and verified afresh. This reinforces existing testing guidance rather
than adding a duplicate build-provenance rule.

Actual native loopback WebSocket scenarios exercise the real SDK, pinned server
and production relay for 2/4/8 players on both engine pins: 40 submitted frames
per scenario, 532 canonical comparisons and 35,260 binary receives per run.
They establish a separate transport boundary from injected-wire witnesses.

The first fresh witness review found that three late SDK error types could be
latched after the last wait without preventing success. An actual SDK protocol
error still emitted a passing result in
`.cache/session-012/live-relay/late-red-43.log`. The repair added final checks
and actual protocol/server/room-join error controls; both
`.cache/session-012/live-relay/late-fixed-<version>/signalfish-live.json`
receipts record rejection of those three controls. A second review then
emitted another actual SDK failure signal and reproduced exit 0 plus success
in `.cache/reference/results/native-final-review-auth-control.json`.

The durable lesson is to inventory every applicable SDK failure signal, latch
all failures, and recheck after final event processing immediately before
success publication. Prove each signal with an actual final-boundary negative
control; correct final game state alone cannot establish a healthy run.
Root updated this procedure at its single home in the
[testing skill](../skills/testing/SKILL.md). The native probe signal inventory,
sixteen actual late-event controls now pass on both pins in the complete native
receipts. Final acceptance still needs metadata-bound reruns described below.
Completed `.cache/reference/results/session-012-final-native-relay-<version>/`
receipts predate the second review repair; their positive scenarios and three
controls are historical evidence, not final candidate acceptance.

## Final Lifetime and Metadata Findings

Actual SDK decoding can change connection/authentication/room state before a
later signal is observed. The production adapter now checks public current
connection, authentication, player and room identity before processing queued
bytes, and fences spectator replacement and known-member reconnection.
Seven actual-decoder cases fail against the old adapter on both engine pins in
`.cache/reference/results/sdk-lifetime-red-<version>/`, then pass in
`sdk-lifetime-green-<version>/`. Event subscriptions alone were insufficient;
queued work must revalidate the SDK's current authority at consumption.

Both `.cache/tests/session-012-complete-full-<version>.json` receipts pass all
125 unit cases through both repetition layers. Both complete native receipts
under `.cache/reference/results/session-012-complete-native-<version>/` pass
2/4/8-player gameplay and sixteen actual late SDK event controls. Positive
runs retain 532 comparisons and 35,260 binary receives per engine.

The last fresh review found incomplete build metadata could still be accepted;
the evaluator reproduced four omitted-field variants. Matching source and
executable hashes do not establish the complete build procedure. The launcher
now validates the exact nine current inputs, builder/archive identities,
actual known build-log bytes and compiler-tool hashes. Six methods in
`scripts/reference/test_signalfish_live_probe.py` pass after repair, covering
metadata omissions and build-log handling alongside native result controls.
This applies the existing inventory/provenance guidance at the consumer;
a producer writing rich metadata does not prove consumers require it.

The complete native positives predate this stricter launcher. A fresh builder
run and `.cache/reference/results/session-012-shipping-native-<version>/`
receipts must bind the final candidate, followed by the last independent review
and current-head CI. Those outcomes remain pending and are not inferred from
historical positives.

## Actions Taken

| # | Action | Canonical home | Verification |
| --- | --- | --- | --- |
| 1 | Strengthened the existing optional-SDK procedure with an unused missing-import control. | [networking transport](../skills/networking-transport/SKILL.md) | Local red/green package controls above; final harness checks required below. |
| 2 | Replaced plan-only wording with auditing every mesh-authority path, explicitly additive peers after partial initialization failure. | Same networking skill | SDK source inspection above; implementation regression repair and final reruns are separate delivery requirements. |
| 3 | Kept genuine SDK witness, identity comparison, lifetime fencing and epoch limits in that single existing procedure. | Same networking skill | Existing focused, mutation and SDK receipts above establish their stated boundaries. |
| 4 | Recorded membership and implemented binary relay while retaining the distinct WebRTC/browser release gates. | [context](../context.md) | Checked against production adapter and actual SDK receipt boundaries. |
| 5 | Added drained-batch ownership, exact FIFO retry and corrected confirmed-state verification to existing networking guidance. | Same networking skill, updated by root | Relay unit/SDK witnesses and six negative controls above; final harness checks pending after extension. |
| 6 | Added complete SDK failure-signal capture, final-drain checks and actual signal controls. | [testing](../skills/testing/SKILL.md), updated by root | Two independent late-signal reproductions; sixteen-control complete native receipts pass, final metadata-bound reruns pending. |

## Prune Ledger

- Searched existing skills, knowledge and retrospectives before writing; no
  competing optional-SDK procedure existed. Updated the networking skill rather
  than creating another skill or a duplicate knowledge entry.
- Fixed plan-only advice at its authoritative source. Replaced obsolete
  membership-only/no-byte-adapter claims with the implemented relay scope.
  Retained the live transport/browser release limits and the distinct gameplay versus diagnostic
  trace guidance; this session did not invalidate them.
- Twelve retrospective files existed before this artifact, below the current
  consolidation threshold. No unrelated retirement was justified.
- Verify-on-touch: root passed `make llm-index`, `make lint-llm` and
  `make test-llm` after S1 curation, plus `make lint-source`. The S2 extension
  and native-witness extensions require these checks again after final edits.
  Corrected obsolete native-proof-pending wording to actual loopback evidence,
  while retaining pending witness-repair and browser/WebRTC limits.

## Outcome

- State: `findings-acted` — durable guidance corrected and evidence boundaries
  recorded. This state describes curation, not release or merge status.
- Follow-ups: the separate evaluator completed the additive-peer repair with
  real SDK matching-retry and identity-mapping regression controls on both pins.
  A final fresh-context review passed the nine seam cases, SDK witness and package
  controls on both pins with no findings or source drift. Before S2, root
  passed all 116 unit cases and determinism suites on both pins with
  the explicit 120-second CI budget, then reran SDK/package witnesses. Root records
  current-head CI, feedback and delivery in
  the linked S1 and S2 issues. S2 final delivery and
  current-head CI remain pending at this checkpoint. Complete 125-case suites
  pass on both pins. Native gameplay and sixteen late-event controls pass on
  both pins, but their receipts predate the last build-metadata repair. Fresh
  builder/shipping-native receipts and the last independent review are pending.
  Browser and WebRTC gates remain separate roadmap work; no pending check is
  claimed passed here.

Retro: findings-acted

## Receive-pressure follow-through

A cold review reproduced recoverable peer outbox pressure with two actual input
packets. The uncommitted second input disappeared and the relay became terminal,
although draining the ACK and directly retrying that payload succeeded. Focused
red: `.cache/session-012/relay-pressure-red-4.7.2.json`. Preserve the receive head
and its owned token until acceptance, distinguish committed terminal state from
the returned pressure code, and keep bounded outbound service available while
receives wait. This procedure belongs in the existing networking skill. Root is
running final source-bound checks and a fresh review after the repair freezes.

Final receive-pressure regressions pass all three cases on both engines with
87 assertions per repetition; old-code controls fail recoverable/handshake cases
on both pins and preserve the terminal control. Both final full-suite receipts
`.cache/tests/session-012-release-full-<version>.json` pass 128 cases. Final SDK
and clean SDK-free packaging receipts pass. The rebuilt strict-metadata launcher
also passed all sixteen native controls before the receive-pressure repair;
final source-bound release-native receipts now pass 2/4/8 gameplay and all sixteen
controls on both pins. The final fresh review covers all seventeen technical
files, finds no actionable defects and verifies unchanged source hashes.
Source width/GDScript lint, 37 reference tests and final harness validation pass.
Delivery and merge-triggered main CI will be recorded in the linked issues.
