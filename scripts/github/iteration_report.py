"""Measure required PR and merge-group check latency using authenticated gh and repository ref activity."""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import math
from pathlib import Path
from statistics import mean
import subprocess
from urllib.parse import urlencode


def ts(value):
    stamp = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return (stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)).timestamp()


def candidate(origin, required, jobs):
    """Keep every attempt's work and carry successful checks through partial rerequests."""
    contexts = defaultdict(list)
    intervals, failures, steps = [], [], []
    for j in jobs:
        if j['name'] in required:
            contexts[j['name']].append(j)
        if not j.get('started_at') or not j.get('completed_at') or j['conclusion'] == 'skipped':
            continue
        start, end = ts(j['started_at']), ts(j['completed_at'])
        intervals.append((start, end))
        failed = [ts(s['completed_at']) for s in j['steps'] if s['conclusion'] == 'failure' and s.get('completed_at')]
        if failed or j['conclusion'] in ('failure', 'timed_out'):
            failures.append(min(failed, default=end))
        steps.append(dict(job=j['name'], run=j['run_id'], attempt=j['run_attempt'], outcome=j['conclusion'],
                          pickup_s=start - ts(j['created_at']), seconds=end - start,
                          steps=[(s['name'], s['conclusion'], ts(s['completed_at']) - ts(s['started_at']))
                                 for s in j['steps'] if s['conclusion'] != 'skipped' and s.get('started_at') and s.get('completed_at')]))
    latest = [max(rows, key=lambda j: (j['run_id'], j['run_attempt'])) for rows in contexts.values()]
    missing = sorted(required - contexts.keys())
    conclusions = {j['conclusion'] for j in latest}
    # The historical Gate legitimately skipped the controls on a non-tooling PR.
    invalid_skip = any(j['conclusion'] == 'skipped' and j['name'] != 'Reference and oracle negative controls' for j in latest)
    if missing or not origin or invalid_skip or any(not j.get('completed_at') for j in latest):
        outcome = 'incomplete'
    elif 'cancelled' in conclusions:
        outcome = 'cancelled'
    elif conclusions <= {'success', 'skipped'}:
        outcome = 'success'
    else:
        outcome = 'failure'
    end = max((ts(j['completed_at']) for j in latest if j.get('completed_at')), default=None)
    elapsed = end - ts(origin) if outcome != 'incomplete' and end is not None else None
    concurrency = peak = 0
    for _, delta in sorted((t, d) for a, b in intervals if b > a for t, d in ((a, 1), (b, -1))):
        concurrency += delta
        peak = max(peak, concurrency)
    return dict(outcome=outcome, elapsed_s=elapsed, missing=missing, runner_s=sum(b-a for a,b in intervals),
                peak_runners=peak, first_failure_s=min(failures)-ts(origin) if origin and failures else None,
                retry_recovery_s=end-min(failures) if failures and outcome == 'success' else None, jobs=steps)


def summary(rows):
    # Superseded heads stay visible but have no completed validation verdict.
    times = sorted(r['elapsed_s'] for r in rows if r['outcome'] in ('success', 'failure') and r['elapsed_s'] is not None)
    p95 = times[math.ceil(.95*len(times))-1] if times else None
    counts = Counter(r['outcome'] for r in rows)
    return dict(outcomes=counts, completed=len(times), p95_s=p95, target_verified=len(times) >= 40 and p95 < 300 and not counts['incomplete'],
                total_runner_minutes=round(sum(r['runner_s'] for r in rows)/60, 2))


def cost_groups(rows):
    groups = defaultdict(list)
    for row in rows:
        key = (row['event'], row['tooling_controls'], row['outcome'])
        groups[key].append(row['runner_s'])
    return [dict(event=e, tooling_controls=t, outcome=o, count=len(values), mean_runner_s=mean(values))
            for (e, t, o), values in sorted(groups.items())]


