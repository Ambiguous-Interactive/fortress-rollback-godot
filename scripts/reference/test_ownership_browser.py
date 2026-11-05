"""Value: browser batches reject unsafe selectors and deliver every selected suite to the Web host."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

import ownership_probes as probes


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'scripts/reference/browser/ownership.cjs'
SUITES = [f'res://tests/unit/test_{name}.gd' for name in ('alpha', 'beta', 'gamma', 'delta')]
MOCK = r"""
let capture=()=>{};
function inject(phase) {
  if(!process.env.OWNERSHIP_TEST_CAPTURE_PHASE?.split(',').includes(phase))return;
  const kind=process.env.OWNERSHIP_TEST_CAPTURE_KIND||'console';
  const message=process.env.OWNERSHIP_TEST_CAPTURE_MESSAGE||'unexpected renderer failure';
  for(let count=0;count<Number(process.env.OWNERSHIP_TEST_CAPTURE_COUNT||1);count++)
    capture(kind,kind==='pageerror'?new Error(message):{type:()=> 'error',text:()=>message});
}
module.exports.inject=inject;
for (const engine of ['chromium', 'firefox']) module.exports[engine] = { async launch(options) {
  const contexts = [];
  return {
  version: () => 'fixture', contexts: () => contexts,
  async close() {
    inject('browser');
    setImmediate(()=>inject('drain'));
    if (process.env.OWNERSHIP_TEST_CLEANUP) console.error(JSON.stringify({cleanup: 'browser', open_contexts: contexts.length}));
    if (process.env.OWNERSHIP_TEST_CLEANUP === 'browser-error') throw new Error('fixture browser close failure');
  },
  async newPage() {
    const context = { async close() {
      await Promise.resolve();
      inject('context');
      contexts.splice(contexts.indexOf(context), 1);
      if (process.env.OWNERSHIP_TEST_CLEANUP) console.error(JSON.stringify({cleanup: 'context'}));
      if (process.env.OWNERSHIP_TEST_CLEANUP === 'context-error') throw new Error('fixture context close failure');
    } };
    contexts.push(context);
    let url;
    const listeners={};capture=(kind,value)=>listeners[kind]?.(value);
    return { on(kind,callback) {listeners[kind]=callback;}, inject, async goto(value) { url = value; },
      async waitForFunction(_operation, _argument, options) {
        if (options.timeout !== 180000) throw new Error('page watchdog changed');
        if (process.env.OWNERSHIP_TEST_TIMEOUT) throw new Error('fixture watchdog');
      },
      async evaluate(operation) {
        global.document = { body: { dataset: {
          fortressOwnership: JSON.stringify({ url, engine, options }),
          fortressOwnershipProgress: JSON.stringify({ case: 'fixture', completed: 1 }),
        } } };
        return operation();
      },
    };
  },
}; } };
"""


@unittest.skipUnless(shutil.which('node'), 'Node is required for the browser CLI contract')
class OwnershipBrowserTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='ownership-browser-', dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.export = Path(self.temporary.name)
        self.mock = self.export / 'playwright.cjs'
        self.mock.write_text(MOCK, encoding='utf-8')
        self.xdotool = self.export / 'xdotool'
        self.xdotool.write_text('''#!/usr/bin/env python3
import sys
commands = {'search': '42', 'getdisplaygeometry': '1280 1024',
            'getwindowgeometry': 'WINDOW=42\\nX=0\\nY=0\\nWIDTH=1280\\nHEIGHT=720\\nSCREEN=0'}
print(commands.get(sys.argv[1], ''))
''')
        self.xdotool.chmod(0o755)

    def run_browser(self, selector, *, timeout=False, root=None, selected="chromium", verified=True, case_name=None, cleanup=False, extra_env=None):
        env = {**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(self.mock),
               'FORTRESS_OWNERSHIP_BROWSER': selected, 'FORTRESS_XDOTOOL_EXECUTABLE': str(self.xdotool)}
        for name in ('chromium', 'firefox'):
            env.pop('FORTRESS_' + name.upper() + '_EXECUTABLE', None)
        if verified:
            env['FORTRESS_' + selected.upper() + '_EXECUTABLE'] = '/fixture/' + selected
        if cleanup:
            env['OWNERSHIP_TEST_CLEANUP'] = str(cleanup)
        if timeout:
            env['OWNERSHIP_TEST_TIMEOUT'] = '1'
        else:
            env.pop('OWNERSHIP_TEST_TIMEOUT', None)
        env.update(extra_env or {})
        command = ['node', str(RUNNER), str(root or self.export)]
        if selector is not None:
            command.append(selector)
        if case_name is not None:
            command.append(case_name)
        return subprocess.run(command, env=env, capture_output=True, encoding='utf-8', check=False, timeout=10)

    # Value: protects=captured browser errors remain fatal after an expected operation failure;
    # fails_when=chooser rejection skips latched renderer errors; why_new=cleanup checks only exercise rejected close promises; seam=owned runner double
    def test_expected_download_failure_cannot_hide_captured_browser_errors(self):
        hook = self.export / 'download-hook.cjs'
        helper = ROOT / 'scripts/reference/browser/replay_download.cjs'
        hook.write_text("""
