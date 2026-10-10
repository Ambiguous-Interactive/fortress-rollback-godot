"""Value: actual session evidence must cover exact callbacks and reject partial or forged streams."""
import copy
import json
import unittest

import session_compare
from test_contract import trace


def result():
    return {'format': 1, 'complete': True, 'passed': True, 'engine_version': '4.3.stable', 'errors': [], 'trace': trace()}


class SessionComparisonTests(unittest.TestCase):
    def test_exact_independent_session_trace(self):
        value = result()
        self.assertEqual(session_compare.compare_result(session_compare.PREFIX + json.dumps(value), '', trace()), value)
        self.assertEqual(len(session_compare.negative_controls(value, trace())), 6)

    def test_schema_and_stream_mutations(self):
        mutations = {
            'unknown': lambda x: x.update(ignored=True),
            'bool_format': lambda x: x.update(format=True),
            'float_player': lambda x: x['trace']['scenario'].update(players=2.0),
            'bool_index': lambda x: x['trace']['operations'][0].update(index=False),
            'engine': lambda x: x.update(engine_version=''),
            'failed': lambda x: x.update(passed=False),
            'errors': lambda x: x.update(errors=['failed']),
            'frame': lambda x: x['trace']['operations'][0].update(frame_after=1),
            'reordered': lambda x: x['trace']['operations'][2]['requests'].reverse(),
            'status': lambda x: x['trace']['operations'][2]['requests'][1]['inputs'][0].update(status='predicted'),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                changed = result()
                mutate(changed)
                session_compare.compare_result(session_compare.PREFIX + json.dumps(changed), '', trace())
        good = session_compare.PREFIX + json.dumps(result())
        for stdout, stderr in ((good + '\n' + good, ''), ('', ''), (good, 'SCRIPT ERROR: bad')):
            with self.subTest(stdout=stdout, stderr=stderr), self.assertRaises(ValueError):
                session_compare.compare_result(stdout, stderr, trace())

    def test_errors_project_only_supported_contract_differences(self):
        for godot, rust in (('INVALID_PLAYER', 'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(255), num_players: 2 } }'),
                            ('MISSING_LOCAL_INPUT', 'InvalidRequestStructured { kind: MissingLocalInput }')):
            with self.subTest(godot=godot):
                actual = result()
                expected = copy.deepcopy(trace())
                for value, error in ((actual['trace'], godot), (expected, rust)):
                    value['operations'][0].update(result='error', error=error)
                    if godot == 'INVALID_PLAYER':
                        value['scenario']['operations'][0]['player'] = 255
                session_compare.compare_result(session_compare.PREFIX + json.dumps(actual), '', expected)
        invalid = 'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(255), num_players: 2 } }'
        for player, players in ((254, 2), (255, 3)):
            with self.subTest(player=player, players=players), self.assertRaises(ValueError):
                session_compare.error_category(invalid, False, player, players)
        with self.assertRaises(ValueError):
            session_compare.error_category('BUSY', True)
        with self.assertRaises(ValueError):
            session_compare.error_category('ArbitraryFailure', False)

    def test_malformed_rust_errors_cannot_borrow_supported_variant_names(self):
        diagnostics = [
            'ArbitraryFailure { detail: "MissingLocalInput" }',
            'ArbitraryFailure { detail: "InvalidLocalPlayerHandle" }',
            'InvalidRequestStructured { kind: MissingLocalInput } trailing',
            'prefix InvalidRequestStructured { kind: MissingLocalInput }',
            'InvalidRequestStructured { kind: MissingLocalInput, detail: 1 }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(256), num_players: 2 } }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(255), num_players: 9 } }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(255), num_players: 1 } }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(0), num_players: 2 } }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(-1), num_players: 2 } }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(255.0), num_players: 2 } }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(0255), num_players: 2 } }',
            'InvalidRequestStructured { kind: InvalidLocalPlayerHandle { handle: PlayerHandle(255), num_players: true } }',
        ]
        for diagnostic in diagnostics:
            with self.subTest(diagnostic=diagnostic), self.assertRaises(ValueError):
                session_compare.error_category(diagnostic, False)
        actual = result()
        expected = trace()
        actual['trace']['operations'][0].update(result='error', error='MISSING_LOCAL_INPUT')
        expected['operations'][0].update(result='error', error=diagnostics[0])
        with self.assertRaisesRegex(ValueError, 'unrecognized error projection'):
            session_compare.compare_result(session_compare.PREFIX + json.dumps(actual), '', expected)


if __name__ == '__main__':
    unittest.main()
