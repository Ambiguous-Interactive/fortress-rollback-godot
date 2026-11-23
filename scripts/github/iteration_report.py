"""Measure required PR and merge-group check latency using authenticated gh and repository ref activity."""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from functools import partial
import json
import math
from pathlib import Path
from statistics import mean
import subprocess
from urllib.parse import urlencode


def ts(value):
    stamp = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return (stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)).timestamp()


CONTROLS = 'Reference and oracle negative controls'
QUEUE = 'refs/heads/gh-readonly-queue/main/'


def legacy_skip(job, jobs, event, non_tooling):
    if job['name'] != CONTROLS:
        return False
    gate = [j for j in jobs if j['run_id'] == job['run_id']]
    old_unit = any(j['name'] == 'Changed unit suites (Godot 4.3)' and
                   any(s['name'] == 'Run the affected unit suites' for s in j['steps']) for j in gate)
    detected = any(j['name'] == 'Detect tooling changes' and j['conclusion'] == 'success' for j in gate)
    if not old_unit or not detected:
        return False
    if event == 'pull_request':
        return non_tooling
    if event == 'merge_group':
        return any(j['name'] == 'Reference negative controls' and j['conclusion'] == 'success' and
                   {'Run make test-reference', 'Run make test-oracle'} <= {s['name'] for s in j['steps'] if s['conclusion'] == 'success'} for j in jobs)
    return False


