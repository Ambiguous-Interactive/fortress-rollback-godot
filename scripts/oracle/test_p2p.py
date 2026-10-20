"""Strict P2P oracle contracts protect actual observed packet/request evidence."""
from copy import deepcopy
import json
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import p2p_launch
from p2p_launch import upstream_inventory, executable_identity, require_unchanged
from contract import initial_game_state, checksum
from p2p_contract import validate_scenario, validate, packet, normalize, compare, REVISION
from p2p_contract import DELAY_ERRORS, comparable_delay, expected_delay_error, godot_max_delay


def timeout_fixture():
    settings = {'quality_us': 100000000, 'keepalive_us': 100000000, 'notify_us': 500000,
                'timeout_us': 5000000, 'checksum_interval': 0, 'divergent_peer': -1}
    scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'lifecycle': settings,
                'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 5000001}]}
    state = initial_game_state(2, 2).hex()
    record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1,
              'pre_state': state, 'pre_confirmed': -1, 'state': state, 'error': None, 'requests': [], 'outgoing': [],
              'metrics': {'frames_ahead': 0, 'peers': [{'peer': 1, 'error': 'NotSynchronized'}]},
              'events': [{'kind': 'network_interrupted', 'peer': 1, 'disconnect_timeout': 4500}, {'kind': 'disconnected', 'peer': 1}]}
    expected = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario), 'records': [record], 'packets': []}
    actual = deepcopy(expected); actual['records'][0]['extension_events'] = []; actual['records'][0]['events'][-1]['reason'] = 'timeout'
    return actual, expected, scenario


