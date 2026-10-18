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
  default and the short disabled-fallback control), `mixed` (mixed, mixed-default, mixed-close) and
  `online`. Every previous step still runs on both pinned engines.

Tried and reverted, by measurement:

- Separate `relay` and `integration` jobs. Each cut its own job's time, but the jobs they left still
  finished inside the mixed job, so they added about two setup minutes each and no wall time.
- Caching the SignalFish server's dependency builds. The cache restored, but the build still took
  67s: the builder uses a fresh cargo home per run, so cargo rebuilt every dependency. Changing that
  would alter the build receipt's environment, so the cache was deleted.

Label times on the cached run (4.7.2): clean 98s, faults 99s, corrupt 6s, default 5s, mixed 114s,
mixed-default 115s, mixed-disabled 26s, mixed-close 118s. Runner variance between runs is large: the
same mixed job took 322s and 526s on two runs.

| Measurement | main `eeac685` | PR, all parts split | PR final (`3ed3a72`) |
| --- | --- | --- | --- |
| Reference Baseline wall time | 12m20s | 6m38s / 8m46s | 7m49s |
| Slowest job | 12m18s (4.7.2 webrtc) | 6m37s / 8m46s | 7m49s (4.7.2 mixed) |
| Jobs / summed job time | 11 / 65m57s | 17 / 75m37s and 80m34s | 13 / 72m13s |

Summed job time on the last four main runs ranged from 61m to 75m, so the final 72m13s sits inside
that spread, 6m above the most recent main run. The two added jobs cost about 2.5 setup minutes each.

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

### Changed-suite runs

After the merge of #115 the local gain was still moderate, so a follow-up PR adds `make test-changed`
(`scripts/changed_suites.py`, launcher `--changed BASE`). It follows `res://` paths and `class_name`
mentions from changed files to the suites that reach them, and falls back to every suite for any
change outside the Godot sources or to the runner. `scripts/tests/test_changed_suites.py` covers
direct, transitive, fixture, class-name and fallback rows; with class-name tracing disabled, it
fails.

| Edit since `HEAD` | Suites | Time |
| --- | --- | --- |
| One test file (`test_replay.gd`) | 1 | 1.6s |
| Online example script | 6 | 16.5s |
| Core `replay.gd` | 48 (everything reaches it) | full run |

The same PR trims CI: each Godot job smoke-tests only its own engine, and SignalFish artifacts drop
the cargo build output (330MB and about 28s of upload per job).

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
integration job's name mentioned Chromium (that job was later folded back). Not acted on: CI never caches durations, so CI keeps
whole-suite shards; its unit run is CPU-bound on four runner CPUs anyway.

`make test-reference` caught that the replay probe change broke two receipt controls (the fixture
lacked `project.godot`, and a regex expected a one-line suite list). Both are fixed.

The [retrospective](../.llm/retrospectives/2026-10-18-faster-ci.md) records the session's findings.
Retro: findings-acted.
