"""Value: reject exported qualification receipts without complete physical and canonical evidence."""
import copy
import unittest

from spectator_browser import validate


class SpectatorBrowserTests(unittest.TestCase):
    def healthy(self):
        host = {'passed': True, 'frames': 48, 'seated_players': 2, 'confirmed': 47, 'host_rollbacks': 46}
        browser = {'browser': 'Chromium', 'version': '156.0', 'errors': [], 'result':
                   {'passed': True, 'frames': 48, 'compared': 48, 'viewer_seated': False, 'paused_turns': 12,
                    'paused_rows': 8, 'viewer_binary_receives': 51, 'catchup_steps': 4}}
        return host, browser

    def test_each_required_observation_rejects_absence_and_numeric_lookalikes(self):
        host, browser = self.healthy()
        validate(host, browser)
        for section in ['host', 'result']:
            row = host if section == 'host' else browser['result']
            for field, value in row.items():
                for bad in [None, 1 if type(value) is bool else True, float(value), 0]:
                    if type(bad) is type(value) and bad == value:
                        continue
                    first, second = copy.deepcopy((host, browser))
                    target = first if section == 'host' else second['result']
                    target[field] = bad
                    with self.subTest(section=section, field=field, value=bad), self.assertRaises(ValueError):
                        validate(first, second)
        for changes in [{'browser': 'Firefox'}, {'version': ''}, {'errors': ['late engine failure']}, {'result': None}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate(host, {**browser, **changes})
        for changes in [{'catchup_steps': 5}, {'catchup_steps': 1}, {'paused_rows': 1}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate(host, {**browser, 'result': {**browser['result'], **changes}})
        for first, second in [(None, browser), (host, None), ({}, {}), (host, {'result': []})]:
            with self.subTest(first=first, second=second), self.assertRaises(ValueError):
                validate(first, second)


if __name__ == '__main__':
    unittest.main()
