# Retrospective: 2026-10-11 peer lifecycle

## Work Under Review

Fresh-context curation of the P4 runtime, actual-source oracle, example and
validation changes against `9f70110eb91cef8909d0f8acb85901c54304c9f0`.
`git diff 9f70110 --stat` reported 26 tracked files, 754 insertions and
84 deletions at curation intake; new candidate files were inspected separately.
Large change, new capability and multiple repair incidents require this loop.
Author rationale was excluded. Evidence comprised the diff, product contracts,
fresh review probes and actual structured red/green process transcripts.

Search before writing: `rg -n 'terminal|overflow|GOODBYE|zero|prediction|negative control|lifecycle|null' .llm`.
Existing networking, testing and rollback skills already own these procedures.
Earlier handshake and input-exchange retrospectives cover nullable ingress,
semantic mutations and confirmation timing; this artifact adds only new edges.
No new skill, tooling, operational fact or duplicate product guide was needed.

## Findings

| # | Episode and evidence | Durable technique |
| --- | --- | --- |
| 1 | Session `review.md:9–12,21`: first-only `_fatal_event` hides timeout. | Fill reserve before later fatal events; retain each remote cause. |
| 2 | Protocol `review.md:10–14`: resumed state commits with only `input_failed`. | Check state/event agreement on partial callback failure. |
| 3 | Oracle `report.md:4`: `#[serde(default)] lifecycle:Option<Lifecycle>` aliases null. | Test omitted and null objects in each executable. |
| 4 | Oracle `report.md:7`: `record.pop('extension_events', None)` hides invented suffixes. | Validate exact excluded inventories first. |
| 5 | Oracle `report.md:10`: `diagnostic = str(error)` learns an early rejection. | Specify diagnostics independently; reach the intended boundary. |
| 6 | Oracle `report.md:13`: equality-only profile passes without named observations. | Require nonzero named observations and controls. |
| 7 | Example `review.md:3`: `(x[0] + 1) % 480` stores invalid x=461. | Keep divergence serializable; force edge restore and real desync. |
| 8 | Zero-window source audit: 14 ADVANCE, zero SAVE and checksum packets. | Audit actual callbacks; identify capture extensions. |
| 9 | Final session probe `probes.gd:17–31`: capacity 1 never reports actual divergence. | Verify comparison handoff at accepted minima through eviction. |
| 10 | Malformed extension objects and unchecked nested inventories produced observer tracebacks. | Validate shape and inventory before consuming nested fields. |
| 11 | Named standalone corpus checks skipped evidence without `--expected`. | Exercise standalone option dependencies through subprocesses. |
| 12 | Timeout projection consumed the final event instead of the identified terminal. | Test valid-shaped extra events against exact ordered comparison. |
| 13 | Explicit misspelled/empty corpus names bypassed the required inventory. | Reject unknown explicit acceptance names; keep custom profiles separate. |
| 14 | Source quality projection used `as_u64` for unsigned-128 ping/pong fields. | Exercise valid upper-bound messages through the real standalone decoder. |
| 15 | Named lifecycle controls consumed metrics from an input-only profile. | Validate option prerequisites before invoking specialized consumers. |
| 16 | CI job 114373774083 stopped both full-suite processes at the default 30-second watchdog. | Verify the actual CI command and its declared full-suite budget. |
| 17 | Feedback repair `red.json`: local close committed PROTOCOL_FAILED instead of TERMINATED. | Distinguish intentional closure from genuine publication failure before first-reason-wins termination. |
| 18 | The same red transcript returned NETWORK_BACKPRESSURE after status committed PROTOCOL_FAILED. | Require the terminating operation's error to agree with terminal status; retain healthy retry pressure. |
| 19 | Cold review compared new guide wording with `peer_session.gd:168–170`: later calls return generic TERMINATED. | Scope API statements to the operation that encounters failure; preserve later-call contracts. |
| 20 | Cold pressure/matrix logs: close and timeout invented event overflow under packet/transition pressure with free event capacity. | Separate terminal transmission pressure from genuine diagnostic capacity failure. |
| 21 | Cold ingress logs: dictionary/bool options raise SCRIPT ERROR and return apparent configure OK. | Guard Variant types before entering typed validators. |
| 22 | `session-011-closure-full-{4.3,4.7.2}.json` records mixed process exits [1,0]. | Finalize fixtures before declaring verification frozen; concurrent passes cannot establish repeatability. |

Review paths are `.cache/session-011/{session-review,protocol-final-review,
oracle-review,example-review}/`; line numbers refer to their captured reports.
These local artifacts preserve episode evidence, not reusable instructions.

Finding 8 was independently counted from
`.cache/session-011/max0-checksum-source.json` using:

```python
import collections, json
trace = json.load(open('.cache/session-011/max0-checksum-source.json'))
print(collections.Counter(r['kind'] for op in trace['records'] for r in op['requests']))
print(collections.Counter(p['semantic']['kind'] for p in trace['packets']))
```

