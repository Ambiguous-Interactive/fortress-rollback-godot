# Session 008 — Protocol messages and playable offline example

Goal: advance user-facing gameplay integration and the fixed-membership P2P
milestone in PLAN.md. Base: `345b287854baf92334a346720b7cbf4e3923456d`.
Branch: `session-008-protocol-and-offline-example`.
The session PR and linked issues own final head, feedback, merge and main-CI evidence.

## Starting evidence and chosen work

Clean main matched the previous squash merge. There were no open/draft PRs.
All three main workflows succeeded: 38094395884, 38094395894 and 38094395883.
The live issue audit prioritized #30's missing packet boundary for P2P and
#41's missing executable client example. These are new addon/user capabilities;
CI and issue closure alone do not establish gameplay progress.

## Bounded protocol codec

The [wire contract and source audit](../docs/protocol.md) specifies eleven
fixed-membership messages, complete slot-status epochs, ACKs, configuration,
floor rounds, identities and unsigned wide values. Independent byte goldens
and semantic records come from a separate fixed-width Python layout.
The production decoder validates packet caps before copies, variable bounds
before collections, complete input geometry and exact payload consumption.
Configuration agreement preserves neutral inputs, ordered roster and game formats.
Semantic compatibility remains separate from the header's layout version.
The projection retains opaque wide bytes as hex and owns nested output records.

Hypothesis: malicious prefixes/counts and changed frame ordering cannot cross
the byte boundary as plausible complete messages. Eight native/Web cases cover
all eleven kinds, every truncation, trailing bytes, negotiated identities,
maximum domains, wrong types, ownership, exact projections and 512 seeded
hostile packet mutations per run. Seed: 1701.
An isolated i16-bound mutant accepted 32768; the semantics case failed exactly
`reject i16 overflow` twice, with exit 1 and no engine error.
Evidence: `.cache/tests/codec-mutation-red.log`.

`python3 scripts/reference/ownership_probes.py --offline --web` passes on
Godot 4.3 and 4.7.2 with Chromium 141.0.7390.37. All four matrices include
16 cases with repeated execution: native/Web positive and the existing exact
ownership alias negative control. Source/artifact hashes are recorded in
`.cache/reference/results/ownership.json`. The suite is already in the
minimum/current CI browser gate; no separate duplicate launcher was added.
Fresh adversarial review found no actionable codec defects and independently
probed maximum player, sample, count, frame and packet geometries.

## Playable offline example

The [quick start](../docs/offline-example.md) runs two players with WASD/arrows,
restart, frame/error diagnostics and presentation interpolation. The example
uses the shipped driver, a 136-byte integer snapshot, seeded PRNG and delayed
pulse records. Cosmetic presentation reconciles only after the complete batch.
Sixteen unique pulses survive 160 frames of repeated eight-frame rewinds;
every corrected canonical snapshot equals uninterrupted simulation.
All sixteen control combinations and arena limits have independent expectations.
PRNG and pending-event omissions fail through production sync-test, localized
to saved frames 21 and 4 respectively. The omitted fields are hidden in each
mutant's snapshot, so the first visible differences follow pulse scheduling
at frame 20 and pulse completion at frame 3. No Rust, test runner or networking
service is imported by the scene.

Two independent reviews ran clean addon/example projects on both native pins.
Physical D input moved player 1; R restarted frame and position. Clean scenes
ran through 180 iterations without application errors. A real minimum-engine
Mesa/Xvfb preview at frame 120 was visually inspected and saved in
[the guide](../docs/offline-example.png).

## Review repair: atomic restore

The first example reviewer reproduced a trailing-byte snapshot that returned
true from load_state and changed x from 120 to 200. Session completion already
rejected trailing bytes, but the callback had applied malformed state first.
The new regression failed before repair; receipt:
`.cache/tests/session-008-trailing-red.json`. The failure reports byte 24 and
the rejected snapshot's changed canonical bytes, without parser errors.
There is no pre-regression main example: this is a defect in the initial candidate.

`FortressSnapshotReader.is_complete()` now exposes a read-only check for live,
error-free, complete consumption. The example checks it before publishing state.
The sweep updates driver/reference/package callbacks and production oracle
request replay; expert completion and view expiry retain their original ownership.
Data-driven cases reject corrupt, truncated and oversized snapshots atomically.
Reader tests cover unread, fully read, empty, errored and expired views.
Green receipt: `.cache/tests/session-008-trailing-green.json`.
A fresh adversarial review independently reran both engine suites and clean
installs and reported no remaining defects.

## Validation and delivery scope

Full unit suites pass on both native pins: 46 cases, repeated in-process and
fresh processes. Native determinism suites also pass. Applicable oracle reruns
compare all 42 actual Rust/production Godot scenarios and persistent controls;
receipts: `.cache/reference/results/session-008-oracle-{4.3,4.7.2}/receipt.json`.
Addon-only package audits pass on both pins. Final candidate CI repeats these gates.

`make lint-source`, GDScript lint, `make llm-index`, `make lint-llm`,
`make test-llm`, `make test-reference` and `make test-oracle` pass.
Editor/formatter maximum source width remains 180 characters.
Current-head CI, complete feedback scans, squash merge and merge-triggered main
CI remain delivery gates, recorded in the PR/linked issues after completion.

Codec bytes do not establish P2P handshake, input exchange or recovery parity.
#31/#32/#59 own endpoint/oracle integration; #30 retains its full acceptance gate.
#41 retains the real browser multiplayer example, SignalFish setup and supported
matrix. Existing detailed issues own these follow-ups; no duplicate backlog exists.
Compression, spectators, coordinated drop and hot join remain individually gated.

Retrospective: [artifact](../.llm/retrospectives/2026-10-10-protocol-and-offline-example.md).
Retro: findings-acted.
