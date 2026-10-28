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
        self.assertEqual(len(recording.acceptance(observed)), 56)
        self.assertEqual(len(recording.controls(observed)), 22)

    # Value: protects=original request evidence; fails_when=status/order/saved state is discarded; why_new=exported rows do not prove callbacks; seam=none
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


if __name__ == '__main__':
    unittest.main()
