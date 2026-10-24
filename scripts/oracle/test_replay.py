"""Full-roster replay acceptance must survive accidental corpus reductions."""
import copy
import unittest

import replay_launch as replay


class ReplayAcceptanceTest(unittest.TestCase):
    # Value: protects=source-bound acceptance cannot silently shrink; fails_when=missing workload earns green;
    # why_new=exact trace comparison alone trusts a reduced generated corpus; seam=none
    def test_missing_or_duplicate_workload_cannot_qualify(self):
        observed = self.observed()
        self.assertEqual(len(replay.acceptance_evidence(observed)), 21)
        for runtime, suffix in [('rust', ''), ('godot', ''), ('godot', '-expert')]:
            for duplicate in (False, True):
                with self.subTest(runtime=runtime, suffix=suffix, duplicate=duplicate):
                    changed = copy.deepcopy(observed)
                    cases = changed[runtime]['cases']
                    case = next(case for case in cases if case['name'] == '5p-64-sparse' + suffix)
                    if duplicate:
                        cases.append(copy.deepcopy(case))
                    else:
                        cases.remove(case)
                    # A regenerated expectation can agree exactly with the reduced corpus.
                    replay.compare(changed, copy.deepcopy(changed))
                    with self.assertRaisesRegex(ValueError, 'missing or duplicate acceptance workload'):
                        replay.acceptance_evidence(changed)

    # Value: protects=all player slots and interior failure execute; fails_when=shortened or incomplete trace qualifies;
    # why_new=workload labels alone cannot establish execution; seam=none
    def test_incomplete_execution_cannot_qualify(self):
        observed = self.observed()
        for runtime, suffix in [('rust', ''), ('godot', ''), ('godot', '-expert')]:
            for fault in ('frame', 'player', 'mismatch'):
                with self.subTest(runtime=runtime, suffix=suffix, fault=fault):
                    changed = copy.deepcopy(observed)
                    case = next(case for case in changed[runtime]['cases'] if case['name'] == '5p-64-middle-mismatch' + suffix)
                    if fault == 'frame':
                        case['records'].remove(next(record for record in case['records'] if record['kind'] == 'advance'))
                    elif fault == 'player':
                        next(record for record in case['records'] if record['kind'] == 'advance')['inputs'].pop(2)
                    elif runtime == 'rust':
                        case['events'] = []
                    else:
                        case['failure_frame'] = 33
                    diagnostic = 'incomplete player/frame workload' if fault != 'mismatch' else (
                        'missing interior event' if runtime == 'rust' else 'missing interior stop')
                    with self.assertRaisesRegex(ValueError, diagnostic):
                        replay.acceptance_evidence(changed)

    # Value: protects=validation and checksum gaps actually execute; fails_when=disabled or dense validation qualifies;
    # why_new=generated traces can agree with a weakened corpus; seam=none
    def test_weakened_sparse_corpus_cannot_qualify(self):
        for fault in ('disabled', 'dense', 'checked-before-mismatch'):
            with self.subTest(fault=fault):
                cases = replay.corpus()
                for case in cases:
                    mode = 'middle-mismatch' if fault == 'checked-before-mismatch' else 'sparse'
                    if not case['name'].endswith('-64-' + mode):
                        continue
                    if fault == 'disabled':
                        case['validate'] = False
                    else:
                        complete = replay.expected(dict(case, validate=False), True)
                        initial = replay.state_bytes((0, case['seed'], case['seed'], 0)).hex()
                        saved = [initial] + [record['bytes'] for record in complete['records'][:-1]]
                        for frame in range(64):
                            if case['checksums'][frame] is None and (fault == 'dense' or frame == 31):
                                case['checksums'][frame] = saved[frame]
                changed = self.observed(cases)
                replay.compare(changed, copy.deepcopy(changed))
                self.assertEqual(len(replay.controls(changed['rust'], changed['rust'])) +
                                 len(replay.expert_controls(changed['godot'], changed['godot'])), 17)
                with self.assertRaisesRegex(ValueError, 'incorrect save frame inventory'):
                    replay.acceptance_evidence(changed)

    # Value: protects=exact sparse SAVE frames and unchecked predecessor; fails_when=missing, extra or reordered work qualifies;
    # why_new=counts and mismatch markers cannot prove request coverage; seam=none
    def test_request_inventory_cannot_qualify_when_corrupted(self):
        observed = self.observed()
        for runtime, suffix in [('rust', ''), ('godot', ''), ('godot', '-expert')]:
            for mode in ('plain', 'sparse', 'middle-mismatch'):
                for fault in ('missing-first-save', 'missing-middle-save', 'missing-last-save', 'extra-save',
                              'save-offset', 'advance-offset', 'request-order'):
                    if mode == 'plain' and fault not in ('advance-offset', 'extra-save'):
                        continue
                    with self.subTest(runtime=runtime, suffix=suffix, mode=mode, fault=fault):
                        changed = copy.deepcopy(observed)
                        case = next(case for case in changed[runtime]['cases'] if case['name'] == f'5p-64-{mode}' + suffix)
                        records = case['records']
                        if fault == 'advance-offset':
                            next(record for record in records if record['kind'] == 'advance' and record['frame'] == 31)['frame'] = 32
                            diagnostic = 'incomplete player/frame workload'
                        else:
                            saves = [record for record in records if record['kind'] == 'save']
                            if fault.startswith('missing-'):
                                save = saves[0] if fault == 'missing-first-save' else saves[-1] if fault == 'missing-last-save' else next(
                                    record for record in saves if record['frame'] == (31 if runtime == 'rust' else 32))
                                records.remove(save)
                            elif fault == 'extra-save':
                                records.insert(0, dict(kind='save', frame=1, bytes='00' * 16, inputs=[]))
                            elif fault == 'save-offset':
                                saves[0]['frame'] = 1
                            else:
                                save = next(record for record in saves if record['frame'] == 32)
                                index = records.index(save)
                                records[index - 1], records[index] = records[index], records[index - 1]
                            diagnostic = 'incorrect save frame inventory'
                        replay.compare(changed, copy.deepcopy(changed))
                        with self.assertRaisesRegex(ValueError, diagnostic):
                            replay.acceptance_evidence(changed)

    @staticmethod
    def observed(cases=None):
        cases = replay.corpus() if cases is None else cases
        return {'rust': {'format': 1, 'cases': [replay.expected(case, True) for case in cases]},
                'godot': replay.godot_expected(cases)}


if __name__ == '__main__':
    unittest.main()
