"""Rejected ownership-run gates split from the original single suite for bounded parallel files."""

import copy
import json

import ownership_probes as probes
from ownership_rejection_fixture import OwnershipRejectionFixture


class OwnershipFullInventoryTests(OwnershipRejectionFixture):
    # Value: protects=Firefox qualifies every native case and control with pinned runtime provenance;
    # fails_when=another browser substitutes, runtime mutates, or Firefox weakens inventory; why_new=old orchestrator only supported Chromium; seam=none
    def test_firefox_runs_complete_inventory_for_both_pins(self):
        results = self.scenario(expected=None, selected='firefox')
        receipt = json.loads((results / 'ownership.json').read_text())
        self.assertEqual(receipt['phases_requested'], ['negative', 'positive'])
        self.assertEqual(receipt['browser_requested'], 'firefox')
        self.assertTrue(receipt['browser_runtime_inventory'])
        self.assertTrue(any('firefox_executable' in key for key in receipt['browser_runtime_inventory']))
        self.assertEqual(len(receipt['records']), 4)
        for row in receipt['records']:
            self.assertEqual(row['browser_artifact'], 'firefox-1495-ubuntu24.04-x86_64.zip')
            self.assertEqual(row['browser']['browser'], 'Firefox')
            self.assertEqual(row['browser']['result'], row['native'])
            self.assertEqual(row['native']['count'], probes.EXPECTED_COUNT)

    # Value: protects=CI parts run both real controls with exact declared native/Web coverage; fails_when=selector drops work; why_new=whole-run orchestration; seam=none
    def test_suite_parts_run_exact_declared_inventory_and_both_controls(self):
        for browser in ('firefox', 'chromium'):
            for part in ('1', '2', '3', '4'):
                with self.subTest(browser=browser, part=part):
                    results = self.scenario(expected=None, selected=browser, version='4.3', suite_part=part)
                    receipt = json.loads((results / 'ownership.json').read_text())
                    selected = probes.select_suites(part)
                    self.assertEqual(receipt['suite_part_requested'], part)
                    self.assertEqual(receipt['suites_requested'], {suite: sorted(cases) for suite, cases in selected.items()})
                    self.assertEqual([row['negative_control'] for row in receipt['records']], [True, False])
                    for row in receipt['records']:
                        self.assertEqual(row['native']['count'], sum(map(len, selected.values())))
                        self.assertEqual(row['browser']['result'], row['native'])

    # Value: protects=both Chromium phases cover the complete native/Web inventory; fails_when=balancing omits a control or adds an overlap; seam=mocked tools
    def test_balanced_chromium_phases(self):
        for phase in ('negative', 'positive'):
            groups = [probes.select_suites(str(i), phase) for i in range(1, 5)]
            for suite in probes.EXPECTED:
                self.assertEqual(sum(suite in group for group in groups), 4 if suite == probes.ALIAS_CONTROL else 1)
            loads = [sum(probes.chromium_seconds(suite, phase) for suite in group) for group in groups]
            self.assertLessEqual(max(loads) - min(loads), 2)
            part = next(i for i, group in enumerate(groups, 1) if probes.DOWNLOAD_SUITE in group)
            if phase == 'positive':
                ordinary_work = [sum(probes.chromium_seconds(suite) for suite in group) for group in groups]
                self.assertGreaterEqual(min(value for i, value in enumerate(ordinary_work, 1) if i != part) - ordinary_work[part - 1], 90)
            results = self.scenario(expected=None, version='4.3', phase=phase, suite_part=str(part), balance_chromium=True)
            receipt = json.loads((results / 'ownership.json').read_text())
            self.assertIs(receipt['balanced_chromium'], True)
            self.assertEqual(receipt['suites_requested'], {suite: sorted(cases) for suite, cases in groups[part - 1].items()})
            record, = receipt['records']
            self.assertEqual(record['browser']['result'], record['native'])
            self.assertEqual(record['native']['count'], sum(map(len, groups[part - 1].values())))
            self.assertEqual(set(record['timings']['native_suite_seconds']), set(groups[part - 1]))
            self.assertEqual([suite for page in record['timings']['browser_pages'] for suite in page['suites']], sorted(groups[part - 1]))
            self.assertEqual('replay_download_controls' in record, phase == 'positive')
            self.assertEqual('replay_download_seconds' in record['timings'], phase == 'positive')

    def test_minimum_chromium_parts_execute_exact_native_and_browser_members(self):
        for phase in ('positive', 'negative'):
            groups = [probes.select_suites(f'{part}of5', phase) for part in range(1, 6)]
            self.assertEqual(set().union(*groups), set(probes.EXPECTED))
            for suite in probes.EXPECTED:
                self.assertEqual(sum(suite in group for group in groups), 5 if suite == probes.ALIAS_CONTROL else 1)
            results = self.scenario(expected=None, version='4.3', phase=phase, suite_part='5of5', balance_chromium=True)
            received = json.loads((results / 'ownership.json').read_text())
            selected = groups[4]
            self.assertEqual(received['suites_requested'], {s: sorted(cases) for s, cases in selected.items()})
            record, = received['records']
            self.assertEqual(record['native'], record['browser']['result'])
            self.assertEqual(record['native']['count'], sum(map(len, selected.values())))
            self.assertEqual(len([g for g in groups if probes.DOWNLOAD_SUITE in g]), 1)

    def test_balanced_chromium_runtime_mutation_rejects_the_active_wave(self):
        results = self.scenario(expected=ValueError, version='4.3', phase='positive', suite_part='5of5',
                                balance_chromium=True, runtime_fault='browser')
        self.assertFalse((results / 'ownership.json').exists())
        self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')

    # Value: protects=complete declared phase receipts; fails_when=missing controls or foreign pins publish; why_new=per-batch validation omits phase inventory; seam=none
    def test_completed_phase_inventory_rejects_missing_foreign_and_alias_phases(self):
        records = [{'engine_version': '4.3', 'negative_control': negative} for negative in (True, False)]
        rounds = [{'label': '4.3-' + label, 'outcome': 'passed'} for label in ('negative', 'positive')]
        probes.validate_phases(records, rounds, ['4.3'])
        for mutation in ('missing', 'foreign', 'alias', 'failed', 'wrong_label'):
            with self.subTest(mutation=mutation):
                altered_records, altered_rounds = copy.deepcopy(records), copy.deepcopy(rounds)
                if mutation == 'missing':
                    altered_records.pop()
                elif mutation == 'foreign':
                    altered_records[0]['engine_version'] = 'foreign'
                elif mutation == 'alias':
                    altered_records[0]['negative_control'] = 1
                elif mutation == 'failed':
                    altered_rounds[0]['outcome'] = 'failed'
                else:
                    altered_rounds[0]['label'] = 'foreign-negative'
                with self.assertRaises(ValueError):
                    probes.validate_phases(altered_records, altered_rounds, ['4.3'])