const helper=require(%s);
const http=require('node:http');
const createServer=http.createServer;
http.createServer=(...args)=>{
  const server=createServer(...args),close=server.close;
  server.close=callback=>close.call(server,error=>{
    require(process.env.FORTRESS_PLAYWRIGHT_PACKAGE).inject('server');callback(error);
  });
  return server;
};
helper.replayDownloads=async(page,url,output,errors,onLoaded,acknowledge)=>{
  page.inject('operation');
  if(process.env.OWNERSHIP_TEST_ACK && typeof acknowledge==='function')acknowledge();
  throw new Error(process.env.OWNERSHIP_TEST_OPERATION||'replay chooser failed to pause playback');
};
""" % json.dumps(str(helper)))
        for phase in ('operation', 'context', 'browser', 'server', 'drain'):
            for kind in ('console', 'pageerror'):
                with self.subTest(phase=phase, kind=kind):
                    child = self.run_browser('--replay-downloads', case_name=str(self.export / 'downloads'), extra_env={
                        'NODE_OPTIONS': '--require=' + str(hook), 'FORTRESS_REPLAY_DOWNLOAD_CONTROL': 'chooser-pause',
                        'OWNERSHIP_TEST_CAPTURE_PHASE': phase, 'OWNERSHIP_TEST_CAPTURE_KIND': kind})
                    self.assertEqual(child.returncode, 1)
                    self.assertEqual(child.stdout, '')
                    self.assertIn('AggregateError', child.stderr)
                    self.assertIn('replay chooser failed to pause playback', child.stderr)
                    self.assertIn('unexpected renderer failure', child.stderr)
        for acknowledged, count, kind, accepted in [(True, 1, 'console', True), (False, 1, 'console', False),
                                                    (True, 2, 'console', False), (True, 1, 'pageerror', False)]:
            with self.subTest(acknowledged=acknowledged, count=count, kind=kind):
                child = self.run_browser('--replay-downloads', case_name=str(self.export / 'downloads'), extra_env={
                    'NODE_OPTIONS': '--require=' + str(hook), 'FORTRESS_REPLAY_DOWNLOAD_CONTROL': 'late-error',
                    'OWNERSHIP_TEST_CAPTURE_PHASE': 'operation', 'OWNERSHIP_TEST_CAPTURE_KIND': kind,
                    'OWNERSHIP_TEST_CAPTURE_COUNT': str(count), 'OWNERSHIP_TEST_CAPTURE_MESSAGE': 'late replay download control',
                    'OWNERSHIP_TEST_ACK': '1' if acknowledged else '',
                    'OWNERSHIP_TEST_OPERATION': 'replay download forbidden events observed'})
                self.assertEqual(child.returncode, 1)
                self.assertEqual(child.stdout, '')
                self.assertEqual(child.stderr.startswith('Error: replay download forbidden events observed\n'), accepted, child.stderr)
                self.assertEqual('AggregateError' in child.stderr, not accepted, child.stderr)
        for phase in ('context', 'browser', 'server', 'drain'):
            with self.subTest(acknowledged=True, extra_phase=phase):
                child = self.run_browser('--replay-downloads', case_name=str(self.export / 'downloads'), extra_env={
                    'NODE_OPTIONS': '--require=' + str(hook), 'FORTRESS_REPLAY_DOWNLOAD_CONTROL': 'late-error',
                    'OWNERSHIP_TEST_CAPTURE_PHASE': 'operation,' + phase, 'OWNERSHIP_TEST_CAPTURE_KIND': 'console',
                    'OWNERSHIP_TEST_CAPTURE_MESSAGE': 'late replay download control', 'OWNERSHIP_TEST_ACK': '1',
                    'OWNERSHIP_TEST_OPERATION': 'replay download forbidden events observed'})
                self.assertEqual(child.returncode, 1)
                self.assertEqual(child.stdout, '')
                self.assertIn('AggregateError', child.stderr)
                self.assertIn('captured browser failures', child.stderr)

    # Value: protects=selected suite coverage; fails_when=URL omits/replaces/reorders selectors; why_new=Python mocks skip real Node CLI; seam=module double
    def test_every_suite_reaches_the_page_at_both_batch_boundaries(self):
        for suites in (SUITES[:1], SUITES):
            with self.subTest(suites=suites):
                child = self.run_browser(json.dumps(suites))
                self.assertEqual(child.returncode, 0, child.stderr)
                receipt = json.loads(child.stdout)
                self.assertEqual(set(receipt), {'browser', 'version', 'result', 'errors'})
                self.assertEqual(receipt['errors'], [])
                url = urlsplit(receipt['result']['url'])
                self.assertEqual(url.path, '/index.html')
                self.assertEqual(parse_qs(url.query), {'suite': suites})

    # Value: protects=one exact case reaches the Web host without widening selection; fails_when=case ignored; why_new=suite-only URL; seam=module double
    def test_exact_case_selector_requires_one_suite_and_reaches_the_page(self):
        child = self.run_browser(json.dumps(SUITES[:1]), case_name='two_peers')
        self.assertEqual(child.returncode, 0, child.stderr)
        value = json.loads(child.stdout)
        self.assertEqual(parse_qs(urlsplit(value['result']['url']).query), {'suite': SUITES[:1], 'case': ['two_peers']})
        for suites, name in [(SUITES, 'two_peers')] + [(SUITES[:1], name) for name in ('', 'two peers', 'two_peers&case=other', '../case', '1', 'True')]:
            with self.subTest(suites=suites, name=name):
                child = self.run_browser(json.dumps(suites), case_name=name)
                self.assertNotEqual(child.returncode, 0)
                self.assertEqual(child.stdout, '')
                self.assertIn('case', child.stderr)

    # Value: protects=selected executable and Firefox WebGL launch; fails_when=Chromium silently substitutes;
    # why_new=URL tests do not inspect browser launch options; seam=module double
    def test_selected_browser_uses_verified_executable_and_preserves_page_result(self):
        for selected in ('chromium', 'firefox'):
            with self.subTest(selected=selected):
                child = self.run_browser(json.dumps(SUITES), selected=selected)
                self.assertEqual(child.returncode, 0, child.stderr)
                value = json.loads(child.stdout)
                self.assertEqual(value['browser'], selected.title())
                self.assertEqual(value['result']['engine'], selected)
                self.assertEqual(value['result']['options']['executablePath'], '/fixture/' + selected)
                self.assertEqual(value['result']['options']['headless'], selected != 'firefox')
                self.assertEqual(parse_qs(urlsplit(value['result']['url']).query), {'suite': SUITES})
                if selected == 'firefox':
                    self.assertEqual(value['result']['options']['firefoxUserPrefs'], PREFERENCES)
                    self.assertEqual(value['firefox_preferences'], PREFERENCES)
                    self.assertEqual(value['display']['x'], 0)

    # Value: dispose owned windows before Firefox waits for startup idle tasks; fails_when=browser closes with a live context; seam=module double
    def test_contexts_close_before_browser_on_success_and_watchdog_failure(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout):
                child = self.run_browser(json.dumps(SUITES[:1]), selected='firefox', timeout=timeout, cleanup=True)
                self.assertEqual(child.returncode, int(timeout), child.stderr)
                cleanup = [json.loads(line) for line in child.stderr.splitlines()
                           if line.startswith('{') and 'cleanup' in json.loads(line)]
                self.assertEqual(cleanup, [{'cleanup': 'context'}, {'cleanup': 'browser', 'open_contexts': 0}])

    # Value: cleanup failures still close the process and HTTP server; fails_when=failed context skips browser or failed browser leaks server; seam=module double
    def test_cleanup_failures_reject_the_process_after_finishing_other_cleanup(self):
        for boundary in ('context', 'browser'):
            with self.subTest(boundary=boundary):
                child = self.run_browser(json.dumps(SUITES[:1]), selected='firefox', cleanup=boundary + '-error')
                self.assertNotEqual(child.returncode, 0)
                self.assertEqual(child.stdout, '', 'cleanup failure must not publish a candidate')
                self.assertIn('fixture ' + boundary + ' close failure', child.stderr)
                cleanup = [json.loads(line) for line in child.stderr.splitlines()
                           if line.startswith('{') and 'cleanup' in json.loads(line)]
                self.assertEqual(cleanup, [{'cleanup': 'context'}, {'cleanup': 'browser', 'open_contexts': 0}])

    def test_unknown_browser_or_missing_executable_never_publishes_success(self):
        for selected, verified in [('webkit', True), ('chromium', False), ('firefox', False)]:
            with self.subTest(selected=selected, verified=verified):
                child = self.run_browser(json.dumps(SUITES[:1]), selected=selected, verified=verified)
                self.assertNotEqual(child.returncode, 0)
                self.assertEqual(child.stdout, '')
                self.assertIn('browser', child.stderr)

    # Value: protects=fail-closed batch boundary; fails_when=empty/duplicate/unsafe selector opens a page; why_new=host selection cannot validate CLI shape; seam=module double
    def test_invalid_selectors_fail_without_a_success_receipt(self):
        invalid = [None, 'no-json', '{}', 'null', '[]', json.dumps(SUITES + [SUITES[0]]),
                   json.dumps(SUITES[:1] * 2), '[1]', '[null]', '[{}]']
        invalid += [json.dumps([value]) for value in ('', 'tests/unit/test_alpha.gd',
                    'res://tests/unit/test_alpha.gd\n', 'res://tests/unit/test_alpha.gd\r',
                    'res://tests/unit/../test_alpha.gd', 'res://tests/unit/test_alpha.gd?other=1',
                    'res://tests/unit/test_alpha.gd#fragment', 'res://tests/unit/test_alpha.gd&suite=other',
                    'res://tests/unit/test_alpha.gd\\bad', 'res://tests/unit//test_alpha.gd')]
        for selector in invalid:
            with self.subTest(selector=selector):
                child = self.run_browser(selector)
                self.assertNotEqual(child.returncode, 0)
                self.assertEqual(child.stdout, '')
                self.assertIn('suite', child.stderr.lower())

    # Value: protects=existing export requirement; fails_when=non-directory root reaches browser; why_new=CLI previously assumed root; seam=module double
    def test_export_root_must_be_an_existing_directory(self):
        for root in (self.export / 'absent', self.mock):
            with self.subTest(root=root):
                child = self.run_browser(json.dumps(SUITES[:1]), root=root)
                self.assertNotEqual(child.returncode, 0)
                self.assertEqual(child.stdout, '')

    # Value: protects=watchdog diagnosis names current batch; fails_when=timeout discards suite/progress; why_new=CLI success cannot cover timeout; seam=module double
    def test_watchdog_retains_batch_and_progress(self):
        child = self.run_browser(json.dumps(SUITES), timeout=True)
        self.assertNotEqual(child.returncode, 0)
        self.assertEqual(child.stdout, '')
        details = [json.loads(line) for line in child.stderr.splitlines() if line.startswith('{')]
        self.assertEqual(details[-1]['suites'], SUITES)
        self.assertEqual(details[-1]['stage'], 'ownership-result')
        self.assertEqual(details[-1]['progress'], {'case': 'fixture', 'completed': 1})
        self.assertEqual(details[-1]['errors'], [])


PINS = {'browser': {'chromium_version': '141.0.7390.37', 'firefox_version': '142.0.1'}}
PREFERENCES = {'webgl.force-enabled': True, 'webgl.disabled': False, 'toolkit.shutdown.fastShutdownStage': 0}


def observed(name):
    value = {'browser': name.title(), 'version': PINS['browser'][name + '_version'], 'errors': [], 'result': {}}
    if name == 'firefox':
        value.update(firefox_preferences=PREFERENCES.copy(), display={
            'x': 0, 'y': 0, 'width': 1280, 'height': 720, 'screen_width': 1280, 'screen_height': 1024})
    return value


class OwnershipBrowserIdentityTests(unittest.TestCase):
    # Value: protects=selected engine identity and WebGL evidence; fails_when=Chromium or unpinned Firefox substitutes;
    # why_new=existing browser tests only require a nonempty Chromium version; seam=none
    def test_pinned_selected_browser_acceptance_and_substitution_rejection(self):
        for name in ('chromium', 'firefox'):
            control = observed(name)
            self.assertEqual(probes.validate_browser(control, None, name, PINS), (name.title(), control['version']))
            for field, replacement in [('browser', 'Chromium' if name == 'firefox' else 'Firefox'),
                                       ('version', 'unverified'), ('errors', ['engine failed'])]:
                changed = copy.deepcopy(control)
                changed[field] = replacement
                with self.subTest(name=name, field=field), self.assertRaises(ValueError):
                    probes.validate_browser(changed, None, name, PINS)
        for field in ('firefox_preferences', 'display'):
            for replacement in (None, {}, {'x': False}, {'webgl.force-enabled': 1, 'webgl.disabled': False}):
                changed = observed('firefox')
                changed[field] = replacement
                with self.subTest(field=field, replacement=replacement), self.assertRaises(ValueError):
                    probes.validate_browser(changed, None, 'firefox', PINS)

    # Value: late updater locks require full shutdown; missing, coerced or fast settings cannot qualify Firefox.
    def test_full_shutdown_preference_requires_exact_integer_zero(self):
        for replacement in (None, False, True, 0.0, 1, 3, '0'):
            changed = observed('firefox')
            if replacement is None:
                del changed['firefox_preferences']['toolkit.shutdown.fastShutdownStage']
            else:
                changed['firefox_preferences']['toolkit.shutdown.fastShutdownStage'] = replacement
            with self.subTest(replacement=replacement), self.assertRaisesRegex(ValueError, 'preferences'):
                probes.validate_browser(changed, None, 'firefox', PINS)


if __name__ == '__main__':
    unittest.main()