Observed outputs: `Counter({'advance': 14})` and
`Counter({'input': 14, 'input_ack': 14})`; `complete` is true.
The original scenario is retained in `max0-checksum-scenario.json`.
[Peer lifecycle](../../docs/peer-lifecycle.md), lines 48–53, explicitly describes
additional Godot SAVE capture as an extension outside source callback parity.
The source audit alone cannot prove that extension's runtime correctness.

## Actions Taken

| Findings | Canonical action | Home |
| --- | --- | --- |
| 1–2 | Add fatal reserve sequencing and commit/event error-path audit procedures. | [Networking transport](../skills/networking-transport/SKILL.md) |
| 3–6 | Extend existing schema/control guidance; require exact excluded inventories and nonvacuous named cases. | [Testing](../skills/testing/SKILL.md) |
| 7 | Require bounded divergence and actual restore before accepting a desync demo. | Testing skill |
| 8 | Audit low-window callbacks; label capture extensions. | [Rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) |
| 9 | Strengthen accepted-minimum retention handoff and nonzero comparison requirements. | Networking and testing skills |
| 10–15 | Apply existing width, strict-ingress, exact-order and nonvacuous rules to standalone validator paths. | Testing skill; no duplicate instructions added |
| 16 | Require the full CI entry point and an evidence-based per-process watchdog. | Testing skill and CI workflow |
| 17–21 | Extend error-path tests across pressure domains and malformed option ingress; qualify later-call docs. | Existing networking/API guidance; no duplicate rule |
| 22 | Require finalized fixtures before declaring verification frozen; preserve and rerun affected evidence. | Testing skill |

Product changes are owned by the runtime/oracle authors. Curation neither edits
them nor treats a review finding as proof of its eventual repair.

## Executed Evidence and Limits

Actual commands and results are retained inside structured transcripts' `runs`.
For reproduction, `<editor>` selects the pinned 4.3 or 4.7.2 ARM64 binary in
`.cache/reference/editors/<version>/`:

```sh
<editor> --headless --path /workspaces/fortress-rollback-godot \
  --script res://tests/runner/run_tests.gd -- --category unit --seed 1701 \
  --suite res://tests/unit/test_endpoint_lifecycle.gd --filter retention_failure
```

`endpoint-review/resume-red.json`: exit 1, count 1, two deterministic runs fail
“resume precedes failure without success event”. The green command removes the
filter and adds `--suite res://tests/unit/test_input_endpoint.gd`.
`resume-green-{4.3,4.7.2}.json`: each passed, both fresh processes exit 0,
complete result, count 15. Fresh protocol clean review `receipt.json` separately
records 15 suite cases and 155 probe checks on each engine, all exit 0.

```sh
<editor> --headless --path /workspaces/fortress-rollback-godot \
  --script res://tests/runner/run_tests.gd -- --category unit --seed 1701 \
  --suite res://tests/unit/test_peer_example_lifecycle.gd --filter game_desync
```

`.cache/tests/session-011-example-boundary-red.json`: exit 1, count 1,
two runs fail “wrong game rules produce a real desync event”. Green commands
remove the filter and add `--suite res://tests/unit/test_peer_example.gd`.
`example-repair/green-{4.3,4.7.2}.json`: each passed, both fresh processes exit 0,
complete result, count 7. Example final review `review.md:8–12` separately
records both-engine suites, 2200-tick hostile input probe, clean-addon audits and
70-case ownership inventories. Browser execution was not repeated by that review.

`overflow-repair/red.json` runs the same runner with
`--suite res://tests/unit/test_peer_lifecycle.gd --filter event_capacity`.
Exit 1 and both repetitions show missing owned remote timeout causes.
At curation intake, its green files contained `failure: in_progress`.
Oracle review records 16 successful scenario comparisons and accepted mutants;
those comparisons cannot establish the repaired observer's final correctness.
Final full runtime/oracle receipts, browser gates and current-head delivery remain
session-owner work. A local scoped green result is not a final session pass.

A subsequent fresh session review added finding 9 after initial curation.
`.cache/session-011/session-final-review/probes.gd:17–19` sets
`max_checksum_frames = 1`, checksum interval 1 and an actual initial accumulator
mismatch. Lines 21–31 run 30 ticks and count actual desync events.
`probes43.log` and `probes472.log` each record `desyncs:0`, `diverged:true`,
`state:running`; window 0 reaches frame 15 and window 8 reaches frame 30.
These are accepted configurations that advance but omit mismatch detection.

At review capture, `peer_checksums.gd:56–59` quotes
`_local.erase(oldest[0])` before `compare`; lines 77–81 advance the remote
retention floor and erase reports before strict eligibility at lines 89–91.
The durable procedure checks the entire send/eligibility/eviction handoff,
including nonzero comparisons and real mismatch at the lowest accepted capacity.
Capacity-2 healthy probes do not establish capacity-1 comparison correctness.
Repair and final green verification for finding 9 were pending at capture.

Subsequent repair receipts in `minimum-checksum-repair/green-{4.3,4.7.2}.json`
each pass 25 focused cases in two fresh processes. They require actual equal
comparisons and real divergence at capacity one in lockstep and prediction,
including delayed/reordered reports and a full control outbox. The cold core
review independently passes an eight-peer reversed-delivery probe on both pins.

