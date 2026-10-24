"""Value: browser batches reject unsafe selectors and deliver every selected suite to the Web host."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'scripts/reference/browser/ownership.cjs'
SUITES = [f'res://tests/unit/test_{name}.gd' for name in ('alpha', 'beta', 'gamma', 'delta')]
MOCK = r"""
module.exports.chromium = { async launch() { return {
  version: () => 'fixture', async close() {}, async newPage() {
    let url;
    return { on() {}, async goto(value) { url = value; },
      async waitForFunction(_operation, _argument, options) {
        if (options.timeout !== 180000) throw new Error('page watchdog changed');
        if (process.env.OWNERSHIP_TEST_TIMEOUT) throw new Error('fixture watchdog');
      },
      async evaluate(operation) {
        global.document = { body: { dataset: {
          fortressOwnership: JSON.stringify({ url }),
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

    def run_browser(self, selector, *, timeout=False, root=None):
        env = {**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(self.mock)}
        if timeout:
            env['OWNERSHIP_TEST_TIMEOUT'] = '1'
        else:
            env.pop('OWNERSHIP_TEST_TIMEOUT', None)
        command = ['node', str(RUNNER), str(root or self.export)]
        if selector is not None:
            command.append(selector)
        return subprocess.run(command, env=env, capture_output=True, encoding='utf-8', check=False, timeout=10)

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


if __name__ == '__main__':
    unittest.main()
