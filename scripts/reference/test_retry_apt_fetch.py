"""Exercise the bounded dropped-archive retry around CI package acquisition."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ROOT / 'scripts/reference/retry_apt_fetch.sh'
DROP_SIGNATURE = 'E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?'
DROPPED_ARCHIVE = ('E: Failed to fetch https://security.ubuntu.com/ubuntu/pool/universe/f/fonts-tlwg/'
                   'fonts-tlwg-loma-otf_0.7.3-1_all.deb')


# Value: protects=Reference jobs finish dependency installs when a mirror drops one archive;
# fails_when=the wrapper retries non-acquisition failures, retries more than once, or hides the
# dropped packages; why_new=an unchanged security.ubuntu.com fetch failed main CI (#349); seam=owned CLI command
class RetryAptFetchTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        owned = tempfile.TemporaryDirectory(prefix='apt-retry-fixture-', dir=scratch)
        self.addCleanup(owned.cleanup)
        self.directory = Path(owned.name)
        self.counter = self.directory / 'invocations'
        self.plan = self.directory / 'plan.txt'

    def run_wrapper(self, plan):
        """Run the wrapper around a fake acquisition command following the attempt plan."""
        rows = []
        for code, body in plan:
            rows.append(str(code) + '|' + body.replace('\n', '\\n'))
        self.plan.write_text('\n'.join(rows))
        fake = self.directory / 'fake-acquire.sh'
        fake.write_text(
            '#!/usr/bin/env bash\n'
            'n=$(( $(cat "$RETRY_COUNTER" 2>/dev/null || echo 0) + 1 ))\n'
            'printf \'%s\' "$n" > "$RETRY_COUNTER"\n'
            'record="$(sed -n "${n}p" "$RETRY_PLAN")"\n'
            '[[ -z "$record" ]] && record="$(tail -n 1 "$RETRY_PLAN")"\n'
            'code="${record%%|*}"\n'
            'body="${record#*|}"\n'
            '[[ -n "$body" ]] && printf \'%b\\n\' "$body"\n'
            'exit "$code"\n')
        fake.chmod(0o755)
        environment = dict(os.environ, RETRY_COUNTER=str(self.counter), RETRY_PLAN=str(self.plan))
        return subprocess.run(['bash', str(COMMAND), str(fake)],
                              capture_output=True, text=True, encoding='utf-8',
                              timeout=10, env=environment)

    def invocations(self):
        return int(self.counter.read_text()) if self.counter.exists() else 0

    def test_clean_success_runs_once_without_retry(self):
        result = self.run_wrapper([(0, '')])
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(self.invocations(), 1)
        self.assertIn('attempt 1 of 2', result.stdout)
        self.assertNotIn('Retrying', result.stdout + result.stderr)

    def test_dropped_archive_recovers_through_exactly_one_named_retry(self):
        result = self.run_wrapper([(100, DROPPED_ARCHIVE + '\n' + DROP_SIGNATURE), (0, '')])
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(self.invocations(), 2)
        self.assertIn('fonts-tlwg-loma-otf_0.7.3-1_all.deb', result.stderr)
        self.assertIn('attempt 2 of 2', result.stderr)

    def test_persistent_drop_fails_after_the_single_retry(self):
        result = self.run_wrapper([(100, DROPPED_ARCHIVE + '\n' + DROP_SIGNATURE)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.invocations(), 2, 'the wrapper must retry exactly once')
        self.assertIn('failed again on attempt 2 of 2', result.stderr)

    def test_failures_without_dropped_archives_never_retry(self):
        # Data-driven: (exit code, failure body) pairs that must fail immediately.
        cases = {
            'wrong exit code with the full signature': (1, DROPPED_ARCHIVE + '\n' + DROP_SIGNATURE),
            'acquisition code without the summary signature': (100, DROPPED_ARCHIVE),
        }
        for label, attempt in cases.items():
            with self.subTest(label):
                result = self.run_wrapper([attempt])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.invocations(), 1, 'only a code-100 dropped-archive failure may retry')
                self.assertIn('no dropped archives', result.stderr)
            self.counter.unlink()
            self.plan.unlink()

    def test_unnamed_summary_signature_still_retries_once(self):
        result = self.run_wrapper([(100, DROP_SIGNATURE), (0, '')])
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(self.invocations(), 2)
        self.assertIn('attempt 2 of 2', result.stderr)

    def test_missing_command_is_rejected_without_running(self):
        result = subprocess.run(['bash', str(COMMAND)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 64)
        self.assertIn('Expected the package-acquisition command', result.stderr)


if __name__ == '__main__':
    unittest.main()
