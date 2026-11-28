# Oracle and Mutation Evidence

Use for differential traces, schemas, projections and negative controls.
Validate the instrument with a single-variable green control before trusting its red;
see the [regression triple proof](../SKILL.md#regression-triple-proof).

Validate embedded scenarios/results independently before comparing their identity
to submitted artifacts. Python equality treats booleans, integral floats and
integers as equal; it is not schema validation. Standalone executables also need
their own complete schema and nonempty-work boundary.
Preserve decoded wire fields instead of substituting scenario expectations.
Preserve request and export statuses separately; unknown or predicted status must not normalize to confirmed.
Fault observers must check read success before interpreting returned bytes or default status fields.
If stronger validation rejects an injected fault earlier, require that exact typed rejection rather than a derivative status mismatch.
Keep that structural rejection separate; rebuild semantic mutants with valid structure so they still reach the invariant they claim to test.
Mutate actual encoded bytes before observation to test the observer itself.
Bind the complete original artifact, including header and metadata, to an independent
baseline before validating its exact changed byte. Two mutually consistent forged files are not original evidence.
Validate nullable fields before normalization; false and empty strings cannot
silently become the same observation. Test omitted and explicit-null optional
objects separately through every standalone executable. Require field presence
when explicit null is part of the observed contract; parser defaults can alias
them before shared validation runs. Constrain omitted setup records to their
exact allowed position. Formal projection must account for the observed initial
state and every supported post-state, including actual backlog and pacing advice.
Do not substitute a model's sentinel rules for runtime policy observations.
Test each prediction boundary before confirmation and after confirmed frame
zero. The two conditions can use different frame-distance calculations.
Label synthetic bootstrap separately, retain startup counterexamples, and require
transition-control rejection inside the actual observed suffix, not only its setup.
When a detailed observation stream accompanies a smaller comparison projection, validate its complete
delivery and microstep inventory too. Repeating valid startup records must not replace exercised history.
Count completed ADVANCE requests separately from service attempts, retaining bounded empty attempts with their original samples.
Record unexpected callback kinds too; a redundant LOAD can preserve canonical state while violating request order.

Compare intermediate canonical prefixes against original submitted histories.
A final checksum or accumulator sum can match after reordered inputs; replaying
an oracle's own requests can preserve the same mistake. Keep a temporal mutation
that retains the final state while violating an intermediate frame.
Diagnostic windows may include predicted inputs beyond received originals. Check
their confirmed prefix against originals, then reproduce captured applied inputs
for speculative playback; retain both confirmed-mismatch and viewer-state controls.

Validate original numeric tokens when parsing erases integer versus float syntax.
Check the complete integer grammar, including leading zeros, and preserve unsigned
field policy before negative zero normalizes. Reject duplicate decoded object keys,
including escaped equivalent spellings, before parsing overwrites their values.

Godot JSON parsers expose numeric fields as floats. After validating integrality
and bounds, reconstruct scenario records with explicit integers before emitting
a strict cross-language trace. Godot 4.3 and 4.7.2 stringify integral floats
differently; never weaken the Python integer schema to compensate. The production
session oracle's canonical scenario conversion protects this boundary.

Mutations must fail at the intended diagnostic and consumed-record position; unrelated failures do not count.
Measure delivery counts at successful operations, rather than emitting the expected inventory.
Longer workloads can cross periodic protocol boundaries despite unchanged input cadence;
derive the full control-message schedule from source instead of repeating short-run totals.
Before accepting a mutation's named rejection, validate its exact changed value and type alongside unchanged state;
an incorrect count or wrong type can reach the same error path as the intended fault.
Distinguish a fabricated missing-history inventory from physical eviction. Advance real queues,
verify the old frame tag is overwritten, and require the retained journal's exact original bytes.
For injected packet loss, retain emission identities and reconcile emitted minus discarded packets with actual receipts.
A later equal payload cannot prove the first emission was lost. Reject a clean trace relabeled as loss and a restored discarded receipt.
Require prerequisite receipts before the decisions they enable in every compared runtime; a retry received only after COMMIT cannot prove recovery.
Capture action order at accepted publication and receipt. Bind each drained packet to that publication before counting distinct retry turns.
For selective loss, prove negotiation arrived. Record the first terminal transition separately from the event drain.
When receipt of a peer's abort ends the operation, record that packet alongside the terminal transition.
Assert departure-driven termination before presenting late work. Compare replay extent and original rows again after refusal.
Pair donor silence with a live donor that holds the same chunk. Bind commits to its release clock and invoke the advancement API directly after refusal.
Validate the complete operation identity against the agreed operation before comparing retry payloads; matching malformed identities are insufficient.
When control packets forward another participant’s certificate, sender direction cannot identify its owner.
Select acknowledgement-loss faults by the actual participant certificate too, and retain emission/delivery order
to distinguish a response to a repeated commit from an independently retried acknowledgement.
Require the earliest eligible delivered response to satisfy the ordering; a later valid retry cannot excuse an earlier invalid one.
Validate each packet’s actual ordered target handles and generations against its digest; an expected digest cannot certify an unchecked target list.
If a global floor prevents the proposed eviction, preserve that control and report the bound.
Compare an overwritten safe tag and the protected original row in the same minimum-capacity ring.
Bind the argument to the recipient's actual receipt, active membership and the prediction window.
Changing the inventory cannot establish that an original row was evicted.
Declare expected diagnostics independently; learning them from the validator makes rejection circular.
For idempotent input delivery, state equality can hide duplicate work. Also assert
exact queue occupancy, due-frame timing and once-per-frame sampling with a resampling mutant.
Activate each modeled bound: a catch-up speed equal to queue capacity never tests
clamping. Buffer more ready work than the selected speed and remove the production
clamp in an isolated control to prove the model rejects it.
Select mutated records by semantic kind. Require scenario-specific nonzero
observations and an expected control inventory before publishing success. A
shortened corpus that never reaches its named event must fail those gates.
For sparse or optional validation, independently require the exact validation
request schedule. Workload names and advance counts can stay green when validation
is disabled or every frame is checked; neither executes sparse validation.
Recording parity must exercise the source session's actual recording/export API;
constructing a replay directly proves playback only. Compare exported rows and
checksum presence against original delayed inputs and observed SAVE requests,
then round-trip each runtime's own format without implying file interchangeability.
For disconnected-history recordings, make status affect canonical game state. Repair a mutated status row's input digest
when testing state-checksum validation; a digest rejection alone does not prove playback applies the recorded status.
For mid-session extraction, retain the actual decoded early export through continued gameplay,
then play that retained object. Observe subsequent extraction success or refusal and later recording
contents independently; regenerating the early export after continuation cannot prove its ownership.
Legacy format acceptance must observe the decoder's actual version, not only a workload name.
Run independently packed files through each playback interface, then replace legacy bytes
with a valid current file and require rejection at the format identity boundary.
For snapshot-omission controls, derive localization from the first serialized
consumer of the missing field. A mutant that omits a field from every snapshot
can hide its immediate difference until a later scheduled event exposes it.

Before projecting intentional source/product differences, validate the excluded
inventory's exact peer membership, payload, count, order and allowed position.
Keep controls for invented local-peer events and duplicate notification suffixes.
Terminal freeze witnesses read the actual retained simulation frame after teardown,
require the completed frontier, and reject zero display defaults or later advancement.
Their mutants preserve earlier frame/state checks to reach the terminal boundary.
For deliberate gameplay divergence, retain valid serialized-state bounds. Drive
the game to domain edges and force rollback after divergence; require a genuine
checksum mismatch rather than accepting an unrelated callback failure.
A corruption control may desync before capture; require its typed cause and independently verified altered bytes.

Keep the observed first failure separate from later cleanup termination. A stopped counterpart cannot replace the required desync or erase canonical history.
For held packets, keep publication, release and socket consumption clocks separate. Bind a positive COMMIT to its real routes and the recipients' installed history.
Fence both browser endpoints at the recovered prefix before releasing new input.
Join a held relay carrier to its exact browser message. Require a unique candidate for SDK admission when the SDK reports envelope bytes alone.
When extending a browser witness, run the workflow's actual engine and browser axes.
Swap the browser assignments in a mixed receipt while preserving its browser inventory.
For retained local samples, check code, frame, bytes and status on the installed
backend during a real prediction stall. Check the authored sample independently.
Read typed outcomes and original histories from each runtime. Case names and assertion counts identify the tests and cannot establish runtime outcomes.
For an exported room with a closed browser page, join original page indices to UUIDs before closing. Start the SDK notice window at the controller action.
Rebuild speculative snapshots from bounded applied callback inputs. Use the observed delivery history in live cases whose prediction varies with arrival order.
Give fake engine subprocesses in receipt tests a fixture-local capacity directory. Keep real engine and browser probes on the shared lease.

Fingerprint the inputs to each schedule generator, including its upstream
source and locked build. Check that the tracked bundle matches the fingerprint
and full corpus inventory. Rebuild it with the selected observer when those
inputs change. Compare hinted and unhinted scenarios with the same live
oracle and record subprocess counts and canonical hashes. Revalidate the
whole hint and use its observations only for an exact matching prefix.

At a prediction cap, record both the first blocked call and an identical
retry. The first call can stage and send the current sample. The retry must
hold the frame without sending another sample. After actual input arrives,
compare earlier rollback callbacks separately from forward frame progress.
Service delayed receipt gossip before treating a stall as the nearest
reachable retention bound. Record physical slot tags before and after reuse.

Receipt and snapshot tooling binds the working tree at run start and refuses
drift at the end (`launch.require_unchanged` over `source_files()`,
`native_source_snapshot` over `git ls-files --others`, plus commit and dirty
identity): never create, edit or commit any tracked file while an oracle
launcher, receipt capture or the parallel unittest runner holds the tree — including
creating or editing a non-ignored untracked file, which the same snapshots
count via `git ls-files --others` (their contents are hashed). Twice recorded before it was systematized: session 190's wrap receipts died
on "evidence identity changed" from a file created mid-run, and session 191
repeated it (a tooling file created during `test_godot_runner`, then a
mid-run commit failing the corpus's repository-identity check). Finish or
kill the run first; the definitive receipt always comes from the final head
with a clean tree. Mutant-check hygiene from the same session: never stash a
working-tree diff with `git diff > patch` and re-apply it later — the captured
patch goes stale the moment the tree moves (a checkout in between silently
restored a mutant); re-apply fixes by editing the file and verify the exact
changed lines after every checkout cycle.
