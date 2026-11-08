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
            for part in ('1', '2'):
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

