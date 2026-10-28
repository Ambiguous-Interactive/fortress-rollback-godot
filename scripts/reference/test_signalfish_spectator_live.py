"""Fail-closed receipt controls for actual spectator playback evidence."""
import copy
import json
import unittest

from signalfish_spectator_live import FAILURE, LATE_SIGNALS, MARKER, validate_late_failure, validate_result


class SpectatorLiveTests(unittest.TestCase):
    def valid(self):
        return {'passed': True, 'frames': 48, 'compared': 48, 'seated_players': 2, 'viewer_seated': False,
                'host_rollbacks': 46, 'binary_receives': 100, 'viewer_binary_receives': 50, 'catchup_steps': 4, 'paused_frames': 8, 'provisioning_controls': 7}

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
