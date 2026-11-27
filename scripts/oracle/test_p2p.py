"""Strict P2P oracle contracts protect actual observed packet/request evidence."""
from copy import deepcopy
import hashlib
import json
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import p2p_launch
import p2p_wrap
import p2p_wrap_regenerate
import profile_report
from p2p_launch import upstream_inventory, executable_identity, require_unchanged, wrap_fixture
from contract import initial_game_state, checksum
from p2p_contract import validate_scenario, validate, packet, normalize, compare, REVISION
from p2p_contract import DELAY_ERRORS, INPUT_ERRORS, comparable_delay, expected_delay_error, godot_max_delay, slots_of
from source_wire import RECOVERY_REVISION, checksum_basis, decode_trace


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

    # Value: protects=the standalone validator's no-traceback contract under a layout scenario;
    # fails_when=a hostile packet sender raises TypeError/IndexError from the owned-slot lookup
    # instead of the clean ValueError boundary; why_new=#363 multi-local slots; seam=none
    def test_standalone_layout_malformed_sender(self):
        scenario = {'format': 1, 'players': 4, 'input_delay': 0, 'max_prediction': 4, 'layout': [2, 2],
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        trace = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario),
                 'records': [{'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1,
                              'error': None, 'requests': [], 'events': [], 'extension_events': [], 'outgoing': [0],
                              'state': initial_game_state(4, 2).hex()}],
                 'packets': [{'id': 0, 'from': 0, 'to': 1, 'semantic': {'kind': 'input_ack', 'ack_frame': 0}}]}
        with TemporaryDirectory() as root:
            path = Path(root) / 'scenario.json'; path.write_text(json.dumps(scenario), encoding='utf-8')
            for bad_from in (9, 1.0, 'x', None, True, -1, 2, 3):
                mutant = deepcopy(trace); mutant['packets'][0]['from'] = bad_from
                with self.subTest(bad_from=bad_from):
                    result = subprocess.run([sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(path)],
                                            input=json.dumps(mutant), capture_output=True, encoding='utf-8', timeout=10, check=False)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertTrue(result.stderr.startswith('p2p validation: from: invalid integer'), result.stderr)
                    self.assertNotIn('Traceback', result.stderr)
            # An unconsumed packet must not silently accept a machine-invalid destination.
            for bad_to in (9, 2, 3, 1.0, None):
                mutant = deepcopy(trace); mutant['packets'][0]['to'] = bad_to
                with self.subTest(bad_to=bad_to):
                    result = subprocess.run([sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(path)],
                                            input=json.dumps(mutant), capture_output=True, encoding='utf-8', timeout=10, check=False)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertTrue(result.stderr.startswith('p2p validation: to: invalid integer'), result.stderr)
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

    def test_versioned_checksum_basis_before_projection(self):
        value = {'id': 0, 'from': 0, 'to': 1,
                 'semantic': {'kind': 'checksum_report', 'frame': 2, 'checksum': '0' * 32},
                 'raw': {'header': {'conn_id': 1, 'flags': 0, 'protocol_version': 6, 'sentinel': [245, 82]},
                         'body': {'ChecksumReport': {'frame': 2, 'checksum': 0, 'basis_token': 0}}}}
        packet(value, 2, True, wire=6)
        with self.assertRaisesRegex(ValueError, 'protocol version'):
            packet(value, 2, True)
        body = value['raw']['body']['ChecksumReport']
        for token in (True, 0.0, -1, 1 << 64, '0'):
            with self.subTest(token=token):
                body['basis_token'] = token
                with self.assertRaisesRegex(ValueError, 'checksum basis token'):
                    packet(value, 2, True, wire=6)
        for token in ((1 << 64) - 1, 4176669562639073937):
            body['basis_token'] = token
            self.assertEqual(checksum_basis(body, 6), token)
            with self.assertRaisesRegex(ValueError, 'fixed-membership'):
                packet(value, 2, True, wire=6)
        del body['basis_token']
        with self.assertRaisesRegex(ValueError, 'raw control'):
            packet(value, 2, True, wire=6)
        value['raw']['header']['protocol_version'] = 2
        packet(value, 2, True)
        body['basis_token'] = 0
        with self.assertRaisesRegex(ValueError, 'raw control'):
            packet(value, 2, True)
        with self.assertRaisesRegex(ValueError, 'unsupported upstream wire version'):
            packet(value, 2, True, wire=7)

    def test_trace_rejects_duplicate_raw_basis(self):
        contents = '{"body":{"ChecksumReport":{"frame":2,"checksum":0,"basis_token":4176669562639073937,"basis_token":0}}}'
        with self.assertRaisesRegex(ValueError, 'duplicate trace field: basis_token'):
            decode_trace(contents)

    def test_source_revision_selection_is_explicit(self):
        _, trace, scenario = timeout_fixture()
        trace['upstream_revision'] = RECOVERY_REVISION
        validate(trace, scenario, True, source_revision=RECOVERY_REVISION)
        with self.assertRaisesRegex(ValueError, 'incomplete/revision'):
            validate(trace, scenario, True)
        with self.assertRaisesRegex(ValueError, 'unsupported upstream wire revision'):
            validate(trace, scenario, True, source_revision='a' * 40)

    # Value: protects=the layout checksum seam; fails_when=a layout trace loses its
    # upstream-default desync reports, or a quality/keepalive packet or a solo-mesh
    # checksum sneaks past the no-lifecycle packet gate; why_new=the couch wrap
    # flood crosses frame 60 without a lifecycle section; seam=p2p_contract.validate
    def test_layout_checksum_packet_gate(self):
        def trace(layout, kind, body):
            players = sum(layout) if layout else 2
            scenario = {'format': 1, 'players': players, 'input_delay': 0, 'max_prediction': 4,
                        'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 1}]}
            if layout:
                scenario['layout'] = list(layout)
            state = initial_game_state(players, 2).hex()
            record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1,
                      'error': None, 'requests': [], 'events': [], 'extension_events': [], 'outgoing': [0],
                      'state': state}
            value = {'format': 1, 'complete': True, 'upstream_revision': REVISION,
                     'scenario': scenario, 'records': [record],
                     'packets': [{'id': 0, 'from': 0, 'to': 1, 'semantic': dict(kind=kind, **body)}]}
            return scenario, value
        checksum_report = {'frame': 60, 'checksum': '0' * 32}
        quality_report = {'frame_advantage': 0, 'ping': '0' * 32}
        quality_reply = {'pong': '0' * 32}
        goodbye = {'reason': 255}
        cases = [([1, 1], 'checksum_report', checksum_report, None),
                 ([2, 2], 'checksum_report', checksum_report, None),
                 ([1, 1], 'quality_report', quality_report, 'lifecycle packet outside explicit profile'),
                 ([1, 1], 'quality_reply', quality_reply, 'lifecycle packet outside explicit profile'),
                 ([1, 1], 'keep_alive', {}, 'lifecycle packet outside explicit profile'),
                 ([1, 1], 'goodbye', goodbye, 'lifecycle packet outside explicit profile'),
                 (None, 'checksum_report', checksum_report, 'lifecycle packet outside explicit profile')]
        for layout, kind, body, failure in cases:
            with self.subTest(layout=layout, kind=kind):
                scenario, value = trace(layout, kind, body)
                if failure is None:
                    validate(value, scenario, False)
                else:
                    with self.assertRaisesRegex(ValueError, failure):
                        validate(value, scenario, False)

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

    # Value: protects=the lifecycle path's wide-row control; fails_when=a wide scenario's
    # flipped tail byte passes the packet comparison, or a width-four scenario grows the
    # mutation; why_new=the wrap family gained a width-32 profile whose generic width
    # controls are unreachable on the lifecycle path; seam=p2p_lifecycle_controls.mutations_for
    def test_lifecycle_wide_tail_control(self):
        from p2p_lifecycle_controls import mutations_for
        actual, expected, scenario = timeout_fixture()
        row = 'aa' * 32
        statuses = [{'disconnected': False, 'epoch': 0, 'last_frame': -1} for _ in range(2)]
        packet = {'id': 0, 'from': 0, 'to': 1,
                  'semantic': {'kind': 'input', 'start_frame': 0, 'ack_frame': -1, 'statuses': statuses,
                               'players': [0], 'frames': [row]},
                  'raw': {'header': {'conn_id': 1, 'flags': 0, 'protocol_version': 2, 'sentinel': [245, 82]},
                          'body': '0000'}}
        expected['packets'] = [packet]
        actual['packets'] = deepcopy(expected['packets'])
        self.assertNotIn('wide_tail', mutations_for(actual, expected))
        scenario['input_width'] = 32
        expected['scenario']['input_width'] = 32
        mutations = mutations_for(actual, expected)
        self.assertIn('wide_tail', mutations)
        mutation, diagnostic = mutations['wide_tail']
        self.assertEqual(diagnostic, 'packet 0: semantic mismatch')
        mutant = deepcopy(actual); mutation(mutant)
        self.assertNotEqual(mutant['packets'][0]['semantic']['frames'][0][-2:], row[-2:])
        # The flip must reach exactly what compare's packet equality reads: the
        # normalized semantic frames. The full-comparator firing is exercised on
        # the real wrap traces by the launcher's control pass itself.
        normalized_actual = normalize(actual)['packets'][0]['semantic']['frames']
        normalized_mutant = normalize(mutant)['packets'][0]['semantic']['frames']
        self.assertNotEqual(normalized_mutant, normalized_actual)
        self.assertNotEqual(normalized_mutant[0][-2:], normalized_actual[0][-2:])

    # Value: protects=the builder's and evidence gate's width guards; fails_when=a
    # hostile build width escapes the builder guard, or an evidence call accepts a
    # scenario whose signature no committed profile carries; why_new=review round A2:
    # both guards were only exercised positively at launch; the width axis saturated
    # in session 196, so the evidence binding drifts on a grammar-valid but
    # uncommitted capacity/width combination instead; seam=p2p_wrap.build/evidence
    def test_wrap_width_guards(self):
        from p2p_lifecycle_controls import mutations_for
        scenario = wrap_fixture('mesh_4_wrap_flood_width_32')
        drifted = deepcopy(scenario)
        # Grammar-valid (capacity nine admits the window-four lead) but no committed
        # profile carries the wide rows on the nine-row ring, so the evidence gate's
        # profile-identity binding itself must refuse before any witness is read.
        drifted['queue_capacity'] = 9
        with self.assertRaisesRegex(ValueError, 'wrap witness profile'):
            p2p_wrap.evidence({'records': []}, drifted)
        # The positive path must still read witnesses: the undrifted fixture passes
        # the binding and fails later at the empty-records floor, so a binding
        # mutant that compares the wrong profile field (rounds for capacity) —
        # which the capacity drift alone cannot distinguish — is caught here.
        with self.assertRaisesRegex(ValueError, 'wrap witness missing pending advances'):
            p2p_wrap.evidence({'records': []}, deepcopy(scenario))
        # Hostile widths die at the builder's own grammar-bound guard before any
        # payload can carry them: anything outside the compared set, non-int
        # widths, and the literal 4 (the default row must be requested as None).
        for hostile in (4, 8, 2, 0, 33, 64, '32', True, 4.0):
            with self.subTest(width=hostile):
                with self.assertRaisesRegex(ValueError, 'input width'):
                    p2p_wrap.build(None, None, 4, 128, 142, width=hostile)
        # The wide control's width lives in the embedded scenario; a caller without
        # one fails loudly instead of silently skipping the wide control.
        with self.assertRaisesRegex(ValueError, 'embedded scenario'):
            mutations_for({'packets': []}, {'records': []})

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

    # Value: protects=the scenario-operation bound stays deliberate; fails_when=the corpus
    # scale the #379 raise admits drifts, or an above-bound inventory passes; why_new=#379
    # default-ring wrap floods; seam=validate_scenario's operation inventory
    def test_operation_inventory_bound(self):
        original = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'operations': []}
        original['operations'] = [{'kind': 'poll', 'peer': 0, 'now_us': index} for index in range(1, 20001)]
        validate_scenario(original)
        mutant = deepcopy(original)
        mutant['operations'].append({'kind': 'poll', 'peer': 0, 'now_us': 20001})
        with self.assertRaises(ValueError):
            validate_scenario(mutant)

    # Value: protects=the standalone validator's trace-size denial-of-service guard stays
    # deliberate; fails_when=the #379 raise drifts back over the seven- and eight-peer wrap
    # traces (18.2 and 25.9 megabytes spaced); why_new=#379 default-ring wrap floods;
    # seam=p2p_validate's stdin length bound
    def test_standalone_trace_size_bound(self):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        with TemporaryDirectory() as root:
            path = Path(root) / 'scenario.json'; path.write_text(json.dumps(scenario), encoding='utf-8')
            command = [sys.executable, str(Path(__file__).with_name('p2p_validate.py')), '--scenario', str(path)]
            at_bound = b'{' + b' ' * (32000000 - 2) + b'}'
            accepted = subprocess.run(command, input=at_bound, capture_output=True, timeout=30, check=False)
            self.assertEqual(accepted.returncode, 2, accepted.stderr)
            self.assertNotIn('trace size bound', accepted.stderr.decode('utf-8', 'replace'))
            rejected = subprocess.run(command, input=at_bound + b' ', capture_output=True, timeout=30, check=False)
            self.assertEqual(rejected.returncode, 2, rejected.stderr)
            self.assertEqual(rejected.stderr, b'p2p validation: trace size bound\n')

    # Value: protects=the committed wrap-flood fixtures stay consistent with their manifest
    # and the profile table; fails_when=a stale, drifted or re-profiled fixture reaches the
    # launchers, a per-peer delay profile loses its construction delays, or a width
    # profile drifts off its committed row width; why_new=#379 fixtures keep the
    # builders off the CI critical path, #383 adds the delay profiles, the width
    # profile joins the flood family; seam=p2p_launch.wrap_fixture
    def test_wrap_fixture_inventory(self):
        for name, (players, capacity, rounds, window, delays, layout, width) in p2p_wrap.PROFILES.items():
            with self.subTest(case=name):
                scenario = wrap_fixture(name)
                self.assertEqual(scenario['players'], players)
                self.assertEqual(scenario.get('queue_capacity', 128), capacity)
                self.assertEqual(scenario['max_prediction'], window)
                self.assertEqual(scenario.get('delays'), delays)
                self.assertEqual(scenario.get('layout'), layout)
                self.assertEqual(scenario.get('input_width', 4), width or 4)
                self.assertGreater(len(scenario['operations']), rounds - 2)
        manifest = json.loads((Path(p2p_launch.__file__).parent / 'fixtures/wrap_flood/MANIFEST.json').read_text(encoding='utf-8'))
        self.assertEqual(set(manifest['fixtures']), {name + '.json' for name in p2p_wrap.NAMES})

    # Value: protects=the committed width profile against a re-profiled row width;
    # fails_when=a grammar-valid fixture whose input_width drifts off its committed
    # profile loads; why_new=the flood family gained its width axis; the grammar
    # already rejects row-length drift, so the drifted fixture shrinks its rows to
    # the claimed width and exercises the profile check itself;
    # seam=p2p_launch.wrap_fixture
    def test_wrap_fixture_width_drift_refused(self):
        source = wrap_fixture('mesh_4_wrap_flood_width_32')
        drifted = deepcopy(source)
        drifted['input_width'] = 1
        for op in drifted['operations']:
            if op['kind'] == 'step':
                op['bytes'] = op['bytes'][:2]
        with TemporaryDirectory() as root:
            fixtures = Path(root)
            # The hostile shape: the committed fixture file is rewritten to a
            # re-profiled schedule and its manifest digest re-stamped to match —
            # exactly what a hand edit (or a bad regeneration) could leave behind.
            (fixtures / 'mesh_4_wrap_flood_width_32.json').write_text(json.dumps(drifted), encoding='utf-8')
            digests = {'mesh_4_wrap_flood_width_32.json':
                       hashlib.sha256((fixtures / 'mesh_4_wrap_flood_width_32.json').read_bytes()).hexdigest()}
            (fixtures / 'MANIFEST.json').write_text(json.dumps({'format': 1, 'fixtures': digests}), encoding='utf-8')
            with patch.object(p2p_launch, 'FIXTURES', fixtures):
                with self.assertRaisesRegex(ValueError, 'wrap fixture profile drift: mesh_4_wrap_flood_width_32'):
                    wrap_fixture('mesh_4_wrap_flood_width_32')

    # Value: protects=the single-fixture regeneration's fail-closed precondition and its
    # manifest merge; fails_when=--only crashes before the precondition check (the #382
    # squash lost the provenance_path hoist), rewrites a committed sibling, or cannot add a
    # genuinely new profile; why_new=the #383 delay wrap profiles are regenerated with
    # --only; seam=p2p_wrap_regenerate.main with the real fixture loader and mocked tooling
    def test_wrap_regenerate_only_precondition_and_merge(self):
        def run_main(fixtures, only):
            """main() with build/tooling mocked but the real fixture loader active."""
            real = p2p_launch.wrap_fixture
            # The merge branch digests the oracle binary for provenance; a stub
            # keeps the test independent of a built binary (CI has none).
            stub_binary = fixtures / 'oracle-binary'
            stub_binary.write_bytes(b'oracle')

            def loader(name):
                # Mirror the production contract with the corpus's current manifest:
                # a probe must name either a manifest-carried fixture or an existing
                # file; anything else fails loudly instead of silently skipping.
                manifest = fixtures / 'MANIFEST.json'
                carried = set(json.loads(manifest.read_text(encoding='utf-8')).get('fixtures', {})) \
                    if manifest.exists() else set()
                if name + '.json' not in carried and not (fixtures / (name + '.json')).exists():
                    raise AssertionError('probed a name the corpus never carried: ' + name)
                return real(name)

            with patch('sys.argv', ['p2p_wrap_regenerate.py', '--only', only]), \
                 patch.object(p2p_wrap_regenerate, 'FIXTURES', fixtures), \
                 patch.object(p2p_launch, 'FIXTURES', fixtures), \
                 patch.object(p2p_wrap_regenerate, 'wrap_fixture', loader), \
                 patch.object(p2p_wrap_regenerate, 'BINARY', stub_binary), \
                 patch.object(p2p_wrap_regenerate, 'git_identity', lambda: {'commit': 'committed'}), \
                 patch.object(p2p_wrap_regenerate, 'load_manifest', lambda: {'rust': {'version': '1.99.1'}}), \
                 patch.object(p2p_wrap_regenerate, 'sources', lambda manifest, offline: None), \
                 patch.object(p2p_wrap_regenerate, 'setup_rust', lambda manifest, offline: ('cargo', None)), \
                 patch.object(p2p_wrap_regenerate, 'execute', lambda command, log, timeout=0: None), \
                 patch.object(p2p_wrap_regenerate, 'validate', lambda value, scenario, raw: None), \
                 patch('p2p_wrap.build', lambda binary, observe, players, capacity, rounds,
                       window, delays=None, layout=None, width=None: {
                           'format': 1, 'players': players, 'input_delay': 0, 'max_prediction': window,
                           'queue_capacity': capacity,
                           **({'delays': list(delays)} if delays is not None else {}),
                           **({'layout': list(layout)} if layout is not None else {}),
                           **({'input_width': int(width)} if width is not None else {}),
                           'operations': [{'kind': 'poll', 'peer': 0, 'now_us': index}
                                          for index in range(1, rounds + 1)]}), \
                 patch('p2p_wrap_regenerate.subprocess.run') as fake_run:
                fake_run.return_value.stdout = '{"format": 1}'
                p2p_wrap_regenerate.main()

        with TemporaryDirectory() as root:
            # Red control: without the committed manifest, --only refuses for its named
            # reason instead of probing the tree (pre-fix this died on UnboundLocalError).
            empty = Path(root) / 'empty'; empty.mkdir()
            with self.assertRaisesRegex(ValueError, '--only needs the committed wrap-flood manifest'):
                run_main(empty, 'mesh_4_wrap_flood_window_8')
            # A manifest-named fixture missing from disk still refuses: --only never
            # repairs a committed corpus entry, it only adds names the manifest lacks.
            partial = Path(root) / 'partial'; partial.mkdir()
            (partial / 'MANIFEST.json').write_text(json.dumps(
                {'format': 1, 'fixtures': {'mesh_2_wrap_flood.json': 'sibling'}, 'provenance': {}}), encoding='utf-8')
            with self.assertRaisesRegex(OSError, 'mesh_2_wrap_flood.json'):
                run_main(partial, 'mesh_4_wrap_flood_window_8')
            # A valid committed corpus gains the genuinely new profile without
            # rewriting the sibling digest, and the rewrite itself re-loads cleanly.
            # The two delay profiles stay absent here (no file, no manifest entry):
            # they are the genuinely new names this regeneration adds.
            new_names = ('mesh_3_wrap_flood_delays_2_1_0', 'mesh_4_wrap_flood_delays_2_0')
            committed = Path(root) / 'committed'; committed.mkdir()
            digests = {}
            for name, (players, capacity, rounds, window, delays, layout, width) in p2p_wrap.PROFILES.items():
                if name in new_names:
                    continue
                sibling = {'format': 1, 'players': players, 'input_delay': 0, 'max_prediction': window,
                           'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 1}]}
                if capacity != 128:
                    sibling['queue_capacity'] = capacity
                if delays is not None:
                    sibling['delays'] = list(delays)
                if layout is not None:
                    sibling['layout'] = list(layout)
                if width is not None:
                    sibling['input_width'] = int(width)
                path = committed / (name + '.json')
                path.write_text(json.dumps(sibling), encoding='utf-8')
                digests[name + '.json'] = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest_path = committed / 'MANIFEST.json'
            manifest_path.write_text(json.dumps({'format': 1, 'fixtures': digests,
                                                 'provenance': {'builder': 'b', 'commit': 'old'}}), encoding='utf-8')
            run_main(committed, 'mesh_4_wrap_flood_window_8')
            merged = json.loads(manifest_path.read_text(encoding='utf-8'))
            self.assertEqual(merged['fixtures']['mesh_2_wrap_flood.json'], digests['mesh_2_wrap_flood.json'])
            self.assertIn('mesh_4_wrap_flood_window_8.json', merged['fixtures'])
            self.assertNotEqual(merged['fixtures']['mesh_4_wrap_flood_window_8.json'],
                                digests['mesh_4_wrap_flood_window_8.json'])
            self.assertEqual(merged['provenance']['commit'], 'committed')
            self.assertTrue((committed / 'mesh_4_wrap_flood_window_8.json').exists())
            # The merge path covers insertion, not only replacement: --only for
            # a genuinely new name adds its digest while every committed
            # sibling keeps its exact bytes (the first run's own rewrite is the
            # one expected exception).
            run_main(committed, 'mesh_3_wrap_flood_delays_2_1_0')
            inserted = json.loads(manifest_path.read_text(encoding='utf-8'))
            self.assertIn('mesh_3_wrap_flood_delays_2_1_0.json', inserted['fixtures'])
            rewritten = {'mesh_3_wrap_flood_delays_2_1_0.json', 'mesh_4_wrap_flood_window_8.json'}
            for name, digest in digests.items():
                if name not in rewritten:
                    self.assertEqual(inserted['fixtures'][name], digest, name)
            self.assertTrue((committed / 'mesh_3_wrap_flood_delays_2_1_0.json').exists())

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

    # Value: protects=the explicit queue profile and its capacity-aware bounds; fails_when=a profile production
    # Godot refuses to configure, a non-power-of-two capacity below the delayed-input lead, an in-band
    # Godot-refused delay, or a bound formula drift passes; seam=none
    def test_queue_capacity_profile(self):
        step = {'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': '00000000'}
        original = {'format': 1, 'players': 3, 'input_delay': 0, 'max_prediction': 4, 'queue_capacity': 9,
                    'operations': [step, {'kind': 'delay', 'peer': 0, 'delay': 6}]}
        validate_scenario(original)
        validate_scenario(dict(deepcopy(original), queue_capacity=128))
        validate_scenario(dict(deepcopy(original), queue_capacity=16, operations=[step]))
        for mutate in (lambda x: x.update(queue_capacity=5), lambda x: x.update(queue_capacity=129),
                       lambda x: x.update(queue_capacity=True), lambda x: x.update(queue_capacity=9.0),
                       lambda x: x.update(queue_capacity=None),
                       lambda x: x.update(queue_capacity=8), lambda x: x.update(input_delay=1),
                       lambda x: x['operations'][1].update(delay=4)):
            mutant = deepcopy(original); mutate(mutant)
            with self.assertRaises(ValueError):
                validate_scenario(mutant)
        self.assertEqual(godot_max_delay(4, 9), 0)
        self.assertEqual(godot_max_delay(4, 8), -1)
        self.assertEqual(godot_max_delay(4, 12), 1)
        self.assertTrue(comparable_delay(6, 4, 9) and not comparable_delay(1, 4, 9) and not comparable_delay(4, 4, 9))
        self.assertTrue(not comparable_delay(0, 4, 8) and comparable_delay(4, 4, 8))
        self.assertEqual(expected_delay_error(0, 6, 4, 9), 'INVALID_CONFIGURATION')
        self.assertEqual(expected_delay_error(0, 4, 4, 9), 'INVALID_CONFIGURATION')
        self.assertEqual(expected_delay_error(0, 0, 4, 8), 'INVALID_CONFIGURATION')
        self.assertEqual(set(DELAY_ERRORS.values()), {'UNSUPPORTED', 'INVALID_CONFIGURATION'})

    # Value: protects=the input-width grammar shared by both engines and the shrinker;
    # fails_when=an unsupported width, a wrong-length step payload, a bool/float/null alias,
    # or a width below the game's minimum passes; why_new=#365 width slice; seam=none
    def test_input_width_scenario_rules(self):
        step = {'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': 'ff'}
        original = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'input_width': 1,
                    'operations': [step, dict(step, peer=1, now_us=1)]}
        validate_scenario(original)
        for width, payload in ((4, '00000000'), (32, 'ab' * 32)):
            validate_scenario(dict(deepcopy(original), input_width=width,
                                   operations=[dict(step, bytes=payload), dict(step, peer=1, now_us=1, bytes=payload)]))
        for mutate in (lambda x: x.update(input_width=3), lambda x: x.update(input_width=2),
                       lambda x: x.update(input_width=8), lambda x: x.update(input_width=16),
                       lambda x: x.update(input_width=33), lambda x: x.update(input_width=65536),
                       lambda x: x.update(input_width=0), lambda x: x.update(input_width=True),
                       lambda x: x.update(input_width=4.0), lambda x: x.update(input_width=None),
                       lambda x: x.update(input_width='4'),
                       # A step payload shorter or longer than the configured width is refused.
                       lambda x: x['operations'][0].update(bytes='ff00'),
                       lambda x: x['operations'][0].update(bytes='')):
            mutant = deepcopy(original); mutate(mutant)
            with self.assertRaises(ValueError):
                validate_scenario(mutant)

    # Value: protects=the per-machine delay-profile grammar shared by both engines; fails_when=a
    # wrong-length, out-of-band or aliased profile, or one above the peer bound, reaches a trace;
    # why_new=#371 delay-profile slice; seam=none
    def test_delay_profile_scenario_rules(self):
        step = {'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': 'ff' * 4}
        original = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'delays': [2, 0],
                    'operations': [step, dict(step, peer=1, now_us=1)]}
        validate_scenario(original)
        validate_scenario(dict(deepcopy(original), layout=[2, 1, 1], players=4,
                               delays=[2, 0, 1], operations=[step, dict(step, peer=1, now_us=1), dict(step, peer=2, now_us=2), dict(step, peer=3, now_us=3)]))
        for mutate in (lambda x: x.update(delays=[2]), lambda x: x.update(delays=[2, 0, 0]),
                       lambda x: x.update(delays=[2, 3]), lambda x: x.update(delays=[2, 0.0]),
                       lambda x: x.update(delays=[2, True]), lambda x: x.update(delays=None),
                       lambda x: x.update(delays=[]),
                       # A profile above the peer bound refuses even when the shared delay stays inside it.
                       lambda x: x.update(delays=[2, 2], queue_capacity=10),
                       lambda x: x.update(delays='20')):
            mutant = deepcopy(original); mutate(mutant)
            with self.assertRaises(ValueError):
                validate_scenario(mutant)
        # An omitted profile keeps the shared delay for every slot, across layouts too.
        from p2p_contract import scenario_delays
        self.assertEqual(scenario_delays(original), [2, 0])
        self.assertEqual(scenario_delays(dict(deepcopy(original), layout=[2, 1, 1], players=4, delays=[2, 0, 1])), [2, 2, 0, 1])
        self.assertEqual(scenario_delays({'players': 3, 'input_delay': 1, 'operations': []}), [1, 1, 1])
        self.assertEqual(scenario_delays({'players': 4, 'input_delay': 1, 'layout': [3, 1], 'delays': [2, 0], 'operations': []}), [2, 2, 2, 0])

    # Value: protects=the width fold shared by both engines; fails_when=a fold that stops
    # matching the little-endian u32 read at the default width shifts existing fixtures;
    # why_new=#365 width slice; seam=none
    def test_input_width_fold_semantics(self):
        from p2p_contract import fold_input
        self.assertEqual(fold_input('11000000'), int.from_bytes(bytes.fromhex('11000000'), 'little'))
        self.assertEqual(fold_input('0a'), 10)
        self.assertEqual(fold_input('ff' * 4), 4294967295)
        # Independent wide-row oracle: the fold equals the XOR of the row's little-endian
        # u32 words, a formulation that shares no code with the byte-wise implementation.
        wide = bytes.fromhex('0123456789abcdef' * 2)
        expected = 0
        for start in range(0, len(wide), 4):
            expected ^= int.from_bytes(wide[start:start + 4], 'little')
        self.assertEqual(fold_input(wide.hex()), expected)

    # Value: protects=the non-default-width flight row shape; fails_when=a packet whose rows
    # are not one width-sized input per owned slot passes validation; why_new=#365 width slice; seam=none
    def test_input_width_packet_row_shape(self):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'input_width': 32,
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1, 'error': None,
                  'requests': [], 'events': [], 'extension_events': [], 'outgoing': [0],
                  'state': initial_game_state(2, 2).hex()}
        statuses = [{'disconnected': False, 'epoch': 0, 'last_frame': -1} for _ in range(2)]
        row = '11000000' + '00' * 28
        trace = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario),
                 'records': [record],
                 'packets': [{'id': 0, 'from': 0, 'to': 1,
                              'semantic': {'kind': 'input', 'start_frame': 0, 'ack_frame': -1, 'players': [0],
                                           'frames': [row], 'statuses': statuses}}]}
        validate(deepcopy(trace), scenario)
        for mutate in (lambda x: x['packets'][0]['semantic'].update(frames=['11000000']),
                       lambda x: x['packets'][0]['semantic'].update(frames=[row + 'ff']),
                       lambda x: x['packets'][0]['semantic'].update(frames=[row[:-2]])):
            mutant = deepcopy(trace); mutate(mutant)
            with self.assertRaises(ValueError):
                validate(mutant, scenario)
        # The minimum width validates a one-byte row and refuses a four-byte row.
        narrow_scenario = dict(deepcopy(scenario), input_width=1)
        narrow = deepcopy(trace); narrow['scenario'] = deepcopy(narrow_scenario)
        narrow['packets'][0]['semantic']['frames'] = ['11']
        validate(deepcopy(narrow), narrow_scenario)
        mutant = deepcopy(narrow); mutant['packets'][0]['semantic']['frames'] = ['11000000']
        with self.assertRaises(ValueError):
            validate(mutant, narrow_scenario)

    # Value: protects=the advance reconstruction at non-default widths; fails_when=a confirmed
    # slot whose bytes carry the wrong width, or a stale-wide neutral prefix, passes; why_new=#365
    # width slice; seam=none
    def test_input_width_advance_reconstruction(self):
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'input_width': 1,
                    'operations': [{'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': '11'}]}
        state = initial_game_state(2, 2)
        from p2p_contract import advance_game_state as advance
        # Independent width-1 oracle: a one-byte little-endian read is the whole fold.
        inputs = [{'player': 0, 'bytes': '11', 'status': 'confirmed'}, {'player': 1, 'bytes': '00', 'status': 'predicted'}]
        advanced = advance(state, [int.from_bytes(bytes.fromhex('11'), 'little'), 0], 2)
        save = {'kind': 'save', 'frame': 0, 'state_bytes': state.hex(), 'checksum': checksum(state), 'inputs': []}
        step = {'kind': 'advance', 'frame': 0, 'state_bytes': advanced.hex(), 'checksum': checksum(advanced), 'inputs': inputs}
        record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 1, 'confirmed_frame': -1, 'error': None,
                  'requests': [save, step], 'events': [], 'extension_events': [], 'outgoing': [],
                  'state': advanced.hex()}
        trace = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario),
                 'records': [record], 'packets': []}
        validate(deepcopy(trace), scenario)
        for mutate in (lambda x: x['records'][0]['requests'][1]['inputs'][0].update(bytes='11000000'),
                       lambda x: x['records'][0]['requests'][1]['inputs'][1].update(bytes='00000000')):
            mutant = deepcopy(trace); mutate(mutant)
            with self.assertRaises(ValueError):
                validate(mutant, scenario)

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

    # Value: protects=the explicit endpoint-layout grammar shared by both engines and the shrinker;
    # fails_when=a slot-less machine, a zero slot, a machine-count or slot-total drift, a float size,
    # a delay raise or lifecycle settings under a layout, or an alias passes; why_new=#363 layout slice; seam=none
    def test_layout_scenario_rules(self):
        step = {'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': '00000000'}
        original = {'format': 1, 'players': 4, 'input_delay': 0, 'max_prediction': 4, 'layout': [2, 2],
                    'operations': [step, dict(step, peer=1, now_us=1), dict(step, peer=2, now_us=2), dict(step, peer=3, now_us=3)]}
        validate_scenario(original)
        validate_scenario(dict(original, layout=[2, 2, 2], players=6, operations=[step, dict(step, now_us=1)]))
        validate_scenario(dict(original, layout=[2, 1, 1]))
        for mutate in (lambda x: x.update(layout=[4]), lambda x: x.update(layout=[3, 2]),
                       lambda x: x.update(layout=[2, 2, 2]), lambda x: x.update(layout=[0, 4]),
                       lambda x: x.update(layout=[2, 1]), lambda x: x.update(layout=[2.0, 2]),
                       lambda x: x.update(layout=[None, 2]), lambda x: x.update(layout=['x', 2]),
                       lambda x: x.update(layout=[[2], 2]), lambda x: x.update(layout=[True, 3]),
                       lambda x: x.update(layout=True), lambda x: x.update(layout=[2, 2, 2, 2, 2, 2, 2, 2, 2]),
                       lambda x: x.update(layout=[]), lambda x: x['operations'].append({'kind': 'delay', 'peer': 0, 'delay': 1}),
                       lambda x: x.update(lifecycle={'quality_us': 100000, 'keepalive_us': 100000, 'notify_us': 500000,
                                                     'timeout_us': 5000000, 'checksum_interval': 0, 'divergent_peer': -1})):
            mutant = deepcopy(original); mutate(mutant)
            with self.assertRaises(ValueError):
                validate_scenario(mutant)

    # Value: protects=slot-to-machine derivation for records and packet senders; fails_when=an omitted
    # layout stops being one slot per endpoint or a layout drops or reorders ownership; why_new=#363; seam=none
    def test_layout_slot_projection(self):
        self.assertEqual(slots_of({'players': 3}), [[0], [1], [2]])
        self.assertEqual(slots_of({'players': 6, 'layout': [1, 3, 2]}), [[0], [1, 2, 3], [4, 5]])

    # Value: protects=the multi-local flight row shape; fails_when=a packet whose player list drops,
    # reorders or extends the sender's owned slots, whose row width is not one four-byte input per
    # owned slot, or whose sender is not the row's machine passes; why_new=#363 multi-local wire shape; seam=none
    def test_layout_packet_row_shape(self):
        scenario = {'format': 1, 'players': 4, 'input_delay': 0, 'max_prediction': 4, 'layout': [2, 2],
                    'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1, 'error': None,
                  'requests': [], 'events': [], 'extension_events': [], 'outgoing': [0], 'state': initial_game_state(4, 2).hex()}
        statuses = [{'disconnected': False, 'epoch': 0, 'last_frame': -1} for _ in range(4)]
        packet0 = {'id': 0, 'from': 0, 'to': 1,
                   'semantic': {'kind': 'input', 'start_frame': 0, 'ack_frame': -1, 'players': [0, 1],
                                'frames': ['1100000022000000'], 'statuses': statuses}}
        trace = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario),
                 'records': [record], 'packets': [packet0]}
        validate(deepcopy(trace), scenario)
        for mutate in (lambda x: x['packets'][0]['semantic'].update(players=[0]),
                       lambda x: x['packets'][0]['semantic'].update(players=[0, 1, 2]),
                       lambda x: x['packets'][0]['semantic'].update(players=[1, 0]),
                       lambda x: x['packets'][0]['semantic'].update(frames=['11000000']),
                       lambda x: x['packets'][0]['semantic'].update(frames=['1100000022000000ff']),
                       lambda x: x['packets'][0].update(**{'from': 1}),
                       lambda x: x['packets'][0]['semantic'].update(players=[2, 3])):
            mutant = deepcopy(trace); mutate(mutant)
            with self.assertRaises(ValueError):
                validate(mutant, scenario)
        # The omitted layout keeps one slot per endpoint with four-byte rows.
        plain_scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4,
                          'operations': [{'kind': 'poll', 'peer': 0, 'now_us': 0}]}
        plain_statuses = [{'disconnected': False, 'epoch': 0, 'last_frame': -1} for _ in range(2)]
        plain = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(plain_scenario),
                 'records': [dict(record, peer=0, state=initial_game_state(2, 2).hex())],
                 'packets': [{'id': 0, 'from': 0, 'to': 1,
                              'semantic': {'kind': 'input', 'start_frame': 0, 'ack_frame': -1, 'players': [0],
                                           'frames': ['11000000'], 'statuses': plain_statuses}}]}
        validate(deepcopy(plain), plain_scenario)
        mutant = deepcopy(plain); mutant['packets'][0]['semantic'].update(frames=['1100000022000000'])
        with self.assertRaises(ValueError):
            validate(mutant, plain_scenario)

    # Value: protects=the partially-staged advance projection; fails_when=a missing-input step that
    # advanced or kept requests passes, or the source and Godot names stop mapping onto each other;
    # why_new=#363 multi-local steps; seam=none
    def test_layout_missing_input_projection(self):
        scenario = {'format': 1, 'players': 4, 'input_delay': 0, 'max_prediction': 4, 'layout': [2, 2],
                    'operations': [{'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': '11000000'}]}
        record = {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 0, 'confirmed_frame': -1, 'error': None,
                  'requests': [], 'events': [], 'outgoing': [], 'state': initial_game_state(4, 2).hex()}
        expected = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario),
                    'records': [deepcopy(record)], 'packets': []}
        expected['records'][0]['error'] = 'MissingLocalInput'
        actual = deepcopy(expected); actual['records'][0].update(error='MISSING_LOCAL_INPUT', extension_events=[])
        validate(deepcopy(expected), scenario, True)
        validate(deepcopy(actual), scenario)
        compare(actual, expected, scenario)
        self.assertEqual(normalize(deepcopy(expected), True)['records'][0]['error'], 'MISSING_LOCAL_INPUT')
        self.assertEqual(normalize(deepcopy(actual))['records'][0]['error'], 'MISSING_LOCAL_INPUT')
        for mutate in (lambda x: x['records'][0].update(frame_after=1),
                       lambda x: x['records'][0].update(requests=[{'kind': 'save', 'frame': 0, 'state_bytes': initial_game_state(4, 2).hex(),
                                                                   'checksum': checksum(initial_game_state(4, 2)), 'inputs': []}])):
            mutant = deepcopy(actual); mutate(mutant)
            with self.assertRaisesRegex(ValueError, 'missing-input step advanced'):
                validate(mutant, scenario)
            source_mutant = deepcopy(expected); mutate(source_mutant)
            with self.assertRaisesRegex(ValueError, 'missing-input step advanced'):
                validate(source_mutant, scenario, True)

    # Value: protects=per-slot delay scheduling and the per-slot neutral prefix; fails_when=a
    # confirmed row below the slot's own start or a sample on the wrong slot frame validates;
    # why_new=#371 delay-profile slice; seam=none
    def test_delay_profile_trace_rules(self):
        from p2p_contract import advance_game_state, initial_game_state, checksum
        steps = [{'kind': 'step', 'peer': 0, 'now_us': 0, 'bytes': 'ee000000'},
                 {'kind': 'step', 'peer': 1, 'now_us': 1, 'bytes': 'ff000000'}]
        scenario = {'format': 1, 'players': 2, 'input_delay': 0, 'max_prediction': 4, 'delays': [2, 0], 'operations': steps}
        state = initial_game_state(2, 2)
        after0 = advance_game_state(state, [0, 0], 2)
        after1 = advance_game_state(state, [0, 255], 2)
        request0 = {'kind': 'advance', 'frame': 0, 'state_bytes': after0.hex(), 'checksum': checksum(after0),
                    'inputs': [{'player': 0, 'bytes': '00000000', 'status': 'confirmed'},
                               {'player': 1, 'bytes': '00000000', 'status': 'predicted'}]}
        request1 = {'kind': 'advance', 'frame': 0, 'state_bytes': after1.hex(), 'checksum': checksum(after1),
                    'inputs': [{'player': 0, 'bytes': '00000000', 'status': 'predicted'},
                               {'player': 1, 'bytes': 'ff000000', 'status': 'confirmed'}]}
        records = [
            {'index': 0, 'peer': 0, 'frame_before': 0, 'frame_after': 1, 'confirmed_frame': -1, 'error': None,
             'requests': [request0], 'events': [], 'outgoing': [], 'state': after0.hex()},
            {'index': 1, 'peer': 1, 'frame_before': 0, 'frame_after': 1, 'confirmed_frame': -1, 'error': None,
             'requests': [request1], 'events': [], 'outgoing': [], 'state': after1.hex()},
        ]
        trace = {'format': 1, 'complete': True, 'upstream_revision': REVISION, 'scenario': deepcopy(scenario),
                 'records': [deepcopy(records[0]), deepcopy(records[1])], 'packets': []}
        validate(deepcopy(trace), scenario, True)
        actual = deepcopy(trace)
        for record in actual['records']:
            record['extension_events'] = []
        validate(actual, scenario)
        # Each slot's band follows its own machine: peer 1's real row stays legal at frame zero
        # only while its machine keeps delay zero, and peer 0's zero prefix only while its
        # machine keeps delay two. One shared-delay reading fails one side every time.
        for profile in ([2, 2], [0, 0]):
            shifted = deepcopy(scenario); shifted['delays'] = profile
            shifted_trace = deepcopy(trace); shifted_trace['scenario'] = shifted
            with self.assertRaisesRegex(ValueError, 'submitted confirmed prefix frame 0 slot '):
                validate(shifted_trace, shifted, True)
        # A nonzero row inside a slot's own prefix band, a record from a different frame than
        # its operation, and a moved sample still refuse.
        for mutate, expected in (
                (lambda x: x['records'][0]['requests'][0]['inputs'][0].update(bytes='ee000000'), 'submitted confirmed prefix frame 0 slot 0'),
                (lambda x: x['records'][0].update(frame_before=1), 'game/session before frame'),
                (lambda x: x['scenario']['operations'][1].update(bytes='01000000'), 'submitted confirmed prefix frame 0 slot 1')):
            mutant = deepcopy(trace); mutate(mutant)
            with self.assertRaisesRegex(ValueError, expected):
                validate(mutant, mutant['scenario'], True)

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


