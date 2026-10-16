"""Value: rejects diagnostic downloads with credentials, invented callbacks or hidden storage dependencies."""
import copy
import unittest

from online_diagnostics import validate_download, game_checksum


def diagnostic_download():
    return {'filename': 'fortress-diagnostics.json', 'before': {'restores': 1, 'frame': 110},
            'after': {'restores': 1, 'frame': 110, 'storage_calls': 0}, 'report': {
                'schema': 'fortress-peer-diagnostics-v1', 'engine': '4.3.stable',
                'current_frame': 110, 'confirmed_frame': 108, 'lifecycle': 0, 'reason': 0, 'failure_frame': -1,
                'pending_rollback_frame': -1, 'frames_ahead': 0,
                'statistics': {'rollback_count': 1, 'resimulated_frames': 2, 'advanced_frames': 110,
                               'prediction_stalls': 3, 'last_rollback_depth': 2, 'max_rollback_depth': 2},
                'peers': [{'index': 0, 'state': 'running', 'pending_frames': 1, 'last_received_frame': 108,
                           'last_acked_frame': 108, 'round_trip_time_ms': 37, 'average_frame_advantage': 0}],
                'transport': {'relay_links': 0, 'pending_packets': 0, 'pending_bytes': 0}, 'failure': {}}}


class DiagnosticDownloadTests(unittest.TestCase):
    def test_opt_in_trace_requires_consent_and_checks_original_history(self):
        from online_example_probe import expected_states
        from online_diagnostics import validate_trace_history
        histories = [[0, 0] + [2] * 110, [0, 0] + [4] * 110]
        states = expected_states(histories, 110)
        value = diagnostic_download()
        value['report']['trace'] = trace_evidence(states, histories)
        validate_download(value, trace_enabled=True)
        validate_trace_history(value['report'], states, histories)
        predicted = copy.deepcopy(value)
        predicted['report']['trace']['frames'][0]['inputs'][0]['status'] = 2
        validate_download(predicted, trace_enabled=True)
        validate_trace_history(predicted['report'], states, histories)
        with self.assertRaises(ValueError):
            validate_download(value)
        for mutate in (lambda v: v['report'].pop('trace'),
                       lambda v: v['report']['trace'].update(seed='room-secret'),
                       lambda v: v['report']['trace'].update(max_frames=True),
                       lambda v: v['report']['trace']['frames'][0].update(auth_token='secret'),
                       lambda v: v['report']['trace']['frames'][0]['inputs'][0].update(bytes='0f'),
                       lambda v: v['report']['trace']['frames'][0].update(state='00' * 136),
                       lambda v: v['report']['trace'].update(retained_payload_bytes=0),
                       lambda v: v['report']['trace'].update(frames=[])):
            changed = copy.deepcopy(value)
            mutate(changed)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                validate_download(changed, trace_enabled=True)
                validate_trace_history(changed['report'], states, histories)

    def test_valid_download_with_real_callback_brackets(self):
        validate_download(diagnostic_download())
        value = diagnostic_download()
        value['after'].update(restores=2, frame=111)
        validate_download(value)

    def test_rejects_unknown_fields_at_every_exposed_boundary(self):
        for boundary in ('report', 'peer', 'statistics', 'transport', 'failure'):
            with self.subTest(boundary=boundary):
                value = diagnostic_download()
                target = value['report']
                if boundary == 'peer':
                    target = target['peers'][0]
                elif boundary != 'report':
                    target = target[boundary]
                target['auth_token'] = 'private'
                with self.assertRaises(ValueError):
                    validate_download(value)

    def test_rejects_numeric_aliases_and_wrong_completed_work(self):
        for field, invalid in [('rollback_count', 0), ('rollback_count', 2), ('advanced_frames', 111),
                               ('rollback_count', True), ('resimulated_frames', 2.0), ('prediction_stalls', -1),
                               ('last_rollback_depth', 3), ('advanced_frames', 2**63)]:
            with self.subTest(field=field, invalid=invalid):
                value = diagnostic_download()
                value['report']['statistics'][field] = invalid
                with self.assertRaises(ValueError):
                    validate_download(value)

    def test_rejects_missing_download_and_storage_use(self):
        for mutate in (lambda v: v.update(filename='other.json'), lambda v: v['after'].update(storage_calls=1),
                       lambda v: v['after'].update(storage_calls=False), lambda v: v['report'].update(engine='')):
            value = diagnostic_download()
            mutate(value)
            with self.assertRaises(ValueError):
                validate_download(value)

    def test_bounds_nested_terminal_causes_and_checksum_bytes(self):
        value = diagnostic_download()
        event = {'kind': 'desync_detected', 'frame': 60, 'peer_index': 0, 'local_checksum': '01' * 16, 'remote_checksum': '02' * 16}
        value['report']['failure'] = copy.deepcopy(event)
        validate_download(value)
        for mutate in (lambda e: e.update(remote_checksum='bad'), lambda e: e.update(peer_index=1),
                       lambda e: e.update(terminal_cause=[copy.deepcopy(event)] * 3),
                       lambda e: e.update(terminal_cause=[{'kind': 'overflow', 'terminal_cause': [
                           {'kind': 'overflow', 'terminal_cause': [copy.deepcopy(event)]}]}])):
            invalid = copy.deepcopy(value)
            mutate(invalid['report']['failure'])
            with self.assertRaises(ValueError):
                validate_download(invalid)


def trace_evidence(states, histories):
    frames = [{'frame': frame, 'state': state, 'state_available': True, 'checksum': game_checksum(state),
               'inputs': [{'player': player, 'bytes': bytes([histories[player][frame]]).hex(), 'status': 1} for player in range(2)]}
              for frame, state in states.items() if frame < 110]
    return {'schema': 'fortress-canonical-trace-v1', 'seed': '1701', 'application_version': 'fortress-online-integer-v1',
            'replay_command': '', 'max_frames': 120, 'max_payload_bytes': 18480, 'max_export_bytes': 198752,
            'retained_payload_bytes': len(frames) * 154, 'first_divergence': {}, 'frames': frames}
