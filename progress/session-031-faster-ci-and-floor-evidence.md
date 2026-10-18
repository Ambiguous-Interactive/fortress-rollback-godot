# Session 031 — Faster CI, case-level shards and floor evidence

## Scope and baseline

Started 2026-10-18 at 00:47 UTC with a two-hour limit. Main was green at `eeac685` with no open PRs.
The uncommitted session 030 delivery notes and merge-authorization wording were carried into this PR.

Goals: advance at least three issues, keep CI time flat or lower without losing coverage, and make
local test runs much faster. A triage pass over every open task issue found none closable as-is:
nearly all wait on #13 or on live browser work. #61's runtime repair had already shipped, and #45
had one concrete row left.

## Faster CI

Measured first. On main (`eeac685`, run 39082854349) the 4.7.2 WebRTC job took 12m18s, and its
eight browser labels ran in one 10m13s step. The next slowest job was the 4.7.2 online job (8m21s:
online example 2m04s, then native relay 4m05s), then the suites jobs (unit 2m29s, then integration
2m37s).

- `signalfish_webrtc_probe.py --label` (repeatable) selects witness labels and records them in the
  receipt; each label logs its time. CI's SignalFish matrix is now `direct` (clean, faults, corrupt,
  default), `mixed` (the four mixed labels), `online` and `relay`. Relay extracts its pinned editor
  through `fetch` and skips the browser install.
- The Godot matrix adds `integration`, which runs the four cases as before without the browser
  install or web smoke. The suites part keeps the package audit, SDK probe, runner controls, unit
  and determinism runs.
- The SignalFish jobs cache the server's dependency builds. The builder still cleans and rebuilds the
  server crate, and its receipt is unchanged.

Every previous step still runs on both pinned engines; the adversarial review checked this line by
line.

| Measurement | main `eeac685` | PR, first run (`9a0fba2`..`d52534d`) |
| --- | --- | --- |
| Reference Baseline wall time | 12m20s | 6m38s |
| Slowest job | 12m18s (4.7.2 webrtc) | 6m37s (4.3 mixed) |
| Jobs / summed job time | 11 / 65m57s | 17 / 75m37s |

The summed job time rose with six extra job setups. The dependency cache, measured below, targets
about a minute of that per SignalFish job.

## Faster local runs

Measured on 16 CPUs with nothing else running. `make test-godot` (unit, 263 cases) took 37.4s with
main's launcher. Its long pole was `test_webrtc_mesh_backlog.gd` (one case, about 25s), which sorted
last, so it started after almost everything else.

- `scripts/run_godot_tests.py` saves per-suite times to ignored `.cache/tests/durations.json`
  (`--durations` overrides) and starts the slowest shards first, both repetitions together.
- A suite that took at least four seconds runs one fresh-process pair per case. `run_tests.gd` gains
  `--list-cases` and `--case <name>`; an unknown `--case` is an error. Shards merge in suite order,
  then inventory order. A split suite's recorded time removes the extra engine startups, so a suite
  that is no longer slow runs whole again. Times only change scheduling.
- `test_webrtc_mesh_backlog.gd` is two cases, one per receive budget, with the same assertions.

| Measurement | Before | After |
| --- | --- | --- |
| `make test-godot` (unit) | 37.4s | 25.7s |
| Integration category | 121.2s (first run, whole suite) | 89.6s (cases in parallel) |

The unit floor is now `test_peer_example.gd::sustained_faults` (about 19s), a 3,000-tick
simulation. Formatted per-tick assertion labels cost only about 10% of it, so it was left alone.

`test_sharded_runs_match_one_process` adds a forced split: `--jobs 1`, `--jobs 4`, and `--jobs 4`
with a durations file that marks `test_snapshot_history.gd` slow must give identical results. With
the case order reversed inside split suites, the control fails.

## Global rollback floor (#61)

`tests/unit/test_rollback.gd` adds `global_floor`. Three players, prediction window 4, queue
capacity 9: player 2 lags by three frames and forces a rollback each tick from tick 13; player 1
stalls, then receives frames 9–17 at once and stays five frames ahead; tick 20 raises the local
input delay during prediction. Every tick checks that the floor input is readable from all three
queues, that one more frame from player 1 is refused, and that the old floor's side slot is dropped
and its resend rejected. Confirmed states match a run with no delays.

Mutations, each reverted: the fastest player's received frame as the floor (322 failures); a queue's
own high-water as its floor (347 failures; `external_corrections` still passes under this one);
keeping the side slot on discard (29 failures). The upstream oracle observation gate stays open.

## Native and Web replay playback (#45)

`test_replay.gd` records canonical states after every playback, at each desync stop, for the
re-encoded golden and for the lockstep case. `ownership_probes.py` runs all seven replay cases in
native and exported Chromium builds on both pins, and the existing strict comparison now covers
them. The generated probe project copies `config/version` from `project.godot`, which joins the
source checksums. With one Web-only state changed, the probe failed with `native/web ownership
divergence`. Each export page may now take two minutes; one page took 36.6s under load against the
old 60s limit. Remaining on #45: optional seek and snapshot acceleration.

## Review

A fresh-context adversarial review of the CI, runner and floor changes found no critical defects.
Acted on: split suites stayed split forever (major), unknown `--case` names were ignored, runner
controls wrote the real durations file, an unknown mesh case ran the second branch, and the
integration job's name mentioned Chromium. Not acted on: CI never caches durations, so CI keeps
whole-suite shards; its unit run is CPU-bound on four runner CPUs anyway.

`make test-reference` caught that the replay probe change broke two receipt controls (the fixture
lacked `project.godot`, and a regex expected a one-line suite list). Both are fixed.

The [retrospective](../.llm/retrospectives/2026-10-18-faster-ci.md) records the session's findings.
Retro: findings-acted.
