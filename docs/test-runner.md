# Deterministic Godot test runner

The V1 runner is development tooling, not rollback or differential coverage.
It implements the fail-closed and repeatability requirements in
[verification policy](verification-policy.md), with the Godot 4.3-compatible
suite boundary described below. It requires only Godot and Python's standard
library; no test addon, Rust toolchain or browser package is needed.

## Headless entry point

Use a verified editor fetched through the [reference tools](reference/README.md):

```sh
python3 scripts/run_godot_tests.py \
  --godot .cache/reference/editors/4.3/Godot_v4.3-stable_linux.arm64 --timeout 180
```

Choose the corresponding verified executable for your host architecture.
The launcher returns 0 only after **two fresh Godot processes** both complete,
pass, and produce identical semantic results. Each process also executes each
case twice with fresh suite and assertion-context instances. Every repetition
receives the same explicit seed (default `1701`, signed 64-bit).

Options: `--category unit|determinism|integration`, `--filter <case-substring>`,
`--suite res://path.gd` (repeatable), `--seed <integer>`, `--timeout <seconds>`
(per process, default 30), and `--results <path>`. Default results live in ignored
`.cache/tests/latest.json`. They contain engine version/digest, repository commit
and dirty flag, pin digest, platform, commands, working directory, seeds, complete
semantic records, raw engine output, exit status and failure reason. A dirty flag
means the commit alone does not reproduce the worktree.

CI uses `--timeout 180` for the complete unit category; `make test-godot` uses 120 seconds.
Use the CI command above for the full verification budget. Ordinary focused suites retain
the default budget. The slower integration category uses the budget below.
Deliberate watchdog controls keep their short limits.

The integration category includes the slower eight-peer transport scheduling regression. Run each
case separately. The single-poll workload uses 180 seconds; the other cases use 120 seconds.
Keep the single-poll control, batched workload, and ordering controls in separate processes.
The 120-second single-poll run completed one repetition but expired during its second on CI.
The larger bounded budget retains every workload and repeat; CI must verify full completion:

```sh
for case in default_single default_batched readiness_boundary aborted_wait; do
  case_timeout=120
  if [ "$case" = default_single ]; then case_timeout=180; fi
  python3 scripts/run_godot_tests.py --godot path/to/verified/godot \
    --category integration --filter "$case" --timeout "$case_timeout" \
    --results ".cache/tests/integration-$case.json"
done
```

It preserves real peer retries, ACKs and receipt gossip through bounded transport work with an
explicit 300 ms host schedule. Its fake transport delivery queue becomes visible only between host turns;
this native fixture does not establish browser or physical outage acceptance.

Without explicit suites, the selected category discovers `test_*.gd` recursively
under `tests/<category>/`, in sorted path order. Unit additionally runs the runner's
self-suite. Missing suites, duplicate paths, unknown options, invalid inventories,
zero matched cases and zero assertions fail. Empty categories fail;
selecting a category with the runner
self-suite validates selection, not product integration or simulation coverage.
The runner self-suite protects table assertions, first-byte/frame diagnostics and
fresh-instance isolation. Deliberate failures live outside discovery under
`tests/runner-controls/`.

## Focused local iteration

Select the owning suite while changing one subsystem:

```sh
make test-focus GODOT=path/to/verified/godot SUITE=res://tests/unit/test_input_queue.gd
make test-focus GODOT=path/to/verified/godot CATEGORY=determinism FILTER=restore
```

This uses the same fail-closed launcher and both repetition layers. Empty selections fail.
Run the full affected categories before delivery; focused receipts establish only their selected coverage.
Oracle launchers still run every scenario and negative control. Their verified source caches retain
unchanged file timestamps, so warm Cargo builds reuse artifacts after content validation.
Changed, missing, injected or symlinked source files trigger replacement from the verified archive.

## Suite interface

A suite extends `RefCounted`. `cases() -> PackedStringArray` returns unique,
nonempty names in deterministic execution order. `run_case(name: String,
context: RefCounted) -> void` consumes the supplied context. Use explicit preloads
rather than requiring an editor-imported global class cache.

```gdscript
extends RefCounted

func cases() -> PackedStringArray:
    return PackedStringArray(["canonical_state"])

func run_case(_name: String, context: RefCounted) -> void:
    var rows: Array[Dictionary] = [
        {"label": "integer addition", "actual": 1 + 2, "expected": 3},
    ]
    context.table(rows)
    context.bytes_equal(PackedByteArray([1]), PackedByteArray([1]), 0, "S(0)")
    context.state(0, PackedByteArray([1]))
    context.finish()
```

Contexts expose `equal(actual, expected, label)`, `table(rows)`,
`bytes_equal(actual, expected, frame, label)`, `state(frame, canonical_bytes)`
and `finish()`. They collect explicit failures; no `assert()` can disappear in
release exports. Byte failures identify the first differing byte (including
length differences), supplied frame, and complete expected/actual hex bytes.
State records preserve case/frame order and full canonical bytes. Seed values
and canonical bytes use lossless strings in JSON. Mark completion exactly once,
after all work; asynchronous/yielding cases are unsupported and fail incomplete.

`scenario_runner.gd` has no SceneTree, Node, filesystem, timer or OS dependency.
A future browser host can preload the same suite scripts and call
`execute(scripts: Array[Script], category, filter_text, seed) -> Dictionary`.
The result contains format, completion, pass flag, count, errors and ordered
case records with both runs. Browser export/execution is **not implemented or
verified by this runner**. It still needs its own host watchdog/error handling.

Mutable fixture state belongs on each suite instance/context. Static fields,
autoloads, engine globals and external resources are forbidden as fixture state;
fresh instances cannot reset arbitrary external state. Both repeat layers compare
all result records, without normalizing disagreement, timing or order. Native
scenario assertions must record meaningful canonical states for byte equality to
prove anything about their simulations.

## Failure controls and scope

```sh
python3 scripts/reference/test_godot_runner.py \
  --godot .cache/reference/editors/4.3/Godot_v4.3-stable_linux.arm64 -v
python3 scripts/reference/test_godot_runner.py \
  --godot .cache/reference/editors/4.7.2/Godot_v4.7.2-stable_linux.arm64 -v
```

The table drives real engine controls: known pass; byte failure at frame 7/byte
1; incomplete case; uncaught script error; an error after a case already marked
complete; static-state leakage; watchdog; parse error; missing suite; empty filter;
and zero-exit missing completion. It checks intended failure reasons so a timeout
cannot count as a successful assertion rejection. It also runs the runner suite
in each category with the maximum signed seed, comparing in-process and
fresh-process results. Standard-library tests reject truncated, unknown,
contradictory and vacuous structured results.

Godot can log an uncaught GDScript error and still exit zero after a completed
case. The standalone `godot --headless --path . --script
res://tests/runner/run_tests.gd` invocation cannot guarantee interception of all
engine errors or interrupt a synchronous infinite loop. Use the **Python entry
point** for CI: it rejects engine `ERROR`/`SCRIPT ERROR` output, nonzero exit,
missing/duplicate completion, malformed result records, incomplete consumption,
repeat disagreement and wall-clock watchdog expiry. Wall-clock timeout belongs
only to the host and never enters scenario simulation state. The after-completion
error control specifically proves that a green marker/zero exit cannot bypass
this host boundary. Fresh-process divergence records the first differing ordered
case/state/byte when available.

No pinned Fortress parity claim applies: these assertions test the Godot host
contract, not translated simulation behavior. Product differential, browser,
formal, multiplayer and release-platform gates remain separate work.
