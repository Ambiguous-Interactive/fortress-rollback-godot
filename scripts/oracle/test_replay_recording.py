"""Value: real recording applicability requires full history, coverage and independent roster inventory; seam=none."""
import copy
import unittest

import replay_recording as recording


class RecordingAcceptanceTest(unittest.TestCase):
    @staticmethod
    def observed(cases=None):
        cases = recording.corpus() if cases is None else cases
        return {runtime: dict(format=1, cases=[recording.expected(case, runtime == 'rust') for case in cases])
                for runtime in ('rust', 'godot')}

    def test_complete_recordings_and_paired_controls(self):
        observed = self.observed()
        self.assertEqual(len(recording.acceptance(observed)), 112)
        self.assertEqual(len(recording.controls(observed)), 40)

    # Value: protects=original request evidence; fails_when=status/order/saved state is discarded; why_new=exported rows do not prove callbacks; seam=none
    def test_lockstep_workloads_and_service_schedule_are_independent(self):
        observed = self.observed()
        for runtime in ('rust', 'godot'):
            lockstep = [case for case in observed[runtime]['cases'] if case['name'].endswith('-prediction0')]
            self.assertEqual(len(lockstep), 56)
            for delay in (0, 2):
                case = next(case for case in lockstep if case['name'] == f'record-5p-64-delay{delay}-prediction0')
                self.assertEqual(case['saves'], [])
                self.assertTrue(all(checksum is None for checksum in case['checksums']))
                self.assertEqual(len(case['advances']), 64)
                self.assertEqual(len(case['services']), (128 if delay == 0 else 65) if runtime == 'rust' else 64)
                changed = copy.deepcopy(observed)
                target = next(row for row in changed[runtime]['cases'] if row['name'] == case['name'])
                target['services'].pop(0)
                with self.assertRaisesRegex(ValueError, r'\.services:'):
                    recording.acceptance(changed)
            changed = copy.deepcopy(observed)
            changed[runtime]['cases'] = [case for case in changed[runtime]['cases'] if not case['name'].endswith('-prediction0')]
            with self.assertRaisesRegex(ValueError, 'incomplete recording workload inventory'):
                recording.acceptance(changed)

    def test_original_request_mutations_reject_at_the_changed_boundary(self):
        for runtime in ('rust', 'godot'):
            for fault in ('status', 'value', 'save-state', 'order', 'missing-save'):
                with self.subTest(runtime=runtime, fault=fault):
                    observed = self.observed()
                    case = next(case for case in observed[runtime]['cases'] if case['name'] == 'record-5p-64-delay2')
                    records = case['records']
                    index = next(i for i, row in enumerate(records) if row['kind'] == ('advance' if fault in ('status', 'value') else 'save')
                                 and row['frame'] == 31)
                    if fault == 'status':
                        records[index]['inputs'][2]['status'] = 'predicted'
                    elif fault == 'value':
                        records[index]['inputs'][2]['value'] ^= 1
                    elif fault == 'save-state':
                        records[index]['bytes'] = '00' * 16
                    elif fault == 'order':
                        records[index:index + 2] = reversed(records[index:index + 2])
                    else:
                        records.pop(index)
                    with self.assertRaisesRegex(ValueError, r'\.records(?:\[|:)'):
                        recording.acceptance(observed)

    def test_omitted_duplicate_and_reduced_corpus_cannot_qualify(self):
        for runtime in ('rust', 'godot'):
            for duplicate in (False, True):
                with self.subTest(runtime=runtime, duplicate=duplicate):
                    observed = self.observed()
                    cases = observed[runtime]['cases']
                    cases.append(copy.deepcopy(cases[0])) if duplicate else cases.pop()
                    with self.assertRaisesRegex(ValueError, 'incomplete recording workload inventory'):
                        recording.acceptance(observed)
        reduced = self.observed(recording.corpus()[:-1])
        with self.assertRaisesRegex(ValueError, 'incomplete recording workload inventory'):
            recording.acceptance(reduced)

    def test_recorded_frames_and_validation_coverage_are_not_equated(self):
        for runtime in ('rust', 'godot'):
            for fault in ('future', 'checksum', 'events', 'completion', 'numeric'):
                with self.subTest(runtime=runtime, fault=fault):
                    observed = self.observed()
                    case = next(case for case in observed[runtime]['cases'] if case['name'] == 'record-5p-64-delay2')
                    if fault == 'future':
                        case['total_frames'] = 64 if runtime == 'rust' else 65
                    elif fault == 'checksum':
                        case['checksums'][1] = '00' * 16 if runtime == 'rust' else None
                    elif fault == 'events' and runtime == 'rust':
                        case['playback']['events'] = [{'frame': 0, 'expected': '00' * 16, 'actual': '00' * 16}]
                    elif fault == 'events':
                        case['playback']['failure_frame'] = 0
                    elif fault == 'completion':
                        case['playback']['complete'] = False
                    else:
                        case['players'] = 5.0
                    with self.assertRaises(ValueError):
                        recording.acceptance(observed)

    def test_named_workload_cannot_hide_altered_inputs(self):
        for fault in ('delay', 'seed', 'count', 'players'):
            cases = recording.corpus()
            case = next(case for case in cases if case['name'] == 'record-5p-64-delay2')
            case[fault] -= 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                recording.acceptance(self.observed(cases))


class ContinuingExtractionTest(unittest.TestCase):
    # Value: protects=continued gameplay and owned extraction evidence; fails_when=source extraction consumes gameplay or rewrites old exports; seam=none
    def test_complete_extraction_and_controls(self):
        observed = {runtime: dict(format=1, cases=[recording.extraction_expected(case, runtime == 'rust')
                                                 for case in recording.extraction_corpus()]) for runtime in ('rust', 'godot')}
        self.assertEqual(len(recording.extraction_acceptance(observed)), 56)
        self.assertEqual(len(recording.extraction_controls(observed)), 12)
        for runtime in ('rust', 'godot'):
            for field, value in [('format', True), ('format', 1.0), ('format', 2), ('extra', None)]:
                changed = copy.deepcopy(observed)
                changed[runtime][field] = value
                with self.assertRaises(ValueError):
                    recording.extraction_acceptance(changed)
            changed = copy.deepcopy(observed)
            changed[runtime]['cases'].pop()
            with self.assertRaisesRegex(ValueError, 'incomplete continuing extraction inventory'):
                recording.extraction_acceptance(changed)


if __name__ == '__main__':
    unittest.main()