def compare_budget(history, after):
    """Weight baseline cost by the new sample's event, tooling mix and final outcome."""
    costs = {(g['event'], g['tooling_controls'], g['outcome']): g['mean_runner_s'] for g in history}
    try:
        expected = sum(costs[r['event'], r['tooling_controls'], r['outcome']] for r in after)
    except KeyError:
        return {'comparable': False}
    observed = sum(r['runner_s'] for r in after)
    if expected <= 0:
        return {'comparable': False}
    return dict(comparable=True, observed_runner_minutes=round(observed / 60, 2), expected_runner_minutes=round(expected / 60, 2),
                ratio=round(observed / expected, 4), within_budget=observed <= 1.05 * expected)


def collect(repo, since, until):
    def pages(endpoint):
        raw = subprocess.check_output(['gh', 'api', '--paginate', '--slurp', f'repos/{repo}/{endpoint}'])
        return json.loads(raw)

    rules = [rule for page in pages('rules/branches/main') for rule in page if rule['type'] == 'required_status_checks']
    required = {c['context'] for rule in rules for c in rule['parameters']['required_status_checks']}
    if not required:
        raise ValueError('no required check contexts reported by the main branch rules')
    origin = defaultdict(list)
    for page in pages('activity?per_page=100&time_period=month'):
        for item in page:
            if item['activity_type'] in ('branch_creation', 'push', 'force_push'):
                origin[(item['ref'], item['after'])].append(item['timestamp'])
    groups = defaultdict(list)
    for event in ('pull_request', 'merge_group'):
        query = urlencode(dict(event=event, created=f'{since}..{until}', per_page=100))
        for workflow in ('gate.yml', 'reference-baseline.yml'):
            result = pages(f'actions/workflows/{workflow}/runs?{query}')
            runs = [run for page in result for run in page['workflow_runs']]
            if len({r['id'] for r in runs}) != result[0]['total_count']:
                raise ValueError('incomplete Actions query; use a shorter date window')
            for run in runs:
                ref = 'refs/heads/' + run['head_branch']
                starts = [v for v in origin[ref, run['head_sha']] if ts(v) <= ts(run['created_at'])]
                start = max(starts, default=None) if (run.get('head_repository') or {}).get('full_name') == repo else None
                groups[(event, ref, run['head_sha'], start)].append(run)

    def jobs(run):
        result = pages(f"actions/runs/{run['id']}/jobs?per_page=100&filter=all")
        rows = [j for page in result for j in page['jobs']]
        if len({j['id'] for j in rows}) != result[0]['total_count'] or any(j['head_sha'] != run['head_sha'] for j in rows):
            raise ValueError(f"incomplete or mismatched job list for run {run['id']}")
        return run['id'], rows

    with ThreadPoolExecutor(max_workers=4) as pool:
        work = dict(pool.map(jobs, (r for group in groups.values() for r in group)))
    result = []
    for (event, ref, sha, start), runs in groups.items():
        executed = [j for r in runs for j in work[r['id']]]
        row = candidate(start, required, executed)
        # Historical controls ran both make targets in one job. The parallel
        # layout still runs the exact targets in its two worker jobs.
        row['tooling_controls'] = any(step['name'] in ('Run make test-reference', 'Run make test-oracle') and step['conclusion'] != 'skipped'
                                      for j in executed for step in j['steps'])
        result.append(dict(event=event, ref=ref, sha=sha, start=start, runs=[r['id'] for r in runs], **row))
    return dict(repo=repo, since=since, until=until, required=sorted(required), candidates=result,
                cost_groups=cost_groups(result), summary={event: summary([r for r in result if r['event'] == event]) for event in ('pull_request', 'merge_group')})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='Ambiguous-Interactive/fortress-rollback-godot')
    parser.add_argument('--since', required=True, help='UTC date or timestamp within the past month')
    parser.add_argument('--until', default=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
    parser.add_argument('--baseline', type=Path, help='compare runner usage for the same event, controls and outcome mix')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    report = collect(args.repo, args.since, args.until)
    if args.baseline:
        before = json.loads(args.baseline.read_text())
        if before['repo'] != args.repo or ts(before['until']) >= ts(args.since):
            parser.error('baseline must cover an earlier window in the same repository')
        for event, metrics in report['summary'].items():
            metrics['budget'] = compare_budget(before['cost_groups'], [r for r in report['candidates'] if r['event'] == event])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, separators=(',', ':')) + '\n')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