class ProfileReportTests(unittest.TestCase):
    """The published P2P profile report stays bound to the committed corpora.

    Value: protects=the published supported-profile claim; fails_when=the report's
    inventory drifts from the case tables the launchers actually execute; why_new=
    P5 completion criterion (#34); seam=docs/reference/p2p-profiles.md block markers.
    """

    def test_committed_report_matches_derived_inventory(self):
        report = Path(p2p_launch.__file__).parents[2] / 'docs/reference/p2p-profiles.md'
        self.assertTrue(report.exists(), 'published P2P profile report is missing')
        self.assertEqual(profile_report.check(report), None)

    # Value: protects=fixture-name honesty of the published wrap inventory; fails_when=the
    # derived wrap scope and the committed MANIFEST disagree; why_new=P5 report; seam=MANIFEST.
    def test_derived_scope_names_every_wrap_manifest_fixture(self):
        fixtures = Path(p2p_launch.__file__).parent / 'fixtures/wrap_flood'
        manifest = json.loads((fixtures / 'MANIFEST.json').read_text(encoding='utf-8'))
        scope = profile_report.p2p_scope()['p2p-wrap']
        self.assertEqual(sorted(scope), sorted(name[:-len('.json')] for name in manifest['fixtures']))
        self.assertEqual(len(scope), len(set(scope)))

    # Value: protects=fail-closed drift control; fails_when=a tampered report passes;
    # why_new=P5 report; seam=generated inventory block.
    def test_check_rejects_report_drift(self):
        report = Path(p2p_launch.__file__).parents[2] / 'docs/reference/p2p-profiles.md'
        self.assertTrue(report.exists(), 'published P2P profile report is missing')
        with TemporaryDirectory() as dir:
            mutated = Path(dir) / 'p2p-profiles.md'
            text = report.read_text(encoding='utf-8')
            self.assertIn('`mesh_2_wrap_flood`', text)
            mutated.write_text(text.replace('`mesh_2_wrap_flood`', '`mesh_2_wrap_flood_tampered`'),
                               encoding='utf-8')
            problem = profile_report.check(mutated)
            self.assertIsNotNone(problem)
            self.assertIn('mesh_2_wrap_flood_tampered', problem)

    # Value: protects=the CLI's exit contract (0 verified, 1 drift, 2 tooling error); fails_when=a
    # drift or a broken invocation reports the wrong code; why_new=P5 report; seam=main().
    def test_cli_exit_codes(self):
        tool = Path(profile_report.__file__)
        report = Path(p2p_launch.__file__).parents[2] / 'docs/reference/p2p-profiles.md'
        cases = {
            'verified': (['--check', str(report)], 0),
            'missing': (['--check', str(report.parent / 'no-such-report.md')], 2),
            'directory': (['--check', str(report.parent)], 2),
            'exclusive': (['--check', str(report), '--write', str(report)], 2),
        }
        for name, (arguments, expected) in cases.items():
            result = subprocess.run([sys.executable, str(tool), *arguments], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, f'{name}: {result.stderr[-300:]}')
        with TemporaryDirectory() as dir:
            mutated = Path(dir) / 'drifted.md'
            mutated.write_text(report.read_text(encoding='utf-8').replace('`mesh_2_wrap_flood`', '`x`'),
                               encoding='utf-8')
            result = subprocess.run([sys.executable, str(tool), '--check', str(mutated)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr[-300:])


if __name__ == '__main__':
    unittest.main()
