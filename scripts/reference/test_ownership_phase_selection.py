"""Rejected ownership-run gates split from the original single suite for bounded parallel files."""

import json
from pathlib import Path
import tempfile
from unittest import mock

import ownership_probes as probes
from ownership_rejection_fixture import OwnershipRejectionFixture


class OwnershipPhaseSelectionTests(OwnershipRejectionFixture):
    # Value: protects=complete partial-phase receipts; fails_when=selector loses work or claims both; why_new=default-only runs; seam=none
    def test_each_selected_phase_runs_exact_inventory_and_declares_scope(self):
        for phase in ('negative', 'positive', 'both'):
            with self.subTest(phase=phase):
                results = self.scenario(expected=None, selected='firefox', version='4.3', phase=phase)
                receipt = json.loads((results / 'ownership.json').read_text())
                phases = ['negative', 'positive'] if phase == 'both' else [phase]
                self.assertEqual(receipt['phases_requested'], phases)
                self.assertEqual([row['label'] for row in receipt['rounds']], ['4.3-' + name for name in phases])
                self.assertEqual([row['negative_control'] for row in receipt['records']], [name == 'negative' for name in phases])
                for row in receipt['records']:
                    self.assertEqual(row['browser']['result'], row['native'])
                    self.assertEqual(row['native']['count'], probes.EXPECTED_COUNT)
                self.assertIn('requested engine pins, phases and suite inventory only', receipt['scope'])

    # Value: protects=engine CI partitions retain both controls and every case; fails_when=selector changes workload or pin; why_new=default-only orchestration; seam=none
    def test_one_selected_pin_runs_both_complete_rounds(self):
        for version in ('4.3', '4.7.2'):
            with self.subTest(version=version):
                results = self.scenario(expected=None, version=version)
                receipt = json.loads((results / 'ownership.json').read_text(encoding='utf-8'))
                self.assertEqual(receipt['versions_requested'], [version])
                self.assertEqual([row['label'] for row in receipt['rounds']], [version + '-negative', version + '-positive'])
                self.assertEqual([row['native']['count'] for row in receipt['records']], [probes.EXPECTED_COUNT] * 2)

    # Value: protects=exact phase declarations; fails_when=missing, mismatched or alias inventory publishes; why_new=unpartitioned inventory; seam=none
    def test_requested_phase_inventory_rejects_missing_mismatched_unknown_and_alias_values(self):
        records = [{'engine_version': '4.3', 'negative_control': False}]
        rounds = [{'label': '4.3-positive', 'outcome': 'passed'}]
        probes.validate_phases(records, rounds, ['4.3'], ['positive'])
        for phases in ([], ['negative'], ['positive', 'negative'], ['positive', 'positive'], ['unknown'], [False], [0], 'positive'):
            with self.subTest(phases=phases), self.assertRaises(ValueError):
                probes.validate_phases(records, rounds, ['4.3'], phases)
        for negative in (0, 1, None, 'positive'):
            with self.subTest(negative=negative), self.assertRaises(ValueError):
                probes.validate_phases([{'engine_version': '4.3', 'negative_control': negative}], rounds, ['4.3'], ['positive'])
        with self.assertRaises(ValueError):
            probes.validate_phases([], [], ['4.3'], ['positive'])

    def test_unknown_pin_or_phase_is_rejected_before_tool_qualification(self):
        for option, value in (('--version', 'untrusted'), ('--phase', 'unknown'), ('--phase', 'True'), ('--phase', '1'),
                              ('--suite-part', 'unknown'), ('--suite-part', 'True'), ('--suite-part', '1.0')):
            with self.subTest(option=option, value=value), tempfile.TemporaryDirectory() as directory:
                self.assert_invalid_execution_option(Path(directory), option, value)

    def assert_invalid_execution_option(self, directory, option, value):
        with (mock.patch.object(probes, 'CACHE', directory),
              mock.patch.object(probes, 'load_manifest', return_value={'godot': {'minimum': '4.3', 'current_stable': '4.7.2'}}),
              mock.patch.object(probes.host_capacity, 'acquire_when_free') as acquire,
              mock.patch.object(probes, 'run_probes') as execute,
              mock.patch('sys.argv', ['ownership_probes.py', option, value])):
            with self.assertRaises(SystemExit):
                probes.main()
            acquire.assert_not_called()
            execute.assert_not_called()

