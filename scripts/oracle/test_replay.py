"""Full-roster replay acceptance must survive accidental corpus reductions."""
import copy
import re
import unittest

import replay_launch as replay


class ReplayAcceptanceTest(unittest.TestCase):
    # Value: protects=source-bound acceptance cannot silently shrink; fails_when=missing workload earns green;
    # why_new=exact trace comparison alone trusts a reduced generated corpus; seam=none
    def test_missing_or_duplicate_workload_cannot_qualify(self):
        observed = self.observed()
        self.assertEqual(len(replay.acceptance_evidence(observed)), 21)
        for runtime, suffix in [('rust', ''), ('godot', ''), ('godot', '-expert'), ('godot', '-v4'), ('godot', '-v4-expert')]:
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
        for runtime, suffix in [('rust', ''), ('godot', ''), ('godot', '-expert'), ('godot', '-v4'), ('godot', '-v4-expert')]:
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
                                 len(replay.expert_controls(changed['godot'], changed['godot'])), 21)
                with self.assertRaisesRegex(ValueError, 'incorrect save frame inventory'):
                    replay.acceptance_evidence(changed)

    # Value: protects=exact sparse SAVE frames and unchecked predecessor; fails_when=missing, extra or reordered work qualifies;
    # why_new=counts and mismatch markers cannot prove request coverage; seam=none
    def test_request_inventory_cannot_qualify_when_corrupted(self):
        observed = self.observed()
        for runtime, suffix in [('rust', ''), ('godot', ''), ('godot', '-expert'), ('godot', '-v4'), ('godot', '-v4-expert')]:
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

    # Value: protects=legacy acceptance proves the decoded file version, not a renamed current file;
    # fails_when=current bytes substitute for legacy bytes; why_new=only version 5 executes in the oracle; seam=none
    def test_legacy_version_cannot_be_substituted(self):
        observed = self.observed()
        legacy = [case for case in observed['godot']['cases'] if case['name'] == '5p-64-sparse-v4']
        self.assertEqual(len(legacy), 1, 'legacy replay actually executes')
        legacy[0]['format_version'] = 5
        with self.assertRaisesRegex(ValueError, 'incorrect replay format version'):
            replay.acceptance_evidence(observed)

    # Value: protects=final-only comparison cannot be omitted; fails_when=historical completion substitutes for final SAVE; seam=none
    def test_terminal_acceptance_rejects_weakened_observations(self):
        original = self.observed()
        self.assertEqual(len(replay.terminal_acceptance_evidence(original)), 12)
        for fault in ('missing-save', 'wrong-outcome', 'wrong-boundary', 'missing-workload', 'duplicate'):
            changed = copy.deepcopy(original)
            cases = changed['godot']['cases']
            terminal = next(case for case in cases if case['name'] == '8p-7-terminal-mismatch-v6-expert')
            if fault == 'missing-save':
                terminal['records'].pop()
            elif fault == 'wrong-outcome':
                terminal.update(code=16, failure_frame=-1, complete=True)
            elif fault == 'wrong-boundary':
                terminal['records'][-1]['frame'] -= 1
            elif fault == 'missing-workload':
                cases.remove(terminal)
            else:
                cases.append(copy.deepcopy(terminal))
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                replay.terminal_acceptance_evidence(changed)

    # Value: protects=non-u32 widths execute original canonical prefixes; fails_when=widths narrow, workloads vanish or interior validation skips;
    # why_new=existing source playback fixes all samples to u32; seam=none
    def test_width_acceptance_rejects_weakened_observations(self):
        original = self.observed()
        self.assertEqual(len(replay.width_acceptance_evidence(original)), 8)
        for runtime, suffix in [('rust', ''), ('godot', ''), ('godot', '-v4-expert'), ('godot', '-v6-expert')]:
            for fault in ('missing', 'duplicate', 'width', 'sample', 'prefix', 'validation'):
                changed = copy.deepcopy(original)
                cases = changed[runtime]['cases']
                case = next(item for item in cases if item['name'] == '8p-64-u16-middle-mismatch' + suffix)
                path = f'width.{runtime}.8p-64-u16-middle-mismatch{suffix}'
                if fault == 'missing':
                    cases.remove(case)
                    diagnostic = 'missing or duplicate width workload'
                elif fault == 'duplicate':
                    cases.append(copy.deepcopy(case))
                    diagnostic = 'missing or duplicate width workload'
                elif fault == 'width':
                    case['input_width'] = 1
                    diagnostic = path + '.input_width: value mismatch: expected 2, actual 1'
                elif fault == 'sample':
                    next(item for item in case['records'] if item['kind'] == 'advance')['inputs'][4]['value'] &= 255
                    diagnostic = path + '.records[1].inputs[4].value: value mismatch: expected 65011, actual 243'
                elif fault == 'prefix':
                    next(item for item in case['records'] if item['kind'] == 'advance')['bytes'] = '00' * 16
                    diagnostic = path + ".records[1].bytes: value mismatch: expected '010000003fdf1da1875f50b9e0fb878d', actual '00000000000000000000000000000000'"
                elif runtime == 'rust':
                    case['events'] = []
                    diagnostic = path + '.events: count mismatch'
                else:
                    case['failure_frame'] = 33
                    diagnostic = path + '.failure_frame: value mismatch: expected 32, actual 33'
                with self.subTest(runtime=runtime, suffix=suffix, fault=fault), self.assertRaisesRegex(ValueError, '^' + re.escape(diagnostic) + '$'):
                    replay.width_acceptance_evidence(changed)

    @staticmethod
    def observed(cases=None):
        cases = replay.corpus() if cases is None else cases
        return {'rust': {'format': 1, 'cases': [replay.expected(case, True) for case in cases]},
                'godot': replay.godot_expected(cases)}


if __name__ == '__main__':
    unittest.main()
