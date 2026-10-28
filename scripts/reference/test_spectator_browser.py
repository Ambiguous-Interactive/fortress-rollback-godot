"""Value: reject exported qualification receipts without complete physical and canonical evidence."""
import copy
import unittest
import subprocess
import shutil
from pathlib import Path
from types import SimpleNamespace

from spectator_browser import validate, validate_fault


class SpectatorBrowserTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node is required for browser event controls')
    def test_request_failures_are_fatal_until_deliberate_teardown(self):
        source = Path(__file__).parent / 'browser/spectator.cjs'
        script = """
const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {observeErrors}=require(process.argv[1]);
const page=new EventEmitter(), errors=[];
let closing=false;
observeErrors(page,errors,()=>closing);
page.emit('pageerror',new Error('page failure'));
page.emit('console',{type:()=> 'log',text:()=> 'ignored'});
page.emit('console',{type:()=> 'error',text:()=> 'console failure'});
assert.deepEqual(errors,['page failure','console failure']);
page.emit('requestfailed',{});
assert.equal(errors.length,3,'active request failure must be captured');
closing=true;
page.emit('requestfailed',{});
assert.equal(errors.length,3,'deliberate close must not invent a request failure');
"""
        result = subprocess.run(['node', '-e', script, str(source.resolve())], capture_output=True, encoding='utf-8', timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fault_requires_no_acceptance_completion_or_playback(self):
        browser = {'browser': 'Chromium', 'version': '156.0', 'errors': [],
                   'result': {'passed': False, 'reason': 'browser original-state or membership binding', 'errors': []},
                   'state': {'compared': 0, 'frame': 0, 'simulations': 0, 'accept_pending': False, 'accept_delivered': False}}
        control = SimpleNamespace(accepted_once=False, received=0, done=None)
        validate_fault(1, browser, True, control)
        with self.assertRaises(ValueError):
            validate_fault(1, browser, True, control, 'late browser teardown failure')
        for changes in [{'accepted_once': True}, {'received': 1}, {'done': {}}, {'done': {'complete': True}}]:
            with self.subTest(control=changes), self.assertRaises(ValueError):
                validate_fault(1, browser, True, SimpleNamespace(**{**vars(control), **changes}))
        for field, value in browser['state'].items():
            for bad in [None, True if type(value) is int else 1, 1 if type(value) is int else True, float(value)]:
                with self.subTest(field=field, value=bad), self.assertRaises(ValueError):
                    validate_fault(1, {**browser, 'state': {**browser['state'], field: bad}}, True, control)
        for changes in [{'state': None}, {'state': {}}, {'errors': ['late failure']}, {'result': {}}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_fault(1, {**browser, **changes}, True, control)
        for code, alive in [(0, True), (1, False)]:
            with self.subTest(code=code, alive=alive), self.assertRaises(ValueError):
                validate_fault(code, browser, alive, control)

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
