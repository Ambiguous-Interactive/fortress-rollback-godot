"""Value: the weekly drift report lands on exactly one issue per source or fails loudly.

The reporter must deduplicate by reading issues (not the lagging search API),
skip repeated observations of an identical state, reopen a closed stream
instead of splitting it, fail closed on duplicate carriers or any tooling
error, and never write pins.json — so a scheduled M2 run can only ever report.
"""
import hashlib
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import drift_report

OLD_SHA = 'a' * 40
NEW_SHA = 'b' * 40
NEWER_SHA = 'c' * 40
REPOSITORY = 'https://github.com/example/fortress'

OLD_FILES = {'src/session.rs': 'pub fn step() -> u32 { 7 }\n', 'docs/guide.md': '# Guide\n'}
NEW_FILES = {'src/session.rs': 'pub fn step() -> u32 { 11 }\n', 'docs/guide.md': '# Guide\n'}
NEWER_FILES = {'src/session.rs': 'pub fn step() -> u32 { 12 }\n', 'docs/guide.md': '# Guide\n'}


@contextmanager
def make_tree(files):
    root = tempfile.TemporaryDirectory()
    try:
        base = Path(root.name)
        for name, text in files.items():
            target = base / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        yield base
    finally:
        root.cleanup()


def make_archive(files, root, destination):
    """One tar.gz whose every member lives under `root`, like a codeload archive."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(destination, 'w:gz') as tar:
        for name, text in files.items():
            info = tarfile.TarInfo(f'{root}/{name}')
            payload = text.encode('utf-8')
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))
    return destination


class FakeIssues:
    def __init__(self, carriers=()):
        self.issues = {}
        self.comments = {}
        self._next = 1
        for state, body in carriers:
            self.create_issue('Upstream drift report: fortress', body)
            self.issues[self._next - 1]['state'] = state

    def list_issues(self):
        return [{'number': number, 'state': issue['state'], 'body': issue['body']}
                for number, issue in sorted(self.issues.items())]

    def create_issue(self, title, body):
        number = self._next
        self._next += 1
        self.issues[number] = {'number': number, 'title': title, 'body': body, 'state': 'open'}
        self.comments[number] = []
        return number

    def update_issue(self, number, body=None, state=None):
        if body is not None:
            self.issues[number]['body'] = body
        if state is not None:
            self.issues[number]['state'] = state

    def list_comments(self, number):
        return [dict(comment) for comment in self.comments[number]]

    def add_comment(self, number, body):
        self.comments[number].append({'body': body})


class DriftReportTests(unittest.TestCase):
    def setUp(self):
        self._root = tempfile.TemporaryDirectory()
        base = Path(self._root.name)
        self.cache = base / 'cache'
        self.output = base / 'output'
        (self.cache / 'downloads').mkdir(parents=True)
        self.reviewed_archive = make_archive(OLD_FILES, f'fortress-{OLD_SHA}',
                                             self.cache / 'downloads' / f'{OLD_SHA}.tar.gz')
        self.digest = hashlib.sha256(self.reviewed_archive.read_bytes()).hexdigest()
        self.pins = base / 'pins.json'
        self.pins.write_text(json.dumps({
            'schema_version': 1,
            'artifacts': {},
            'sources': {'fortress': {
                'revision': OLD_SHA,
                'repository': REPOSITORY,
                'root': f'fortress-{OLD_SHA}',
                'archive': {'url': f'{REPOSITORY}/tar.gz/{OLD_SHA}', 'digest': self.digest,
                            'algorithm': 'sha256'},
            }},
        }), encoding='utf-8')
        self.candidate = {}

    def tearDown(self):
        self._root.cleanup()

    def prepare_candidate(self, revision, files):
        self.candidate[revision] = make_archive(files, f'fortress-{revision}',
                                                Path(self._root.name) / f'candidate-{revision}.tar.gz')

    def run_report(self, latest, issues=None, resolve=None, override=True, extra=()):
        fake = issues if issues is not None else FakeIssues()

        def fake_download(entry, revision, destination_dir):
            return self.candidate[revision]

        argv = ['--pins', str(self.pins), '--cache', str(self.cache), '--output', str(self.output),
                '--repo', 'example/fortress']
        if override:
            argv += ['--latest', f'fortress={latest}']
        argv += list(extra)
        with patch.object(drift_report, 'GhIssueClient', lambda repo: fake), \
             patch.object(drift_report, 'download_archive', fake_download), \
             patch.object(drift_report, 'resolve_latest', resolve or (lambda entry: latest)):
            code = drift_report.main_with_args(argv)
        return code, fake

    def test_latest_equal_to_the_reviewed_pin_is_a_noop(self):
        code, fake = self.run_report(OLD_SHA)
        self.assertEqual(code, 0)
        self.assertEqual(fake.issues, {})

    def test_drift_creates_one_carrier_with_a_digested_comment(self):
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        code, fake = self.run_report(NEW_SHA)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.issues), 1)
        number, issue = next(iter(fake.issues.items()))
        self.assertIn(f'<!-- {drift_report.MARKER_PREFIX}:fortress -->', issue['body'])
        self.assertIn(NEW_SHA, issue['body'])
        self.assertEqual(len(fake.comments[number]), 1)
        comment = fake.comments[number][0]['body']
        report_digest = json.loads((self.output / 'fortress.json').read_text(encoding='utf-8'))['report_digest']
        self.assertIn(f'report-digest: `{report_digest}`', comment)
        self.assertIn('drift: 1 changed', comment)
        self.assertIn('`src/session.rs`', comment)
        self.assertNotIn('docs/guide.md', comment)

    def test_repeated_observation_of_the_same_state_is_noise_free(self):
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        code, fake = self.run_report(NEW_SHA)
        number = next(iter(fake.issues))
        self.assertEqual(len(fake.comments[number]), 1)
        code, fake = self.run_report(NEW_SHA, issues=fake)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.issues), 1)
        self.assertEqual(len(fake.comments[number]), 1)

    def test_the_digest_skip_gate_is_load_bearing(self):
        # Mutant control: without the recorded-digest check the same weekly
        # state would be commented again on every scheduled run.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        code, fake = self.run_report(NEW_SHA)
        number = next(iter(fake.issues))
        with patch.object(drift_report, 'comment_digest', lambda body: None):
            self.run_report(NEW_SHA, issues=fake)
        self.assertEqual(len(fake.comments[number]), 2)

    def test_a_new_observation_comments_the_same_issue(self):
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        code, fake = self.run_report(NEW_SHA)
        number = next(iter(fake.issues))
        self.prepare_candidate(NEWER_SHA, NEWER_FILES)
        code, fake = self.run_report(NEWER_SHA, issues=fake)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.issues), 1)
        self.assertEqual(len(fake.comments[number]), 2)
        self.assertIn(NEWER_SHA, fake.issues[number]['body'])

    def test_a_closed_carrier_is_reopened_not_duplicated(self):
        marker = f'<!-- {drift_report.MARKER_PREFIX}:fortress -->'
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        closed = FakeIssues(carriers=[('closed', f'{marker}\nstale state\n')])
        code, fake = self.run_report(NEW_SHA, issues=closed)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.issues), 1)
        number = next(iter(fake.issues))
        self.assertEqual(fake.issues[number]['state'], 'open')
        self.assertIn(NEW_SHA, fake.issues[number]['body'])
        self.assertEqual(len(fake.comments[number]), 1)

    def test_duplicate_carriers_fail_closed_without_writes(self):
        marker = f'<!-- {drift_report.MARKER_PREFIX}:fortress -->'
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        split = FakeIssues(carriers=[('open', f'{marker}\n'), ('open', f'{marker}\n')])
        code, fake = self.run_report(NEW_SHA, issues=split)
        self.assertEqual(code, 1)
        for issue in fake.issues.values():
            self.assertEqual(len(fake.comments[issue['number']]), 0)
        self.assertFalse((self.output / 'fortress.json').exists())

    def test_resolver_failure_reports_a_tooling_error(self):
        def broken(entry):
            raise drift_report.ToolingError('cannot resolve: rate limited')

        code, fake = self.run_report(NEW_SHA, resolve=broken, override=False)
        self.assertEqual(code, 1)
        self.assertEqual(fake.issues, {})

    def test_candidate_root_mismatch_fails_closed_before_any_write(self):
        wrong_root = make_archive(NEW_FILES, f'other-{NEW_SHA}',
                                  Path(self._root.name) / f'candidate-{NEW_SHA}.tar.gz')
        self.candidate[NEW_SHA] = wrong_root
        code, fake = self.run_report(NEW_SHA)
        self.assertEqual(code, 1)
        self.assertEqual(fake.issues, {})
        self.assertFalse((self.output / 'fortress.json').exists())

    def test_malformed_or_unknown_inputs_are_refused(self):
        with self.assertRaises(drift_report.ToolingError):
            self.run_report('not-a-sha')
        with self.assertRaises(drift_report.ToolingError):
            self.run_report(NEW_SHA, extra=['--latest', 'sdk=' + NEW_SHA])
        with self.assertRaises(drift_report.ToolingError):
            self.run_report(NEW_SHA, extra=['--source', 'sdk'])

    def test_summary_records_results_and_failures(self):
        summary = Path(self._root.name) / 'summary.md'
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        code, _ = self.run_report(NEW_SHA, extra=['--summary', str(summary)])
        self.assertEqual(code, 0)
        self.assertIn('- fortress: created at `' + NEW_SHA + '`', summary.read_text(encoding='utf-8'))
        summary.write_text('', encoding='utf-8')

        def broken(entry):
            raise drift_report.ToolingError('rate limited')

        code, _ = self.run_report(NEW_SHA, resolve=broken, override=False, extra=['--summary', str(summary)])
        self.assertEqual(code, 1)
        self.assertIn('### Failures', summary.read_text(encoding='utf-8'))

    def test_pins_and_cache_stay_untouched_by_a_reporting_run(self):
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        before = self.pins.read_bytes(), sorted(
            path.name for path in (self.cache).rglob('*') if path.is_file())
        self.run_report(NEW_SHA)
        after = self.pins.read_bytes(), sorted(
            path.name for path in (self.cache).rglob('*') if path.is_file())
        self.assertEqual(before, after)


class GhIssueClientTests(unittest.TestCase):
    def run_client(self, argv_responses, call):
        """Drive one client method against scripted `gh api` responses."""
        calls = []

        def fake_run(command, capture_output, encoding, timeout, check):
            calls.append(command)
            stdout, code = argv_responses[len(calls) - 1]
            return subprocess.CompletedProcess(command, code, stdout, 'boom')

        client = drift_report.GhIssueClient('example/fortress')
        with patch.object(drift_report.subprocess, 'run', fake_run):
            result = call(client)
        return result, calls

    def test_list_issues_flattens_slurped_pages_and_filters_pull_requests(self):
        pages = json.dumps([
            [{'number': 1, 'state': 'open', 'body': 'issue', 'pull_request': {'x': 1}},
             {'number': 2, 'state': 'closed', 'body': 'carrier'}],
            [{'number': 3, 'state': 'open', 'body': ''}],
        ])
        result, calls = self.run_client([(pages, 0)],
                                        lambda client: client.list_issues())
        self.assertEqual(result, [{'number': 2, 'state': 'closed', 'body': 'carrier'},
                                  {'number': 3, 'state': 'open', 'body': ''}])
        self.assertIn('--paginate', calls[0])
        self.assertIn('--slurp', calls[0])
        self.assertIn('repos/example/fortress/issues?state=all&per_page=100', calls[0])

    def test_create_update_and_comment_construct_post_fields(self):
        created = json.dumps({'number': 7})

        def exercise(client):
            number = client.create_issue('Upstream drift report: fortress', 'body text')
            client.update_issue(7, body='new body')
            client.update_issue(7, state='open')
            client.add_comment(7, 'observation')
            client.list_comments(7)
            return number

        result, calls = self.run_client([(created, 0), ('{}', 0), ('{}', 0), ('{}', 0), ('[]', 0)], exercise)
        self.assertEqual(result, 7)
        self.assertEqual(calls[1], ['gh', 'api', '-X', 'PATCH', 'repos/example/fortress/issues/7',
                                    '-f', 'body=new body'])
        self.assertEqual(calls[2], ['gh', 'api', '-X', 'PATCH', 'repos/example/fortress/issues/7',
                                    '-f', 'state=open'])
        self.assertIn('repos/example/fortress/issues/7/comments', calls[3])
        self.assertIn('-f', calls[3])
        self.assertIn('body=observation', calls[3])

    def test_a_failed_gh_call_raises_a_named_tooling_error(self):
        with self.assertRaises(drift_report.ToolingError) as caught:
            self.run_client([('', 4)], lambda client: client.list_issues())
        self.assertIn('boom', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
