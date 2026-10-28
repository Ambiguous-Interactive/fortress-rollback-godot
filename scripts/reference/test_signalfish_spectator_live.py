"""Fail-closed receipt controls for actual spectator playback evidence."""
import copy
import json
import unittest

from signalfish_spectator_live import DEPARTURE, FAILURE, LATE_SIGNALS, MARKER, validate_departure, validate_late_failure, validate_result


class SpectatorLiveTests(unittest.TestCase):
    def valid(self):
        return {'passed': True, 'frames': 48, 'compared': 48, 'seated_players': 2, 'viewer_seated': False,
                'host_rollbacks': 46, 'binary_receives': 100, 'viewer_binary_receives': 50, 'catchup_steps': 4, 'paused_frames': 8, 'provisioning_controls': 7}

    # Value: protects=physical loss receipt; fails_when=socket, history or canonical evidence is absent; why_new=clean-end receipts omit loss; seam=none
    def test_departure_requires_remote_socket_and_buffered_history_evidence(self):
        for departure in ['host', 'viewer']:
            healthy = {'passed': True, 'departure': departure, 'remote_departure': True, 'socket_closed': True,
                       'host_continued': departure == 'viewer', 'host_frame': 21 if departure == 'viewer' else 20,
                       'buffered_rows': 8, 'viewer_frame': 10, 'compared': 10, 'viewer_binary_receives': 18}
            self.assertEqual(validate_departure(0, DEPARTURE + json.dumps(healthy), departure), healthy)
            for field in healthy:
                invalid = [None, 0, True, float(healthy[field])] if type(healthy[field]) is int else [None, 1, not healthy[field]]
                if field == 'departure':
                    invalid = [None, 1, 'viewer' if departure == 'host' else 'host']
                for value in invalid:
                    if type(value) is type(healthy[field]) and value == healthy[field]:
                        continue
                    altered = {**healthy, field: value}
                    with self.subTest(departure=departure, field=field, value=value), self.assertRaises(ValueError):
                        validate_departure(0, DEPARTURE + json.dumps(altered), departure)
            for changed in [{'viewer_frame': 20, 'compared': 20}, {'buffered_rows': 1}, {'buffered_rows': 30}, {'compared': 9}]:
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    validate_departure(0, DEPARTURE + json.dumps({**healthy, **changed}), departure)
            output = DEPARTURE + json.dumps(healthy)
            for code, text in [(1, output), (0, ''), (0, output + '\n' + output), (0, output + '\nERROR: late failure'),
                               (0, output + '\n' + MARKER + '{}'), (0, output + '\n' + FAILURE + '{}')]:
                with self.subTest(code=code), self.assertRaises(ValueError):
                    validate_departure(code, text, departure)

    def test_late_controls_require_the_actual_final_failure(self):
        for name in LATE_SIGNALS:
            row = {'reason': 'late SDK error or spectator altered host seats', 'errors': [name]}
            healthy = FAILURE + json.dumps(row)
            self.assertEqual(validate_late_failure(1, healthy, name), {'signal': name, 'rejected': True})
            for status, output in [(0, healthy), (1, ''), (1, healthy + '\n' + healthy),
                                   (1, FAILURE + json.dumps({**row, 'reason': 'timed out: SDK login'})),
                                   (1, FAILURE + json.dumps({**row, 'errors': ['another failure']})),
                                   (1, healthy + '\n' + MARKER + json.dumps(self.valid())), (1, healthy + '\nERROR: broken callback')]:
                with self.subTest(name=name, status=status), self.assertRaises(ValueError):
                    validate_late_failure(status, output, name)

    def test_observed_playback_controls_and_physical_delivery_are_required(self):
        healthy = self.valid()
        self.assertEqual(validate_result(0, MARKER + json.dumps(healthy)), healthy)
        for field in healthy:
            for value in [None, True if type(healthy[field]) is int else 1, 0, float(healthy[field])]:
                if type(value) is type(healthy[field]) and value == healthy[field]:
                    continue
                altered = copy.deepcopy(healthy)
                altered[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    validate_result(0, MARKER + json.dumps(altered))
        for output, code in [('', 0), (MARKER + json.dumps(healthy), 1),
                             (MARKER + json.dumps(healthy) + '\n' + MARKER + json.dumps(healthy), 0),
                             (MARKER + json.dumps(healthy) + '\nSCRIPT ERROR: late failure', 0)]:
            with self.subTest(code=code, output=output), self.assertRaises(ValueError):
                validate_result(code, output)


if __name__ == '__main__':
    unittest.main()
