"""Value: rejects diagnostic downloads with credentials, invented callbacks or hidden storage dependencies."""
import copy
import unittest

from online_diagnostics import validate_download


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
