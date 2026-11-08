"""Rejected ownership-run gates split from the original single suite for bounded parallel files."""

import json
import subprocess
from unittest import mock

import ownership_probes as probes
from ownership_rejection_fixture import BROWSER_DETAIL, BROWSER_LOG, OwnershipRejectionFixture, assert_rejection_observed


class OwnershipRejectionDiagnosisTests(OwnershipRejectionFixture):
    # Value: protects=download failures leave a terminal diagnosis; fails_when=any gate error leaves a running round;
    # why_new=ordinary browser-batch rejection does not cover downloads; seam=mocked tool outputs and real source inventories
    def test_download_gate_failures_keep_bounded_failed_rounds(self):
        part = next(part for part in ('1', '2') if 'res://tests/unit/test_replay_viewer_prefix.gd' in probes.select_suites(part))
        diagnostics = {
            'run': 'download command failure ', 'json': 'Expecting property name enclosed in double quotes',
            'browser': 'browser reported errors', 'download': 'replay download boundary differs',
            'control-capture': 'download control capture failure', 'control': 'replay download control failed outside its expected diagnostic:',
            'source': 'ownership source changed during execution: scripts/reference/browser/ownership.cjs',
            'staged': 'ownership staged project changed during execution', 'tools': 'ownership runtime inputs changed during execution',
        }
        for fault, diagnostic in diagnostics.items():
            with self.subTest(fault=fault):
                results = self.scenario(expected=Exception, version='4.3', phase='positive', suite_part=part, download_fault=fault)
                self.assertFalse((results / 'ownership.json').exists())
                entry = self.rounds(results)[0]
                self.assertEqual(entry['outcome'], 'failed')
                self.assertIs(entry['alive'], False)
                self.assertIsInstance(entry['seconds'], (int, float))
                self.assertTrue(entry['errors'])
                self.assertEqual(entry['errors'], probes.bounded_errors(entry['errors']))
                self.assertTrue(entry['errors'][0].startswith(diagnostic), entry['errors'])

    # Value: protects=negative controls reject cleanup failure; fails_when=expected text inside AggregateError passes; seam=mocked owned-child output
    def test_download_controls_reject_expected_error_with_cleanup_failure(self):
        part = next(part for part in ('1', '2') if 'res://tests/unit/test_replay_viewer_prefix.gd' in probes.select_suites(part))
        for name, diagnostic in probes.CONTROL_DIAGNOSTICS.items():
            with self.subTest(control=name):
                output = ('AggregateError: ownership and cleanup failed\n'
                          '    at main (/fixture/ownership.cjs:100:9)\n'
                          '  [errors]: [\n'
                          '    Error: ' + diagnostic + '\n'
                          '        at operation (/fixture/replay_download.cjs:20:3),\n'
                          '    Error: browser cleanup failed\n'
                          '        at cleanup (/fixture/ownership.cjs:90:3)\n'
                          '  ]\n')
                results = self.scenario(expected=ValueError, version='4.3', phase='positive', suite_part=part,
                                        control_output={name: output})
                self.assertFalse((results / 'ownership.json').exists())
                entry = self.rounds(results)[0]
                self.assertEqual(entry['outcome'], 'failed')
                self.assertIs(entry['alive'], False)
                self.assertEqual(entry['errors'], ['replay download control failed outside its expected diagnostic: ' + name])

    # Value: protects=divergent case pages cannot publish or leave a running round; fails_when=assembly trusts repeats only; why_new=suite-level failures; seam=mocked browser
    def test_case_page_divergence_keeps_a_failed_round_and_no_receipt(self):
        suite = 'res://tests/unit/test_driver_peer_parity.gd'
        part = next(part for part in ('1', '2') if suite in probes.select_suites(part))
        results = self.scenario(expected=ValueError, selected='firefox', version='4.3', phase='positive', suite_part=part, browser_fault='case_assertions')
        self.assertFalse((results / 'ownership.json').exists())
        self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')
        self.assertEqual(self.rounds(results)[0]['errors'], ['incomplete or divergent ownership case pages'])

    def test_browser_executes_frozen_node_after_path_alias_replacement(self):
        for selected in ('chromium', 'firefox'):
            with self.subTest(selected=selected):
                self.scenario(expected=None, selected=selected, version='4.3', node_alias=True)

    def test_a_rejected_browser_run_retains_its_diagnosis(self):
        results = self.scenario(BROWSER_LOG)
        rounds = self.rounds(results)
        self.assertEqual(len(rounds), 1, 'the rejected round is the only one that ran')
        assert_rejection_observed(self, rounds[0])
        self.assertFalse((results / 'ownership.json').exists(), 'a rejected run publishes no receipt')

    def test_the_receipt_keeps_the_enriched_round_entries(self):
        results = self.scenario(expected=None)
        receipt = json.loads((results / 'ownership.json').read_text(encoding='utf-8'))
        self.assertEqual(receipt['versions_requested'], ['4.3', '4.7.2'])
        self.assertEqual(receipt['phases_requested'], ['negative', 'positive'])
        self.assertEqual(receipt['suite_part_requested'], 'all')
        self.assertEqual(receipt['suites_requested'], {suite: sorted(cases) for suite, cases in probes.EXPECTED.items()})
        self.assertEqual([entry['label'] for entry in receipt['rounds']],
                         ['4.3-negative', '4.3-positive', '4.7.2-negative', '4.7.2-positive'])
        for entry in receipt['rounds']:
            self.assertEqual(entry['outcome'], 'passed')
            for field in ('alive', 'native_progress', 'browser_progress', 'errors', 'seconds'):
                self.assertIn(field, entry, 'the receipt keeps the enriched round fields')
            self.assertEqual(entry['native_progress']['case'], 'parity')
        self.assertEqual(receipt['rounds'], self.rounds(results),
                         'the receipt keeps the same enriched round entries the run observed')

    def test_a_mutant_that_discards_the_diagnosis_fails_the_observation(self):
        with mock.patch.object(probes, 'bounded_progress', return_value=None), \
                mock.patch.object(probes, 'bounded_errors', return_value=[]):
            results = self.scenario(BROWSER_LOG)
        with self.assertRaises(AssertionError):
            assert_rejection_observed(self, self.rounds(results)[0])

    def test_a_browser_failure_without_a_watchdog_detail_is_a_failure(self):
        results = self.scenario('node: the browser runner crashed\n')
        entry = self.rounds(results)[0]
        self.assertEqual(entry['outcome'], 'failed')
        self.assertFalse(entry['alive'])
        self.assertIn('node: the browser runner crashed', ' '.join(entry['errors']))

    def test_a_native_deadline_keeps_the_case_it_was_executing(self):
        results = self.scenario(native_timeout=True, expected=subprocess.TimeoutExpired)
        entry = self.rounds(results)[0]
        self.assertEqual(entry['outcome'], 'progressing')
        self.assertEqual(entry['native_progress']['case'], 'parity')
        self.assertEqual(entry['native_progress']['elapsed'], 18)
        self.assertFalse(entry['alive'], 'the native child was killed by the deadline')
        self.assertFalse((results / 'ownership.json').exists(), 'a rejected run publishes no receipt')

    # Value: protects=every browser batch's metadata; fails_when=an earlier malformed result is overwritten; why_new=single browser runs cannot erase prior metadata; seam=none
    def test_browser_metadata_is_checked_before_aggregation(self):
        for mutation in ('unknown', 'missing_errors', 'missing_version', 'false_errors', 'null_errors',
                         'empty_version', 'numeric_version', 'wrong_browser', 'changed_version'):
            with self.subTest(mutation=mutation):
                results = self.scenario(browser_fault=mutation, expected=ValueError)
                self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')
                self.assertFalse((results / 'ownership.json').exists())

    # Value: protects=per-child exit and completion checks; fails_when=negative verdict leaks to healthy suites; why_new=aggregation has no process status; seam=none
    def test_later_native_batch_rejects_wrong_exit_incomplete_output_and_engine_errors(self):
        for mutation in ('wrong_exit', 'missing_marker', 'duplicate_marker', 'script_error', 'engine_error'):
            with self.subTest(mutation=mutation):
                results = self.scenario(native_fault=mutation, expected=ValueError)
                self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')
                self.assertFalse((results / 'ownership.json').exists())
                self.assertEqual(len(list(results.glob('ownership-*-native-*.log'))), 2)

    # Value: protects=partial batch evidence; fails_when=later timeout hides completed batch or last case; why_new=first-child timeout cannot catch overwrites; seam=none
    def test_later_native_timeout_keeps_each_log_and_last_case(self):
        results = self.scenario(native_fault='timeout', expected=subprocess.TimeoutExpired)
        entry = self.rounds(results)[0]
        self.assertEqual(entry['outcome'], 'progressing')
        self.assertEqual(entry['native_progress']['case'], 'parity')
        self.assertFalse((results / 'ownership.json').exists())
        logs = list(results.glob('ownership-*-native-*.log'))
        self.assertEqual(len(logs), 2)
        self.assertTrue(all(probes.PROGRESS_PREFIX in log.read_text(encoding='utf-8') for log in logs))

    def test_the_retained_observation_is_bounded(self):
        noisy = json.dumps({**BROWSER_DETAIL, 'errors': [f'engine error {index}' for index in range(50)]})
        results = self.scenario(noisy + '\n')
        entry = self.rounds(results)[0]
        self.assertEqual(len(entry), 8, 'a round keeps a fixed number of fields')
        self.assertEqual(len(entry['errors']), probes.MAX_RETAINED_ERRORS)
        self.assertEqual(len(entry['browser_progress']), 7, 'a progress record keeps a fixed number of fields')
        self.assertEqual(entry['browser_progress']['case'], 'golden')

