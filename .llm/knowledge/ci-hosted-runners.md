# Hosted CI Runner Facts

Verified operational facts about the GitHub-hosted Reference Baseline and
Devcontainer workflows: transient-failure classification, recovery policy and
timing extraction. Re-verify on touch.

| Fact (one assertable sentence) | Evidence (command + output, file:line, or measurement) | Verified |
| --- | --- | --- |
| A single transient `OSError: [Errno 101] Network is unreachable` (or `URLError`/`ConnectionError`) during a pinned-artifact download fails one whole ownership job even when identical sibling legs pass in the same run minutes earlier; `scripts/reference/fetch.py::fetch` retries such downloads with 10/20/30s backoff since the fix below, so the class now self-heals and only exhaustion surfaces the original error. | 2026-11-13 main run `43509711431` on squash `fe2fbc9`: only "snapshot ownership 4.3 negative part 3" failed with `urlopen error [Errno 101]` at `fetch.py:56`, while the same leg passed on PR #356 head `ab2fe87` minutes earlier; fix in PR #357 with `test_fetch.py::test_transient_download_failures_are_retried_and_deterministic_ones_are_not`. | 2026-11-13 |
| A GitHub artifact/download-host outage surfaces as `urllib.error.HTTPError: HTTP Error 504` in the probe step (or `curl: (22) ... 504` in the Devcontainer engine download) and fails many jobs at once across all workflows, including untouched ones; rerun `gh run <id> --failed` on a spaced loop (wait minutes between cycles) until it lands in a healthy window — no tree change is warranted when the merged tree equals a fully green head. | 2026-11-09 main run `42579030814` on squash `b41bba2`: failures shrank 15 → 10 → 8 → 0 across four spaced `--failed` reruns, every failure log showing the 504; the identical tree had passed as PR #339 head `ae88484`. | 2026-11-09 |
| Per-step job timing is extractable even when the Jobs API returns null step timestamps: `gh run view --job <id> --log` lines carry millisecond timestamps and `##[group]Run <step name>` markers, so diffing consecutive group markers per step yields exact step durations. | 2026-11-09 session 165 measured the Chromium 4.7.2 ownership part 3 as ~7s checkout/setup, ~18s cache restore, ~18s npm+playwright and ~1m48s witness work this way (job `128981763159` of run `42562496243`). | 2026-11-09 |

## Files

See also: [cache-hygiene.md](./cache-hygiene.md) for machine-local growth,
[devcontainer-tooling.md](./devcontainer-tooling.md) for container build facts.