class P2PContractTests(unittest.TestCase):
    # Value: protects=standalone timeout mismatch localization; fails_when=projection pops trailing event; why_new=valid suffix passes schema; seam=none
    def test_standalone_timeout_event_suffix(self):
        actual, expected, scenario = timeout_fixture()
        actual['records'][0]['events'].append({'kind': 'wait_recommendation', 'skip_frames': 1})
        with TemporaryDirectory() as root:
            scenario_path = Path(root) / 'scenario.json'; scenario_path.write_text(json.dumps(scenario), encoding='utf-8')
            expected_path = Path(root) / 'expected.json'; expected_path.write_text(json.dumps(expected), encoding='utf-8')
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('p2p_validate.py')),
                                     '--scenario', str(scenario_path), '--expected', str(expected_path)],
                                    input=json.dumps(actual), capture_output=True, encoding='utf-8', timeout=10, check=False)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertIn('operation 0:', result.stderr)
            self.assertNotIn('Traceback', result.stderr)

    # Value: protects=explicit named acceptance gate; fails_when=unknown or empty corpus skips evidence; why_new=internal custom names allow no requirements; seam=none
    def test_standalone_unknown_corpus_with_expected(self):
        actual, expected, scenario = timeout_fixture()
        scenario['operations'][0]['now_us'] = 0
        for trace in (actual, expected):
            trace['scenario'] = deepcopy(scenario); trace['records'][0]['events'] = []
        with TemporaryDirectory() as root:
            scenario_path = Path(root) / 'scenario.json'; scenario_path.write_text(json.dumps(scenario), encoding='utf-8')
            expected_path = Path(root) / 'expected.json'; expected_path.write_text(json.dumps(expected), encoding='utf-8')
            command = [sys.executable, str(Path(__file__).with_name('p2p_validate.py')),
                       '--scenario', str(scenario_path), '--expected', str(expected_path)]
            positive = subprocess.run(command, input=json.dumps(actual), capture_output=True, encoding='utf-8', timeout=10, check=False)
            self.assertEqual(positive.returncode, 0, positive.stderr)
            for name in ('control_boundarie', ''):
                with self.subTest(name=name):
                    result = subprocess.run(command + ['--corpus-case', name], input=json.dumps(actual), capture_output=True,
                                            encoding='utf-8', timeout=10, check=False)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertEqual(result.stderr, 'p2p validation: unknown corpus case\n')

    # Value: protects=standalone malformed ingress rejects structurally; fails_when=unchecked dictionary consumers traceback; why_new=P4 terminal extensions; seam=none
    def test_standalone_malformed_nested_consumers(self):
        original, _, scenario = timeout_fixture()
        mutations = [
            (lambda x: x['records'][0].update(extension_events=[None]), 'extension event'),
            (lambda x: x['records'][0].update(extension_events=[True]), 'extension event'),
            (lambda x: x['records'][0].update(extension_events=[0]), 'extension event'),
            (lambda x: x['records'][0].update(extension_events=['event']), 'extension event'),
            (lambda x: x['records'][0].update(extension_events=[[]]), 'extension event'),
            (lambda x: x.update(scenario=None), 'p2p scenario'),
            (lambda x: x['scenario'].update(players=None), 'players:'),
            (lambda x: x['records'][0].update(outgoing=[0]), 'outgoing packet inventory'),
        ]
        with TemporaryDirectory() as root:
            path = Path(root) / 'scenario.json'; path.write_text(json.dumps(scenario), encoding='utf-8')
            for mutate, diagnostic in mutations:
                with self.subTest(diagnostic=diagnostic, mutation=mutate):
                    mutant = deepcopy(original); mutate(mutant)
                    result = subprocess.run([sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(path)],
                                            input=json.dumps(mutant), capture_output=True, encoding='utf-8', timeout=10, check=False)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertTrue(result.stderr.startswith('p2p validation: ' + diagnostic), result.stderr)
                    self.assertNotIn('Traceback', result.stderr)

    # Value: protects=raw lifecycle packets validate structure before consumption; fails_when=null raw header tracebacks; why_new=control decoding preceded header checks; seam=none
    def test_standalone_raw_control_shape(self):
        _, original, scenario = timeout_fixture()
        with TemporaryDirectory() as root:
            path = Path(root) / 'scenario.json'; path.write_text(json.dumps(scenario), encoding='utf-8')
            for raw in (None, True, []):
                with self.subTest(raw=raw):
                    mutant = deepcopy(original)
                    mutant['packets'] = [{'id': 0, 'from': 0, 'to': 1,
                                          'semantic': {'kind': 'quality_report', 'frame_advantage': 0, 'ping': '00' * 16}, 'raw': raw}]
                    mutant['records'][0]['outgoing'] = [0]
                    result = subprocess.run([sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--source', '--scenario', str(path)],
                                            input=json.dumps(mutant), capture_output=True, encoding='utf-8', timeout=10, check=False)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertTrue(result.stderr.startswith('p2p validation: raw packet:'), result.stderr)
                    self.assertNotIn('Traceback', result.stderr)

    # Value: protects=named corpus source evidence; fails_when=zero-event trace earns named acceptance; why_new=CLI skipped gate without expected; seam=none
    def test_standalone_named_corpus_requires_expected(self):
        actual, _, scenario = timeout_fixture()
        scenario['operations'][0]['now_us'] = 0
        actual['scenario'] = deepcopy(scenario); actual['records'][0]['events'] = []
        with TemporaryDirectory() as root:
            path = Path(root) / 'scenario.json'; path.write_text(json.dumps(scenario), encoding='utf-8')
            command = [sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(path)]
            positive = subprocess.run(command, input=json.dumps(actual), capture_output=True, encoding='utf-8', timeout=10, check=False)
            self.assertEqual(positive.returncode, 0, positive.stderr)
            self.assertTrue(json.loads(positive.stdout)['complete'])
            for name in ('checksums_diverge', 'control_boundaries', ''):
                with self.subTest(name=name):
                    result = subprocess.run(command + ['--corpus-case', name], input=json.dumps(actual), capture_output=True,
                                            encoding='utf-8', timeout=10, check=False)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertEqual(result.stderr, 'p2p validation: --corpus-case requires --expected\n')

    # Value: protects=named lifecycle gates require a lifecycle profile; fails_when=P3 metrics lookup tracebacks; why_new=CLI permits named gates on P3; seam=none
    def test_standalone_named_corpus_rejects_p3(self):
        actual, expected, scenario = timeout_fixture()
        scenario.pop('lifecycle'); scenario['operations'][0]['now_us'] = 0
        for trace in (actual, expected):
            trace['scenario'] = deepcopy(scenario)
            record = trace['records'][0]; record['events'] = []
            for key in ('metrics', 'pre_state', 'pre_confirmed'):
                record.pop(key)
        with TemporaryDirectory() as root:
            path = Path(root) / 'scenario.json'; path.write_text(json.dumps(scenario), encoding='utf-8')
            reference = Path(root) / 'expected.json'; reference.write_text(json.dumps(expected), encoding='utf-8')
            command = [sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(path), '--expected', str(reference)]
            positive = subprocess.run(command, input=json.dumps(actual), capture_output=True, encoding='utf-8', timeout=10, check=False)
            self.assertEqual(positive.returncode, 0, positive.stderr)
            result = subprocess.run(command + ['--corpus-case', 'checksums_match'], input=json.dumps(actual),
                                    capture_output=True, encoding='utf-8', timeout=10, check=False)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertEqual(result.stderr, 'p2p validation: --corpus-case requires lifecycle scenario\n')

    # Value: protects=optional lifecycle strict schema; fails_when=aliases bypass clock policy; why_new=P4 options are nested ingress; seam=none
    def test_lifecycle_settings_strict(self):
        from p2p_lifecycle import settings
        original = {'quality_us': 200000, 'keepalive_us': 100000, 'notify_us': 500000,
                    'timeout_us': 5000000, 'checksum_interval': 2, 'divergent_peer': -1}
        settings(original, 2)
        for key in original:
            for alias in (True, float(original[key]), None):
                mutant = dict(original, **{key: alias})
                with self.assertRaises(ValueError):
                    settings(mutant, 2)
        for key, invalid in [('quality_us', 999), ('keepalive_us', 0), ('notify_us', 5000000),
                             ('timeout_us', 500000), ('checksum_interval', 61), ('divergent_peer', 2)]:
            with self.assertRaises(ValueError):
                settings(dict(original, **{key: invalid}), 2)

    # Value: protects=raw u128 preserves exact control bytes; fails_when=numeric aliases match projected strings; why_new=checksums exceed64bit; seam=none
    def test_lifecycle_raw_wide_integer_schema(self):
        from p2p_lifecycle import control
        number = (1 << 127) + 17
        value = {'semantic': {'kind': 'checksum_report', 'frame': 2, 'checksum': f'{number:032x}'},
                 'raw': {'body': {'ChecksumReport': {'frame': 2, 'checksum': number}}}}
        control(value, True)
        for alias in (True, float(number), str(number), None):
            mutant = deepcopy(value); mutant['raw']['body']['ChecksumReport']['checksum'] = alias
            with self.assertRaises(ValueError):
                control(mutant, True)

    # Value: protects=terminal projection stops onlyfirstfinal event; fails_when=later source operations silently disappear; why_new=membership policy differs; seam=none
    def test_terminal_projection_full_timeout_boundary(self):
        actual, expected, scenario = timeout_fixture()
        compare(actual, expected, scenario)
        for mutate in (lambda x: x['records'][0]['events'][-1].update(peer=0),
                       lambda x: x['records'][0]['events'][-1].update(reason='invented'),
                       lambda x: x['records'][0].update(pre_confirmed=0)):
            mutant = deepcopy(actual); mutate(mutant)
            with self.assertRaises(ValueError):
                compare(mutant, expected, scenario)
        for trace in (actual, expected):
            trace['scenario']['operations'].append({'kind': 'poll', 'peer': 0, 'now_us': 5000002})
            following = deepcopy(trace['records'][0]); following.update(index=1, events=[])
            trace['records'].append(following)
        scenario['operations'].append({'kind': 'poll', 'peer': 0, 'now_us': 5000002})
        with self.assertRaisesRegex(ValueError, 'first final trigger'):
            compare(actual, expected, scenario)

    # Value: protects=terminal exclusions own exact membership/count; fails_when=invented notifications vanish; why_new=cold review escaped exclusions; seam=none
    def test_terminal_notification_inventory(self):
        from p2p_lifecycle import terminal_notifications
        actual, expected, scenario = timeout_fixture()
        terminal_notifications(actual, scenario)
        actual['records'][0]['extension_events'].append({'kind': 'disconnected', 'peer': 0, 'reason': 255})
        with self.assertRaisesRegex(ValueError, 'outside final desync policy'):
            compare(actual, expected, scenario)
        actual['records'][0]['events'] = [{'kind': 'desync_detected'}]
        actual['records'][0]['extension_events'] = [{'kind': 'disconnected', 'peer': 1, 'reason': 255}]
        actual['packets'] = [{'id': i, 'from': 0, 'to': 1, 'semantic': {'kind': 'goodbye', 'reason': 255}} for i in range(3)]
        actual['records'][0]['outgoing'] = [0, 1, 2]
        terminal_notifications(actual, scenario)
        for mutation, diagnostic in [
                (lambda x: x['records'][0]['extension_events'].append({'kind': 'disconnected', 'peer': 0, 'reason': 255}), 'membership'),
                (lambda x: x['records'][0]['extension_events'].append(deepcopy(x['records'][0]['extension_events'][0])), 'membership'),
                (lambda x: x['records'][0]['outgoing'].append(2), 'membership/count'),
                (lambda x: x['records'][0]['outgoing'].pop(), 'membership/count')]:
            mutant = deepcopy(actual); mutation(mutant)
            with self.assertRaisesRegex(ValueError, diagnostic):
                terminal_notifications(mutant, scenario)

    # Value: protects=frozen-policy mutant reaches intended guard; fails_when=inconsistent state masks runtime regression; why_new=old mutation failed earlier; seam=none
    def test_unfrozen_control_is_canonical(self):
        from p2p_lifecycle_controls import mutations_for, unfreeze, controls
        actual, expected, scenario = timeout_fixture()
        mutant = deepcopy(actual); unfreeze(mutant, 0, expected)
        validate(mutant, scenario)
        with self.assertRaisesRegex(ValueError, 'operation 0: Godot terminal boundary not frozen'):
            compare(mutant, expected, scenario)
        mutation, diagnostic = mutations_for(actual, expected)['terminal_unfrozen']
        self.assertEqual(diagnostic, 'operation 0: Godot terminal boundary not frozen')
        mutation(deepcopy(actual))
        with patch('p2p_lifecycle_controls.compare', side_effect=ValueError('unrelated parser failure')):
            with self.assertRaisesRegex(ValueError, 'wrong boundary: metric_bool'):
                controls(actual, expected, scenario)

    # Value: protects=named corpus requires nonzero actual evidence; fails_when=empty short profile earns release evidence; why_new=generic parity vacuous; seam=none
    def test_named_corpus_nonzero_gate(self):
        from p2p_lifecycle import corpus_evidence, CORPUS_REQUIREMENTS
        source = {'records': [], 'packets': []}
        for name in CORPUS_REQUIREMENTS:
            with self.assertRaisesRegex(ValueError, 'missing required source observation'):
                corpus_evidence(name, source, [])
        self.assertEqual(corpus_evidence('custom_short_profile', source, []), {})
        source = {'records': [{'peer': 0, 'events': [{'kind': 'network_interrupted'}],
                             'metrics': {'peers': [{'peer': 1, 'error': 'NotSynchronized'}, {'peer': 1, 'error': None, 'ping': 0,
                                                   'local_frames_behind': 0, 'remote_frames_behind': 0}]}, 'requests': []}],
                  'packets': [{'semantic': {'kind': kind}} for kind in ['quality_report', 'keep_alive']]}
        with self.assertRaisesRegex(ValueError, 'missing required control quality_advantage'):
            corpus_evidence('control_boundaries', source, [])
        evidence = corpus_evidence('control_boundaries', source, ['quality_advantage', 'quality_ping', 'notify_payload'])
        self.assertEqual(evidence['required_observations']['stats_transition'], 1)

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

    # Value: protects=delay-change schema stays fail-closed; fails_when=pre-input, stale-clock, divergent-band or alias delays pass; why_new=X2 oracle op; seam=none
    def test_delay_change_schema(self):
        step = {'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': '00000000'}
        original = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                    'operations': [step, {'kind': 'delay', 'peer': 0, 'delay': 59}, {'kind': 'delay', 'peer': 0, 'delay': 124}]}
        validate_scenario(original)
        for mutate in (lambda x: x['operations'].pop(0), lambda x: x['operations'][1].update(delay=60),
                       lambda x: x['operations'][1].update(delay=123), lambda x: x['operations'][1].update(delay=1001),
                       lambda x: x['operations'][1].update(delay=True), lambda x: x['operations'][1].update(delay=2.0),
                       lambda x: x['operations'][1].update(now_us=0), lambda x: x['operations'][1].update(peer=1),
                       lambda x: x['operations'].insert(1, {'kind': 'poll', 'peer': 1, 'now_us': 0}),
                       lambda x: x['operations'].insert(1, {'kind': 'deliver', 'packet': 0, 'now_us': 0})):
            mutant = deepcopy(original); mutate(mutant)
            with self.assertRaises(ValueError):
                validate_scenario(mutant)

    # Value: protects=independent delay outcome and gap-fill model; fails_when=refusal or gap sample drift passes; why_new=X2 oracle op; seam=none
    def test_delay_change_outcome_model(self):
        self.assertEqual(expected_delay_error(2, 2, 4), None)
        self.assertEqual(expected_delay_error(2, 1, 4), 'UNSUPPORTED')
        self.assertEqual(expected_delay_error(2, 124, 4), 'INVALID_CONFIGURATION')
        self.assertEqual(godot_max_delay(4), 59)
        self.assertTrue(comparable_delay(59, 4) and comparable_delay(124, 4) and not comparable_delay(123, 4))
        self.assertEqual(set(DELAY_ERRORS.values()), {'UNSUPPORTED', 'INVALID_CONFIGURATION'})

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
            engine = tree / 'godot'; engine.write_bytes(b'engine'); engine.chmod(0o755)
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
