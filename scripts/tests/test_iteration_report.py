"""Measure whole-candidate latency, including queue pickup and failed-attempt recovery."""
import unittest

from github.iteration_report import candidate, compare_budget, cost_groups, summary

STAMP = '2026-11-23T00:00:%02dZ'


def job(name, start, end, outcome, attempt=1):
    return dict(name=name, started_at=STAMP % start, completed_at=STAMP % end,
                created_at=STAMP % 1, conclusion=outcome, steps=[], run_id=1, run_attempt=attempt)


class IterationReportTests(unittest.TestCase):
    def test_retry_counts_elapsed_and_both_runner_allocations(self):
        jobs = [job('Gate', 3, 8, 'failure'), job('Qual', 2, 19, 'success'), job('Gate', 23, 33, 'success', 2)]
        row = candidate(STAMP % 0, {'Gate', 'Qual'}, jobs)
        self.assertEqual((row['outcome'], row['elapsed_s'], row['first_failure_s'], row['runner_s']), ('success', 33, 8, 32))
        self.assertEqual(row['retry_recovery_s'], 25)
        self.assertEqual(row['peak_runners'], 2)

    def test_missing_cancelled_and_unknown_clock_cannot_establish_target(self):
        for origin, jobs in [(STAMP % 0, []), (STAMP % 0, [job('Gate', 1, 2, 'cancelled')]), (None, [job('Gate', 1, 2, 'success')])]:
            with self.subTest(origin=origin, jobs=jobs):
                row = candidate(origin, {'Gate'}, jobs)
                self.assertFalse(summary([row] * 40)['target_verified'])

    def test_nearest_rank_p95_and_strict_target(self):
        rows = [dict(outcome='success', elapsed_s=time, runner_s=1) for time in [280] * 37 + [300] * 3]
        self.assertIsNone(summary(rows[:-1])['p95_s'])
        self.assertEqual(summary(rows)['p95_s'], 300)
        self.assertFalse(summary(rows)['target_verified'])

    def test_seven_minute_ceiling_counts_individual_completed_breaches(self):
        rows = [dict(outcome='success', elapsed_s=t, runner_s=1) for t in [299, 300, 419, 420]]
        self.assertEqual(summary(rows)['ceiling_breaches'], 1)
        self.assertFalse(summary(rows)['p95_ceiling_verified'])
        self.assertTrue(summary(rows[:3] * 14)['p95_ceiling_verified'])
        self.assertFalse(summary(rows * 10)['p95_ceiling_verified'])

    def test_runner_budget_accounts_for_the_change_mix(self):
        def row(tooling, seconds):
            return dict(event='pull_request', tooling_controls=tooling, runner_s=seconds, outcome='success')
        baseline = [row(True, 90), row(False, 10)]
        candidate_rows = [row(True, 92), row(True, 92), row(False, 10)]
        self.assertTrue(compare_budget(cost_groups(baseline), candidate_rows)['within_budget'])
        self.assertFalse(compare_budget(cost_groups(baseline), [row(False, 11)])['within_budget'])
        self.assertFalse(compare_budget(cost_groups(baseline[:1]), candidate_rows)['comparable'])

    def test_unstarted_heads_and_reopen_intervals_come_from_ref_history(self):
        from github.iteration_report import QUEUE, attach_runs, eligible
        repo = 'owner/project'
        ref = 'refs/heads/feature'
        def event(clock, before, after, branch=ref, action='push'):
            return dict(timestamp=STAMP % clock, before=before, after=after, ref=branch, activity_type=action)
        activity = [event(1, '0', 'a', action='branch_creation'), event(6, 'a', 'b'), event(9, 'b', 'c'),
                    event(15, 'c', 'd'), event(18, '0', 'x', QUEUE + 'pr-1', 'branch_creation')]
        pr = dict(number=1, base={'ref': 'main'}, created_at=STAMP % 4, closed_at=None, head=dict(ref='feature', repo={'full_name': repo}, sha='d'))
        changes = [dict(createdAt=STAMP % 8, __typename='ClosedEvent'), dict(createdAt=STAMP % 13, __typename='ReopenedEvent')]
        rows, _, periods = eligible(repo, STAMP % 0, activity, [(pr, changes)])
        self.assertEqual([(r['sha'], r['start']) for r in rows], [('x', STAMP % 18), ('a', STAMP % 4), ('b', STAMP % 6), ('c', STAMP % 13), ('d', STAMP % 15)])
        def run(number, clock, sha, branch='feature', owner=repo):
            return dict(id=number, event='pull_request', head_repository={'full_name': owner}, head_branch=branch, head_sha=sha, created_at=STAMP % clock)
        attach_runs(rows, [run(1, 5, 'a'), run(2, 7, 'b', owner='fork/project'), run(3, 10, 'z'),
                           run(7, 11, 'a'), run(4, 16, 'd', branch='unrelated'), run(5, 25, 'd'), run(6, 26, 'unknown')], repo, periods)
        self.assertEqual([(r['sha'], r['runs']) for r in rows], [('x', []), ('a', [1]), ('b', []), ('c', []), ('d', [5]), ('unknown', [6])])
        self.assertIsNone(rows[-1]['start'])
        for r in rows[:1] + rows[2:4]:
            self.assertEqual(candidate(r['start'], {'Gate'}, r['runs'])['outcome'], 'incomplete')

    def test_retargeting_opens_and_closes_only_the_main_intervals(self):
        from github.iteration_report import attach_runs, eligible
        repo, ref = 'org/repo', 'refs/heads/topic'
        activity = [dict(activity_type='push', ref=ref, before=str(c - 1), after=str(c), timestamp=STAMP % c) for c in (1, 5, 9, 14)]
        pr = dict(number=7, created_at=STAMP % 3, closed_at=None, head=dict(ref='topic', repo={'full_name': repo}, sha='14'))
        for event, before, after, expected in (
                ('BaseRefChangedEvent', 'main', 'release', [('1', 3), ('5', 5)]),
                ('AutomaticBaseChangeSucceededEvent', 'release', 'main', [('5', 8), ('9', 9), ('14', 14)])):
            with self.subTest(event=event):
                change = dict(__typename=event, createdAt=STAMP % 8, previous=before, current=after)
                rows, _, periods = eligible(repo, STAMP % 0, activity, [(dict(pr, base={'ref': after}), [change])])
                self.assertEqual([(r['sha'], r['start']) for r in rows], [(sha, STAMP % t) for sha, t in expected])
                runs = [dict(id=t, event='pull_request', head_repository={'full_name': repo}, head_branch='topic', head_sha='5',
                             created_at=STAMP % t, pull_requests=[{'number': 7}]) for t in (6, 8, 10)]
                attach_runs(rows, runs, repo, periods)
                owner = next(r for r in rows if r['sha'] == '5')
                self.assertEqual(owner['runs'], [6] if before == 'main' else [8, 10])

    def test_paginated_base_timeline_keeps_previous_and_new_target(self):
        import json
        from unittest.mock import patch
        from github.iteration_report import main_periods, pull_timeline
        pr = dict(number=7, created_at=STAMP % 1, closed_at=None, base={'ref': 'release'})
        events = [dict(__typename='BaseRefChangedEvent', createdAt=STAMP % 3, previous='main', current='release'),
                  dict(__typename='AutomaticBaseChangeSucceededEvent', createdAt=STAMP % 8, previous='release', current='main')]
        def page(index):
            result = dict(timelineItems=dict(pageInfo={'hasNextPage': index == 0}, nodes=[events[index]]), baseRefName='main', closedAt=None)
            return dict(data=dict(repository=dict(pullRequest=result)))
        with patch('github.iteration_report.subprocess.check_output', return_value=json.dumps([page(0), page(1)])) as api:
            updated, changes = pull_timeline('org/repo', pr)
        self.assertIn('--paginate', api.call_args.args[0])
        self.assertEqual(main_periods(updated, changes), [(STAMP % 1, STAMP % 3, None), (STAMP % 8, None, None)])

    def test_unknown_base_history_prevents_a_passing_denominator(self):
        from github.iteration_report import eligible
        repo = 'org/repo'
        pr = dict(number=7, base={'ref': 'release'}, created_at=STAMP % 0, closed_at=None,
                  head=dict(ref='topic', repo={'full_name': repo}, sha='abc'))
        change = dict(__typename='BaseRefChangedEvent', createdAt=STAMP % 2, previous='main', current='elsewhere')
        for events in ([change], [None], None):
            rows, _, _ = eligible(repo, STAMP % 1, [], [(pr, events)])
            gap, = rows
            self.assertEqual((gap['coverage_gap'], gap['observed_at'], gap['start']), ('base_history_unavailable', STAMP % 1, None))
            self.assertEqual(candidate(gap['start'], {'Gate'}, [job('Gate', 1, 2, 'success')])['outcome'], 'incomplete')

    def test_fork_activity_cannot_be_inferred_from_same_named_base_ref(self):
        from github.iteration_report import eligible
        info = dict(number=1, base={'ref': 'main'}, created_at=STAMP % 1, closed_at=None, head=dict(ref='topic', sha='a', repo={'full_name': 'fork/project'}))
        activity = [dict(activity_type='push', ref='refs/heads/topic', before='0', after='a', timestamp=STAMP % 2)]
        rows, _, _ = eligible('base/project', STAMP % 0, activity, [(info, [])])
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0]['start'])
        self.assertEqual(rows[0]['coverage_gap'], 'fork_ref_history_unavailable')

    def test_legacy_controls_skip_needs_the_old_gate_and_independent_evidence(self):
        from github.iteration_report import CONTROLS, non_tooling_files
        skipped = job(CONTROLS, 1, 1, 'skipped')
        unit = job('Changed unit suites (Godot 4.3)', 1, 2, 'success')
        def step(name):
            return dict(name=name, conclusion='success', started_at=STAMP % 1, completed_at=STAMP % 2)
        unit['steps'] = [step('Run the affected unit suites')]
        detector = job('Detect tooling changes', 1, 2, 'success')
        full = job('Reference negative controls', 1, 2, 'success')
        full['steps'] = [step('Run make test-reference'), step('Run make test-oracle')]
        def outcome(event, jobs, non_tooling=False):
            return candidate(STAMP % 0, {CONTROLS}, jobs, event=event, non_tooling=non_tooling)['outcome']
        old = [unit, detector, skipped]
        self.assertEqual(outcome('pull_request', old, True), 'success')
        self.assertEqual(outcome('pull_request', old), 'incomplete')
        self.assertEqual(outcome('merge_group', old, True), 'incomplete')
        self.assertEqual(outcome('merge_group', old + [full]), 'success')
        unit['steps'] = [step('Verify partition receipts')]
        for event in ('merge_group', 'pull_request'):
            self.assertEqual(outcome(event, old + [full], True), 'incomplete')
        self.assertTrue(non_tooling_files([{'filename': 'docs/README.md'}]))
        self.assertFalse(non_tooling_files([{'filename': 'docs/probe', 'previous_filename': 'scripts/probe'}]))
        self.assertFalse(non_tooling_files([{'filename': 'a'}] * 300))

    def test_missing_pickup_and_start_clocks_cannot_pass(self):
        for name in ('created_at', 'started_at', 'completed_at'):
            row = job('Gate', 1, 2, 'success')
            row[name] = None
            self.assertEqual(candidate(STAMP % 0, {'Gate'}, [row])['outcome'], 'incomplete')

    def test_collect_lists_queue_creation_even_without_workflow_runs(self):
        from datetime import datetime, timedelta, timezone
        import json
        from unittest.mock import patch
        from github.iteration_report import collect, QUEUE
        clock = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
        def response(command):
            endpoint = command[-1].removeprefix('repos/test/repo/')
            if endpoint.startswith('activity?'):
                page = [dict(timestamp=clock, ref=QUEUE + 'pr-42', after='a', before='0', activity_type='branch_creation')]
            elif endpoint == 'rules/branches/main':
                page = [dict(type='required_status_checks', parameters={'required_status_checks': [{'context': 'Gate'}]})]
            elif endpoint.startswith('pulls?'):
                self.assertNotIn('base=', endpoint)
                page = []
            elif endpoint.startswith('actions/workflows/'):
                page = dict(total_count=0, workflow_runs=[])
            else:
                self.fail(endpoint)
            return json.dumps([page]).encode()
        with patch('github.iteration_report.subprocess.check_output', side_effect=response):
            report = collect('test/repo', clock, clock)
        row, = report['candidates']
        self.assertEqual((row['sha'], row['start'], row['outcome'], row['missing']), ('a', clock, 'incomplete', ['Gate']))
        self.assertFalse(report['summary']['merge_group']['target_verified'])
