# Session 030 — Parallel suites, receipts and replay v2

## Scope and baseline

Started 2026-10-17 at 22:38 UTC with a two-hour limit. Main was clean at
`2ed566b` with all main workflows green and no open PRs.

Goals: close or advance at least three issues, keep CI time flat or lower without losing coverage,
and make local test runs much faster. A triage pass over #25–#46, #59, #61, #75 and #103 found no
issue closable as-is. #103 was fully specified. #46 had one row left, and #45 two concrete rows.

## Faster local and CI runs

Measured first. On main, the critical path was the Godot job (one 15-minute step: unit suite 325s,
the integration `default_single` case 254s, then the oracle launchers about 4.5 minutes, all in
series) and the SignalFish job (WebRTC probe 548s, online example 130s, native relay 237s).

- `scripts/run_godot_tests.py` runs each suite in its own pair of fresh processes, up to `--jobs`
  (default: CPU count) at a time, and joins the results in sorted suite order. Both repetitions of a
  suite run at once. `--jobs 1` keeps the single-process run. With `--filter`, suites with no
  matching case are dropped, and the whole selection must still match.
- CI splits the Godot job into `suites` and `oracles`, and the SignalFish job into `webrtc` and
  `online`. Every step still runs on both pinned engines.

Evidence:

| Measurement | Before | After |
| --- | --- | --- |
| `make test-godot` locally (16 CPUs, 258 cases) | 203s | 48s |
| Merged records vs one process | — | identical (`serial.json` vs `latest.json`) |
| Reference Baseline wall time | 17m26s (main `010bad4`) | 11m51s (PR head `bdd9ce2`) |
| Longest Godot job | 16m05s | 7m16s (4.3 suites) |

The slowest single suite (`test_webrtc_mesh_backlog.gd`, 24s locally) is now the local floor.
Billed minutes also drop: the unit suite runs in parallel on the four runner CPUs, which saves more
than the four extra job setups cost.

`test_sharded_runs_match_one_process` compares `--jobs 1` and `--jobs 4` for all, filtered and
unmatched selections. Its first run caught a real bug: shards kept command-line suite order while
`run_tests.gd` sorts suites. Shards are now sorted, and the merged result goes through the same
`validate_result` as a single process, so duplicate suites still fail with `duplicate case`.

The `FILTER=restore` example in `docs/test-runner.md` matched no case even before this change. It
now uses `snapshot`.

## Stale receipts on rejected launcher arguments (#103)

`scripts/reference/receipt_arguments.py` replaces `browser/webrtc_arguments.py`. All nine listed
launchers, plus `ownership_probes.py`, `godot_smoke.py` and the WebRTC probe, use it. On a parse
error or post-parse `parser.error`, the selected receipt (last named `--output`, the default, or the
fixed cache output) becomes `{"passed": false, "failure": "invalid_arguments"}`. Help stays
read-only; `--help=x` is rejected. A bare `--output` selects nothing. The helper is listed in every
source inventory and build-receipt input set that listed the old file.

Option abbreviations such as `--off` are now rejected by every launcher, as the WebRTC probe already
did. No Makefile, workflow or doc used one.

Same failure class: `run_godot_tests.py --results` had the same gap. It now writes a failure to the
selected results before exiting. `test_rejected_arguments_invalidate_selected_results` covers five
rejections and help. With the override removed, five rows fail.

Evidence: `test_rejected_launcher_arguments_invalidate_only_the_selected_receipt` runs all twelve
launchers as real subprocesses in a copied tree. With the helper's write disabled, 60 checks fail.
`make test-reference` (91 OK, 3 skipped), `make test-oracle` (56 OK), and an end-to-end
`queue_launch.py` run (711 cases) whose receipt lists the helper.

## Replay format version 2 (#45)

Replay files now record the starting input delay, prediction window, sync-test flag, neutral input,
engine build, addon version, pinned upstream revision, game seed and game version. Skipped frames
have their own flag and must hold neutral input. `decode` returns `DecodeCode` (`OK`, `MALFORMED`,
`UNSUPPORTED_VERSION`, `TOO_LARGE`). Version 1 never shipped, so it is rejected with
`UNSUPPORTED_VERSION` rather than migrated with invented provenance. The guide states the policy for
released versions.

`scripts/reference/replay_golden.py` packs the golden by hand with `struct`; it never runs Godot.
`tests/fixtures/replay/golden.json` holds the bytes, expected fields and a v1 sample, and
`make test-reference` fails if the file drifts from the generator. `test_replay.gd` decodes every
field, re-encodes identical bytes, and checks 24 hostile patches, every truncation and trailing bytes.

Remaining on #45: native versus exported-browser replay comparison, and optional seek acceleration.

## Delay changes against the Rust oracle (#46)

The pinned upstream `P2PSession::set_input_delay` works at runtime: gap frames repeat the latest
input, decreases are refused, and too-large values return `FrameDelayTooLarge` or
`ConfigValueOutOfRange`. The P2P oracle gains `{"kind": "delay", "peer": p, "delay": d}` on the Rust,
Python and Godot sides. Python recomputes every expected outcome, including the repeated gap frames.

The comparison found a production bug. After a raise, Godot sent one input packet per added frame,
counted gap frames as time-sync samples, and its in-between packets announced the final frame before
carrying it. Upstream sends one packet per remote and skips those samples.
`FortressInputEndpoint.submit_frames` queues the frames and sends once; `set_input_delay` uses it.

Scenarios: `mesh_2_delay_change_loss` (every third packet dropped, repeated raises, refused decreases
and a refused 500), `mesh_4_delay_change_rapid` (reordered delivery, three raises in a row, a raise to
Godot's maximum of 59, a no-op and a refused 1000) and `mesh_3_delay_change_stall` (raise while
stalled, then other peers raise).

Evidence:

- `p2p_launch.py --offline`: 37 cases match twice on Godot 4.7.2 and on the pinned 4.3 editor.
- Red: one packet per frame fails at `operation 1` (and `operation 7` with loss) as `outgoing mismatch`.
  Ignoring the operation stops at `unobserved packet`. Dropping refusal codes fails at
  `operation 21: delay change outcome`.
- `make test-oracle`: 58 OK.

Documented, not compared: changes before the first step (upstream accepts, Godot returns
`UNSUPPORTED`), delays in the band where the limits differ (upstream `127 - max_prediction`, Godot
`(126 - 2 * max_prediction) / 2`), and upstream's full-queue refusal. With a starting delay above 0,
upstream drops a resend that starts at a frame it already holds and Godot accepts it. That is a resend
difference, not a delay rule, so the rapid case raises only after frame zero is acknowledged.

## Review

Fresh adversarial reviews ran on #103 and #45.

- #103, should-fix: with `--output A --output= --bogus`, A is invalidated and `./` is not. Declined:
  the empty value selects nothing, and A was named by the rejected attempt, so invalidating it is
  conservative.
- #103, nit: the same gap in `run_godot_tests.py`. Fixed above.
- #45, should-fix: `DecodeCode.OK` is 0, so a truthiness check inverts. Declined: every result enum
  in the addon starts at `OK`, replays have never shipped, and the guide compares against `OK`.
- #45, nits: two hostile rows are also caught by a second check; playback does not tell a game that
  a frame was skipped (recording calls that path defensive). Recorded, not changed.

## Retrospective

The [retrospective](../.llm/retrospectives/2026-10-17-parallel-suites.md) updates the testing skill's
local-iteration guidance for sharded runs.
Retro: findings-acted.