def candidate(origin, required, jobs, *, event=None, non_tooling=False):
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
                          pickup_s=start - ts(j['created_at']) if j.get('created_at') else None, seconds=end - start,
                          steps=[(s['name'], s['conclusion'], ts(s['completed_at']) - ts(s['started_at']))
                                 for s in j['steps'] if s['conclusion'] != 'skipped' and s.get('started_at') and s.get('completed_at')]))
    latest = [max(rows, key=lambda j: (j['run_id'], j['run_attempt'])) for rows in contexts.values()]
    missing = sorted(required - contexts.keys())
    conclusions = {j['conclusion'] for j in latest}
    invalid_skips = sorted(j['name'] for j in latest if j['conclusion'] == 'skipped' and not legacy_skip(j, jobs, event, non_tooling))
    missing_clock = any(not j.get('completed_at') or (j['conclusion'] != 'skipped' and not (j.get('created_at') and j.get('started_at'))) for j in latest)
    if missing or not origin or invalid_skips or missing_clock:
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
    return dict(outcome=outcome, elapsed_s=elapsed, missing=missing, unproven_skips=invalid_skips, runner_s=sum(b-a for a,b in intervals),
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


def ref_sha(events, clock):
    previous = [e for e in events if e['timestamp'] <= clock]
    sha = previous[-1]['after'] if previous else events[0]['before'] if events else None
    return sha if sha and sha.strip('0') else None


TIMELINE = """
query($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
  repository(owner:$owner, name:$name) { pullRequest(number:$number) {
    baseRefName closedAt
    timelineItems(first:100, after:$endCursor, itemTypes:[
      BASE_REF_CHANGED_EVENT, AUTOMATIC_BASE_CHANGE_SUCCEEDED_EVENT, CLOSED_EVENT, REOPENED_EVENT
    ]) {
      pageInfo { hasNextPage endCursor }
      nodes {
        __typename
        ... on BaseRefChangedEvent { createdAt previous:previousRefName current:currentRefName }
        ... on AutomaticBaseChangeSucceededEvent { createdAt previous:oldBase current:newBase }
        ... on ClosedEvent { createdAt }
        ... on ReopenedEvent { createdAt }
      }
    }
  } }
}
"""


def pull_timeline(repo, pr):
    owner, name = repo.split('/')
    raw = subprocess.check_output(['gh', 'api', 'graphql', '--paginate', '--slurp', '-f', 'query=' + TIMELINE,
                                   '-f', 'owner=' + owner, '-f', 'name=' + name, '-F', 'number=' + str(pr['number'])])
    pages = [page['data']['repository']['pullRequest'] for page in json.loads(raw)]
    # A mutation between pages cannot establish which base or lifecycle the assembled history describes.
    if (not pages or any(not p or p['baseRefName'] != pages[0]['baseRefName'] or p['closedAt'] != pages[0]['closedAt'] for p in pages)
            or pages[-1]['timelineItems']['pageInfo']['hasNextPage']):
        return pr, None
    return dict(pr, base={'ref': pages[0]['baseRefName']}, closed_at=pages[0]['closedAt']), [e for p in pages for e in p['timelineItems']['nodes']]


def main_periods(pr, events):
    """Yield intervals when the PR was both open and targeted main, or a gap for contradictory timeline evidence."""
    if events is None or any(not e or not e.get('createdAt') for e in events):
        return [(pr['created_at'], pr['closed_at'], 'base_history_unavailable')]
    events = sorted(events, key=lambda e: e['createdAt'])
    base = pr['base']['ref']
    changes = [e for e in events if e['__typename'] in ('BaseRefChangedEvent', 'AutomaticBaseChangeSucceededEvent')]
    for change in reversed(changes):
        if not base or change.get('current') != base or not change.get('previous'):
            return [(pr['created_at'], pr['closed_at'], 'base_history_unavailable')]
        base = change['previous']
    opened = True
    start = pr['created_at'] if base == 'main' else None
    intervals = []
    for e in events:
        action = e['__typename']
        if action == 'ClosedEvent':
            opened = False
        elif action == 'ReopenedEvent':
            opened = True
        else:
            base = e['current']
        if opened and base == 'main':
            if start is None:
                start = e['createdAt']
        elif start is not None:
            intervals.append((start, e['createdAt'], None))
            start = None
    if start is not None:
        intervals.append((start, pr['closed_at'], None))
    return intervals


def eligible(repo, since, activity, pulls):
    """Enumerate qualifying ref creations and open PR heads before consulting workflow runs."""
    refs = defaultdict(list)
    heads = {}
    periods = defaultdict(list)

    def add(event, owner, ref, sha, stamp, number=None, reason=None, closed=None):
        key = (event, owner, ref, sha, stamp, number)
        heads[key] = dict(event=event, head_repository=owner, ref=ref, sha=sha, start=None if reason else stamp,
                          observed_at=stamp, pull_request=number, closed_at=closed, runs=[], coverage_gap=reason)

    for e in sorted(activity, key=lambda e: (e['timestamp'], e.get('id', 0))):
        if e['activity_type'] in ('branch_creation', 'push', 'force_push', 'branch_deletion', 'merge_queue_merge', 'pr_merge'):
            refs[e['ref']].append(e)
        if e['activity_type'] == 'branch_creation' and e['ref'].startswith(QUEUE):
            add('merge_group', repo, e['ref'], e['after'], e['timestamp'])

    for pr, transitions in pulls:
        head = pr['head']
        owner = (head.get('repo') or {}).get('full_name')
        if owner and owner.casefold() == repo.casefold():
            owner = repo
        ref = 'refs/heads/' + head['ref']
        events = refs[ref] if owner == repo else []
        for opened, clock, gap in main_periods(pr, transitions):
            if clock is not None and ts(clock) <= ts(since):
                continue
            periods[owner, ref].append((opened, clock, pr['number']))
            if gap or owner != repo:
                observed = opened if ts(opened) >= ts(since) else since
                add('pull_request', owner, ref, head['sha'], observed, pr['number'], gap or 'fork_ref_history_unavailable', clock)
                continue
            sha = ref_sha(events, opened)
            add('pull_request', owner, ref, sha, opened, pr['number'], None if sha else 'opening_head_unavailable', clock)
            for e in events:
                if opened <= e['timestamp'] and (clock is None or e['timestamp'] < clock) and e['activity_type'] in ('push', 'force_push', 'branch_creation'):
                    add('pull_request', owner, ref, e['after'], e['timestamp'], pr['number'], closed=clock)
    return list(heads.values()), refs, periods


def attach_runs(rows, runs, repo, periods):
    groups = defaultdict(list)
    for row in rows:
        groups[row['event'], row['head_repository'], row['ref'], row['sha']].append(row)
    for run in runs:
        owner = (run.get('head_repository') or {}).get('full_name')
        if owner and owner.casefold() == repo.casefold():
            owner = repo
        key = (run['event'], owner, 'refs/heads/' + run['head_branch'], run['head_sha'])
        numbers = {pr['number'] for pr in run.get('pull_requests', [])}
        matching = [r for r in groups[key] if ts(r['observed_at']) <= ts(run['created_at']) and
                    (not r['closed_at'] or run['created_at'] < r['closed_at']) and (not numbers or not r['pull_request'] or r['pull_request'] in numbers)]
        if matching:
            max(matching, key=lambda r: ts(r['observed_at']))['runs'].append(run['id'])
            continue
        event, owner, ref, sha = key
        stamp = run['created_at']
        prs = [(number, closed) for opened, closed, number in periods[owner, ref] if opened <= stamp and
               (not closed or stamp < closed) and (not numbers or number in numbers)]
        if (event == 'merge_group' and owner == repo and ref.startswith(QUEUE)) or (event == 'pull_request' and len(prs) == 1):
            row = dict(event=event, head_repository=owner, ref=ref, sha=sha, start=None, observed_at=stamp,
                       pull_request=prs[0][0] if prs else None, closed_at=prs[0][1] if prs else None, runs=[run['id']], coverage_gap='ref_clock_unavailable')
            rows.append(row)
            groups[key].append(row)


def non_tooling_files(files):
    if len(files) >= 300:  # GitHub caps the compare response's file list.
        return False
    tooling = ('scripts', 'Makefile', '.github/workflows/gate.yml', '.github/workflows/reference-baseline.yml', '.github/workflows/nightly.yml')
    return not any(name.startswith('scripts/') or name in tooling for f in files for name in (f['filename'], f.get('previous_filename', '')))


def collect(repo, since, until):
    def pages(endpoint):
        raw = subprocess.check_output(['gh', 'api', '--paginate', '--slurp', f'repos/{repo}/{endpoint}'])
        return json.loads(raw)

    def items(endpoint):
        return [item for page in pages(endpoint) for item in page]

    rules = [rule for rule in items('rules/branches/main') if rule['type'] == 'required_status_checks']
    required = {c['context'] for rule in rules for c in rule['parameters']['required_status_checks']}
    if not required:
        raise ValueError('no required check contexts reported by the main branch rules')
    activity = items('activity?per_page=100&time_period=month')
    prs = [pr for pr in items('pulls?state=all&sort=updated&direction=desc&per_page=100')
           if ts(pr['created_at']) <= ts(until) and (not pr['closed_at'] or ts(pr['closed_at']) >= ts(since))]
    with ThreadPoolExecutor(max_workers=6) as pool:
        rows, refs, periods = eligible(repo, since, activity, pool.map(partial(pull_timeline, repo), prs))
    runs = {}
    # A head at the window boundary can start its workflows later. Read through collection time
    # in short ranges to stay within the Actions API's 1,000-result ceiling.
    now = datetime.now(timezone.utc)
    lower = datetime.fromtimestamp(ts(since), timezone.utc)
    if lower > now or lower < now - timedelta(days=30) or ts(until) < ts(since) or ts(until) > now.timestamp():
        raise ValueError('window must be ordered and within the last 30 days of repository activity')
    while lower < now:
        upper = min(lower + timedelta(days=5), now)
        dates = '..'.join(d.strftime('%Y-%m-%dT%H:%M:%SZ') for d in (lower, upper))
        for event in ('pull_request', 'merge_group'):
            query = urlencode(dict(event=event, created=dates, per_page=100))
            for workflow in ('gate.yml', 'reference-baseline.yml'):
                result = pages(f'actions/workflows/{workflow}/runs?{query}')
                selected = [run for page in result for run in page['workflow_runs']]
                if len({r['id'] for r in selected}) != result[0]['total_count']:
                    raise ValueError('incomplete Actions query; reduce the workflow run query interval')
                runs.update((r['id'], r) for r in selected)
        lower = upper
    attach_runs(rows, sorted(runs.values(), key=lambda r: r['created_at']), repo, periods)
    rows = [r for r in rows if ts(since) <= ts(r['observed_at']) <= ts(until)]

    def jobs(run):
        result = pages(f"actions/runs/{run['id']}/jobs?per_page=100&filter=all")
        rows = [j for page in result for j in page['jobs']]
        if len({j['id'] for j in rows}) != result[0]['total_count'] or any(j['head_sha'] != run['head_sha'] for j in rows):
            raise ValueError(f"incomplete or mismatched job list for run {run['id']}")
        return run['id'], rows

    matched = {run_id for row in rows for run_id in row['runs']}
    with ThreadPoolExecutor(max_workers=6) as pool:
        work = dict(pool.map(jobs, (runs[run_id] for run_id in matched)))
    result = []
    for info in rows:
        executed = [j for run_id in info['runs'] for j in work[run_id]]
        non_tooling = False
        if info['event'] == 'pull_request' and info['start'] and any(j['name'] == CONTROLS and j['conclusion'] == 'skipped' for j in executed):
            base = ref_sha(refs['refs/heads/main'], info['start'])
            if base:
                compared = pages(f"compare/{base}...{info['sha']}?per_page=100")
                non_tooling = non_tooling_files(compared[0]['files'])
        row = candidate(info['start'], required, executed, event=info['event'], non_tooling=non_tooling)
        row['tooling_controls'] = any(step['name'] in ('Run make test-reference', 'Run make test-oracle') and step['conclusion'] != 'skipped'
                                      for j in executed for step in j['steps'])
        result.append(dict(**info, **row))
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
