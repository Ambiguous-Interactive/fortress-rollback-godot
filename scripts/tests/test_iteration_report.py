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
        self.assertEqual(summary(rows)['p95_s'], 300)
        self.assertFalse(summary(rows)['target_verified'])

    def test_runner_budget_accounts_for_the_change_mix(self):
        def row(tooling, seconds):
            return dict(event='pull_request', tooling_controls=tooling, runner_s=seconds, outcome='success')
        baseline = [row(True, 90), row(False, 10)]
        candidate_rows = [row(True, 92), row(True, 92), row(False, 10)]
        self.assertTrue(compare_budget(cost_groups(baseline), candidate_rows)['within_budget'])
        self.assertFalse(compare_budget(cost_groups(baseline), [row(False, 11)])['within_budget'])
        self.assertFalse(compare_budget(cost_groups(baseline[:1]), candidate_rows)['comparable'])
