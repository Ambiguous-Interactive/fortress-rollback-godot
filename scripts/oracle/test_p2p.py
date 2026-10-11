"""Strict P2P oracle contracts protect actual observed packet/request evidence."""
from copy import deepcopy
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import p2p_launch
from p2p_launch import upstream_inventory, executable_identity, require_unchanged
from contract import initial_game_state, checksum
from p2p_contract import validate_scenario, validate, packet, normalize, compare, REVISION


class P2PContractTests(unittest.TestCase):
    # Value: protects=standalone nonempty strict scenario; fails_when=bool/float aliases integers; why_new=multiplayer scheduler is new ingress; seam=none
    def test_scenario_strict_types(self):
        original = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        validate_scenario(original)
        for key in ('format', 'players', 'input_delay', 'max_prediction'):
            for alias in (True, float(original[key])):
                mutant = deepcopy(original); mutant[key] = alias
                with self.assertRaises(ValueError):
                    validate_scenario(mutant)
        for mutate in (lambda x: x.update(operations=[]), lambda x: x.update(extra=1),
                       lambda x: x['operations'][0].update(peer=False), lambda x: x['operations'][0].update(now_us=0.0),
                       lambda x: x['operations'][0].update(kind='unknown'),
                       lambda x: x.update(max_prediction=0), lambda x: x.update(max_prediction=1)):
            mutant = deepcopy(original); mutate(mutant)
            with self.assertRaises(ValueError):
                validate_scenario(mutant)

    # Value: protects=upstream-only duplicate-save exception; fails_when=Godot extra callbacks disappear; why_new=source API asymmetry; seam=none
    def test_initial_save_exception_is_source_only(self):
        request = {'kind': 'save', 'frame': 0}
        trace = {'scenario': {'operations': [{'kind': 'step'}]}, 'records': [
            {'index': 0, 'peer': 0, 'error': None, 'frame_before': 0, 'frame_after': 1, 'requests': [deepcopy(request), deepcopy(request)]}], 'packets': []}
        self.assertEqual(len(normalize(trace)['records'][0]['requests']), 2)
        self.assertEqual(len(normalize(trace, True)['records'][0]['requests']), 1)

    # Value: protects=complete callback inventory; fails_when=source extra poll saves normalize away; why_new=SAVE0 exception must identify real first advance; seam=none
    def test_poll_duplicate_save_is_not_normalized(self):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': time} for time in (0, 1)]}
        state = initial_game_state(2, 2)
        request = {'kind': 'save', 'frame': 0, 'state_bytes': state.hex(), 'checksum': checksum(state), 'inputs': []}
        records = [{'index': index, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1, 'error': None,
                    'requests': [deepcopy(request), deepcopy(request)], 'events': [], 'outgoing': [], 'state': state.hex()} for index in range(2)]
        expected = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario), 'records': records, 'packets': []}
        actual = deepcopy(expected)
        for record in actual['records']:
            record['requests'].pop(0); record['extension_events'] = []
        validate(expected, scenario, True); validate(actual, scenario)
        with self.assertRaisesRegex(ValueError, 'operation 0: requests mismatch'):
            compare(actual, expected, scenario)

    # Value: protects=per-peer one-time source exception; fails_when=later SAVE0 or stalled first step is erased; why_new=normalization scope needs state; seam=none
    def test_initial_save_exception_is_first_success_per_peer(self):
        request = {'kind': 'save', 'frame': 0}
        records = [{'index': index, 'peer': peer, 'error': error, 'frame_before': 0, 'frame_after': after,
                    'requests': [deepcopy(request), deepcopy(request)]}
                   for index, (peer, error, after) in enumerate([(0, None, 0), (0, None, 1), (0, None, 1), (1, None, 1)])]
        trace = {'scenario': {'operations': [{'kind': 'step'} for _ in records]}, 'records': records, 'packets': []}
        self.assertEqual([len(record['requests']) for record in normalize(trace, True)['records']], [2, 1, 2, 1])

    # Value: protects=Godot stall error evidence; fails_when=null is silently mapped to success; why_new=source-only error asymmetry; seam=none
    def test_stall_error_exception_is_source_only(self):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                    'operations': [{'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': '11000000'}]}
        record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1, 'error': None,
                  'requests': [], 'events': [], 'outgoing': [], 'state': initial_game_state(2, 2).hex()}
        expected = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario), 'records': [record], 'packets': []}
        actual = deepcopy(expected); actual['records'][0].update(error='PREDICTION_STALL', extension_events=[])
        compare(actual, expected, scenario)
        for error in (None, 'PredictionThreshold'):
            mutant = deepcopy(actual); mutant['records'][0]['error'] = error
            with self.assertRaisesRegex(ValueError, 'operation 0: error mismatch'):
                compare(mutant, expected, scenario)

    # Value: protects=source STEP-only stall projection; fails_when=poll errors or changing-frame errors disappear; why_new=cold review accepted a whole poll trace; seam=none
    def test_source_errors_are_not_projected_to_stall(self):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1,
                  'error': 'PredictionThreshold', 'requests': [], 'events': [], 'outgoing': [], 'state': initial_game_state(2, 2).hex()}
        expected = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario), 'records': [record], 'packets': []}
        actual = deepcopy(expected); actual['records'][0].update(error='PREDICTION_STALL', extension_events=[])
        validate(expected, scenario, True); validate(actual, scenario)
        with self.assertRaisesRegex(ValueError, 'operation 0: error mismatch'):
            compare(actual, expected, scenario)
        for kind, error, after in [('poll', None, 0), ('step', 'PredictionThreshold', 0), ('step', 'PredictionThreshold', 1), ('step', None, 1)]:
            trace = {'scenario': {'operations': [{'kind': kind}]}, 'records': [dict(record, error=error, frame_after=after)], 'packets': []}
            self.assertIs(normalize(trace, True)['records'][0]['error'], error)

    # Value: protects=receipt provenance across execution; fails_when=source/tool drift retains success; why_new=multi-process gate spans source inventories; seam=none
    def test_execution_identity_drift(self):
        with TemporaryDirectory() as directory:
            tree = Path(directory)
            for name in ('Cargo.toml', 'Cargo.lock', 'lib.rs'):
                (tree / name).write_text('original', encoding='utf-8')
            original = upstream_inventory(tree)
            require_unchanged('upstream', original, upstream_inventory(tree))
            for name in ('Cargo.toml', 'Cargo.lock', 'lib.rs'):
                (tree / name).write_text('changed', encoding='utf-8')
                with self.assertRaisesRegex(ValueError, 'evidence identity changed: upstream'):
                    require_unchanged('upstream', original, upstream_inventory(tree))
                (tree / name).write_text('original', encoding='utf-8')
            (tree / 'added.rs').write_text('added', encoding='utf-8')
            with self.assertRaises(ValueError):
                require_unchanged('upstream', original, upstream_inventory(tree))
            (tree / 'added.rs').unlink()
            (tree / 'lib.rs').unlink()
            with self.assertRaises(ValueError):
                require_unchanged('upstream', original, upstream_inventory(tree))
            executable = tree / 'engine'; executable.write_bytes(b'original engine')
            identity = executable_identity(executable)
            for changed in (b'changed engine', b'changed oracle binary'):
                executable.write_bytes(changed)
                with self.assertRaisesRegex(ValueError, 'evidence identity changed: executable'):
                    require_unchanged('executable', identity, executable_identity(executable))
            executable.write_bytes(b'original engine')
            executable.chmod(identity['mode'] ^ 0o100)
            with self.assertRaises(ValueError):
                require_unchanged('executable', identity, executable_identity(executable))

    # Value: protects=drift fail-closed publication; fails_when=old receipt survives failed guard; why_new=end-of-run hash alone was mixed provenance; seam=none
    def test_upstream_drift_invalidates_previous_receipt(self):
        with TemporaryDirectory() as directory:
            tree = Path(directory); output = tree / 'results'; output.mkdir()
            receipt = output / 'receipt.json'; receipt.write_text('{"passed":true}', encoding='utf-8')
            upstream = tree / 'upstream'; upstream.mkdir()
            for name in ('lib.rs', 'Cargo.toml', 'Cargo.lock'):
                (upstream / name).write_text('original', encoding='utf-8')
            engine = tree / 'godot'; engine.write_bytes(b'engine')
            binary = tree / 'target/debug/p2p'; binary.parent.mkdir(parents=True)
            def execute(command, *_args, **_kwargs):
                if 'build' in command:
                    binary.write_bytes(b'binary')
                    (upstream / 'Cargo.lock').write_text('changed during build', encoding='utf-8')
                return ('4.3.stable.test' if command[0] == str(engine) else 'tool version', '')
            with patch.multiple(p2p_launch, CACHE=tree, source_files=lambda: [],
                                load_manifest=lambda: {'rust': {'version': '1'}},
                                sources=lambda *_a, **_k: {'fortress': upstream},
                                setup_rust=lambda *_a, **_k: (tree / 'cargo', None), execute=execute), \
                    patch('sys.argv', ['p2p_launch.py', '--godot', str(engine), '--output', str(output)]):
                with self.assertRaisesRegex(ValueError, 'evidence identity changed: upstream source inventory'):
                    p2p_launch.main()
            self.assertFalse(receipt.exists())

    @staticmethod
    def observed_packet():
        statuses = [{'disconnected': False, 'epoch': 0, 'last_frame': 0}, {'disconnected': False, 'epoch': 0, 'last_frame': -1}]
        return {'id': 0, 'from': 0, 'to': 1,
                'semantic': {'kind': 'input', 'start_frame': 0, 'ack_frame': -1, 'players': [0], 'frames': ['11000000'], 'statuses': deepcopy(statuses)},
                'raw': {'header': {'conn_id': 77, 'flags': 0, 'protocol_version': 2, 'sentinel': [245, 82]},
                        'body': {'Input': {'start_frame': 0, 'ack_frame': -1, 'bytes': [2, 17, 13], 'peer_connect_status': statuses}}}}

    # Value: protects=raw numeric domains; fails_when=nested raw aliases pass; why_new=source serde ingress; seam=none
    def test_raw_packet_consumption(self):
        original = self.observed_packet(); packet(original, 2, True)
        for mutate in (lambda x: x['raw']['header'].update(conn_id=True),
                       lambda x: x['raw']['header'].update(sentinel=[245.0, 82]),
                       lambda x: x['raw']['body']['Input']['peer_connect_status'][0].update(epoch=False),
                       lambda x: x['raw']['body']['Input'].update(bytes=[2, True, 13]),
                       lambda x: x['semantic'].update(players=[False]), lambda x: x['semantic'].update(extra=1),
                       lambda x: x['raw']['body']['Input'].update(extra=1)):
            mutant = deepcopy(original); mutate(mutant)
            with self.assertRaises(ValueError):
                packet(mutant, 2, True)

    # Value: protects=complete embedded trace; fails_when=empty or alias passes; why_new=P2P ingress; seam=none
    def test_embedded_and_partial_evidence(self):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1, 'error': None,
                  'requests': [], 'events': [], 'extension_events': [], 'outgoing': [], 'state': initial_game_state(2, 2).hex()}
        trace = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario), 'records': [record], 'packets': []}
        validate(trace, scenario)
        for mutate in (lambda x: x['scenario'].update(format=True), lambda x: x.update(records=[]),
                       lambda x: x['records'][0].update(confirmed_frame=False), lambda x: x.update(complete=1),
                       lambda x: x['records'][0].update(error=False), lambda x: x['records'][0]['events'].append('unknown'),
                       lambda x: x['records'][0]['extension_events'].append({'kind': 'unknown', 'peer': 1, 'start_frame': 0, 'frame_count': 1})):
            mutant = deepcopy(trace); mutate(mutant)
            with self.assertRaises(ValueError):
                validate(mutant, scenario)


if __name__ == '__main__':
    unittest.main()