`oracle-structured-repair/{regressions-red,consumers-red}.log` records actual
traceback exit 1 for malformed nested ingress and exit 0 for named checks without
source evidence. `full-contracts-green.log` passes 49 oracle unit tests.
`reproduction-green.json` records structured exit 2 for the original malformed
extension and both shortened named traces; the valid source comparison still
passes. These exercise existing schema and coverage rules at standalone ingress.

`oracle-cli-repair/red.log` records a timeout suffix traceback and false success
for misspelled/empty corpus names. Its `green.log` passes all 21 P2P contract
tests; the original generated timeout reproduction now rejects at operation 3
with an events mismatch. Existing ordering and named-coverage guidance applies;
no additional overlapping skill rule was added.

`oracle-wide-repair/` retains the actual pre-fix standalone ping rejection,
the final Rust build and six positive wide-value plus twelve separate rejection
controls. `wide-controls-green.json` and `cold-original-green.json` show
successful production decoding; `p3-cold-original-green.log` shows structured
rejection of a named lifecycle check on an input-only profile.
`python-final-green.log` passes all 52 oracle unit tests.

`ci-red/tests/runner-4.3.json` preserves both actual 30-second watchdog failures,
with no completed suite marker. Earlier local verification used 300 seconds
and did not exercise CI's default budget. The workflow now explicitly uses
120 seconds for the complete suite; focused deliberate hang controls retain
their short limits. `session-011-feedback-full-{4.3,4.7.2}.json` each passes
107 cases in two completed fresh processes using that budget. Six real runner
controls per pin still pass; actual CI remains a required delivery gate.

`feedback-repair/red.json` records two completed repetitions of both reason
failures. `green-{4.3,4.7.2}.json` each passes 25 focused cases in two fresh
processes, each repeated twice. Real full-outbox probes distinguish terminal
timeout from recoverable poll/submission pressure. The close-overflow guard
retains genuine protocol publication failure. This applies existing committed
state/event guidance to the public result and first stored terminal reason.

`terminal-cold-review/pressure-{4.3,4.7.2}.log` independently drains both
events and transitions during 128 actual quality receives. Local close returns
BACKPRESSURE but falsely commits PROTOCOL_FAILED and an event-overflow diagnostic.
The scoped healthy mesh checks pass; these close-pressure failures remain real.
`feedback-repair/closure-green-{4.3,4.7.2}.json` each passes 34 focused
cases in two repeated fresh processes. Unchanged hostile ingress and terminal
matrices also execute on both pins without script errors: malformed options
return INVALID_ARGUMENT, pressured timeout publishes actual interruption and
disconnection, and genuine event overflow retains its reserved fatal diagnostic.
The earlier probe incorrectly expected quality receives to publish events; its
unchanged rerun remains recorded, alongside a corrected fixture and actual
queued-interruption overflow control. A renewed cold API review passes 34
focused cases and 349 independent hostile assertions per engine. Final wrap
receipts pass 107 unit cases, determinism, real runner controls, clean installs,
native/Web ownership and all four source gates on both pins. Source inventories
remain unchanged. Exact wrap commands and paths are in the session record;
current-head CI and merge-triggered main CI remain delivery gates.

## Prune Ledger

- Fixed at source: replaced rollback skill's blanket “P2P event lifecycle ...
  remain separately gated” wording with explicit product/source contract links
  and boundary evidence requirements. Retained the independent browser gate.
- Strengthened: accepted-minimum queue progress guidance now includes checksum
  retention through strict eligibility, comparison and eviction. Existing
  nonzero prefix checks now require actual checksum comparisons at that minimum.
- Merged: explicit-null object guidance joins existing nullable schema guidance;
  independent diagnostics and nonzero case gates extend existing negative-control
  guidance. No competing skill or knowledge entry was created.
- Retained: canonical-byte, callback guard, strict schema and pending-repair
  guidance still applies. Sync-test distance-zero behavior is separate from the
  peer zero-window capture extension and was not removed.
- Strengthened: fixture finalization joins existing receipt invalidation guidance;
  mixed-process results remain failed evidence and require a complete rerun.
- Fixed at source: replaced implicit full-suite CI timeout with an explicit
  budget; focused watchdog controls remain unchanged. No competing timeout
  policy or duplicate networking skill was added.
- Verify-on-touch: counted actual source records above; inspected product
  extension documentation; ran all harness gates below. No completed oracle or
  browser release gate is claimed from the curation commands.

## Verification

`make llm-index`: exit 0; index and 26 discovery stubs regenerated.
`make lint-llm`: exit 0; lengths, freshness, links and encoding valid.
`make test-llm`: exit 0; 99 tests passed. Printed ERROR/CRITICAL examples
come from expected negative self-test fixtures, not repository failures.

## Outcome

State: `findings-acted`. Durable procedures live in existing canonical skills.
Final source/runtime, current-head feedback and merge-triggered main-CI evidence
belongs to the linked session P4 issue. This artifact does not predeclare it.
Complete fault meshes, real transports and browser release support retain their
separate roadmap gates.
