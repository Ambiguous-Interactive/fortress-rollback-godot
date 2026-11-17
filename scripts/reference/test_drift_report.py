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
    def __init__(self, carriers=(), identity='reporter'):
        self.identity = identity
        self.issues = {}
        self.comments = {}
        self._next = 1
        for state, body in carriers:
            self.create_issue('Upstream drift report: fortress', body)
            self.issues[self._next - 1]['state'] = state

    def current_login(self):
        return self.identity

    def list_issues(self):
        return [{'number': number, 'state': issue['state'], 'title': issue['title'],
                 'body': issue['body']}
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

    def add_comment(self, number, body, author=None):
        self.comments[number].append({'author': author or self.identity, 'body': body})


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

    def prepare_candidate(self, revision, files, stem='fortress'):
        self.candidate[revision] = make_archive(files, f'{stem}-{revision}',
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

    def test_a_digest_known_closed_carrier_stays_quiet(self):
        # A maintainer who closes the stream after reading the observation must
        # not be fought by the next scheduled run: the recorded digest means
        # no reopen, no body rewrite and no comment.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        _, fake = self.run_report(NEW_SHA)
        number = next(iter(fake.issues))
        fake.update_issue(number, state='closed')
        code, fake = self.run_report(NEW_SHA, issues=fake)
        self.assertEqual(code, 0)
        self.assertEqual(fake.issues[number]['state'], 'closed')
        self.assertEqual(len(fake.comments[number]), 1)

    def test_a_foreign_digest_comment_never_suppresses_the_observation(self):
        # Digests are read only from tool-authored (marker-carried) comments:
        # anyone can compute the identity digest from public inputs, so a
        # foreign comment carrying the GENUINE digest must not make the run
        # skip its observation. The genuine digest is what makes this pin
        # real: a filter regression would suppress and this test would fail.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        _, first = self.run_report(NEW_SHA)
        digest = json.loads((self.output / 'fortress.json').read_text(encoding='utf-8'))['report_digest']
        hijacked = FakeIssues(carriers=[('open', f'<!-- {drift_report.MARKER_PREFIX}:fortress -->\nstale\n')])
        number = next(iter(hijacked.issues))
        # The exact line a well-meaning observer pasting the digest produces:
        # the content-based parser matches it, so only the marker filter can
        # keep the observation landing.
        hijacked.add_comment(number, f'Already recorded elsewhere.\nreport-digest: `{digest}`\n',
                             author='someone')
        code, fake = self.run_report(NEW_SHA, issues=hijacked)
        self.assertEqual(code, 0)
        comments = fake.comments[number]
        self.assertEqual(len(comments), 2)
        self.assertIn(f'<!-- {drift_report.REPORT_PREFIX}:fortress -->', comments[-1]['body'])

    def test_a_copied_marker_from_a_foreign_author_never_suppresses_the_observation(self):
        # The marker line is public too, so authorship is the gate: a foreign
        # author pasting BOTH the marker and the genuine digest must not be
        # accepted as completion evidence.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        _, first = self.run_report(NEW_SHA)
        digest = json.loads((self.output / 'fortress.json').read_text(encoding='utf-8'))['report_digest']
        mimic = FakeIssues(carriers=[('open', f'<!-- {drift_report.MARKER_PREFIX}:fortress -->\nstale\n')])
        number = next(iter(mimic.issues))
        mimic.add_comment(number, f'<!-- {drift_report.REPORT_PREFIX}:fortress -->\n'
                                  f'report-digest: `{digest}`\n', author='mimic')
        code, fake = self.run_report(NEW_SHA, issues=mimic)
        self.assertEqual(code, 0)
        comments = fake.comments[number]
        self.assertEqual(len(comments), 2)
        self.assertEqual(comments[-1]['author'], 'reporter')

    def test_the_scheduled_identity_settles_into_a_quiet_cadence(self):
        # The identity that authored the recorded digest is the one the rule
        # trusts: a same-identity rerun of the same state stays quiet even
        # though foreign comments carry the same digest.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        _, fake = self.run_report(NEW_SHA)
        number = next(iter(fake.issues))
        fake.add_comment(number, f'report-digest: `{json.loads((self.output / "fortress.json").read_text())["report_digest"]}`\n',
                         author='someone')
        code, _ = self.run_report(NEW_SHA, issues=fake)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.comments[number]), 2)

    def test_an_explicit_reporting_identity_never_resolves_and_owns_its_digests(self):
        # The scheduled workflow's Actions installation token cannot resolve
        # `gh api user` (HTTP 403), so it names its reporting identity
        # explicitly; resolution must not run and digest trust follows the
        # named identity exactly as if it had been resolved. The fake models
        # the reality that the token IS the bot: its comments are authored by
        # the override identity while `current_login` would fail if called.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        strict = FakeIssues(identity='github-actions[bot]')
        strict.current_login = self.fail  # any call is a regression
        override = ['--reporting-identity', 'github-actions[bot]']
        code, fake = self.run_report(NEW_SHA, issues=strict, extra=override)
        self.assertEqual(code, 0)
        number = next(iter(fake.issues))
        self.assertEqual(fake.comments[number][0]['author'], 'github-actions[bot]')
        code, fake = self.run_report(NEW_SHA, issues=strict, extra=override)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.comments[number]), 1, 'the same identity observing the same state stays quiet')

    def test_affected_port_tests_render_into_the_comment(self):
        # M2 asks the report to name affected tests: ledger-mapped port-test
        # identities render into the observation comment.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        ledger = Path(self._root.name) / 'ledger.json'
        ledger.write_text(json.dumps({'decisions': {'fortress:src/session.rs': {
            'status': 'covered', 'applicability': 'applicable',
            'port_test_ids': ['tests/unit/test_session.gd::rollback']}}}), encoding='utf-8')
        code, fake = self.run_report(NEW_SHA, extra=['--ledger', str(ledger)])
        self.assertEqual(code, 0)
        number = next(iter(fake.issues))
        comment = fake.comments[number][0]['body']
        self.assertIn('Affected port tests: `src/session.rs`: `tests/unit/test_session.gd::rollback`.',
                      comment)
        self.assertIn('Requires review: `src/session.rs`.', comment)

    def test_a_near_miss_stream_issue_is_named(self):
        # An issue carrying only the marker or only the title is not adopted;
        # the run names it so the fork stays visible instead of silent.
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        near_miss = FakeIssues()
        near_miss.create_issue('Drift chatter', f'<!-- {drift_report.MARKER_PREFIX}:fortress -->\n')
        code, fake = self.run_report(NEW_SHA, issues=near_miss)
        self.assertEqual(code, 0)
        adopted = [issue for issue in fake.issues.values()
                   if issue['title'] == 'Upstream drift report: fortress']
        self.assertEqual(len(adopted), 1)

    def test_a_phantom_marker_without_the_title_is_not_adopted(self):
        # Adoption needs the marker AND the tool's title, so an issue that
        # merely embeds the marker cannot hijack or fork the stream.
        phantom = FakeIssues()
        phantom.create_issue('Random discussion', f'<!-- {drift_report.MARKER_PREFIX}:fortress -->\n')
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        code, fake = self.run_report(NEW_SHA, issues=phantom)
        self.assertEqual(code, 0)
        adopted = [issue for issue in fake.issues.values()
                   if issue['title'] == 'Upstream drift report: fortress']
        self.assertEqual(len(adopted), 1)
        number = adopted[0]['number']
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

    def test_a_missing_reviewed_baseline_fails_closed(self):
        # Red-green for the spec's "missing baseline": a cold or broken fetch
        # cache is a per-source tooling error, never a no-drift report.
        def cold_cache(pin, name, offline=False, cache=None):
            raise OSError(f'offline cache miss: {name}')

        self.prepare_candidate(NEW_SHA, NEW_FILES)
        with patch.object(drift_report.fetch, 'fetch', cold_cache):
            code, fake = self.run_report(NEW_SHA)
        self.assertEqual(code, 1)
        self.assertEqual(fake.issues, {})
        self.assertFalse((self.output / 'fortress.json').exists())

    def test_a_classification_failure_is_a_per_source_tooling_error(self):
        # Red-green for the spec's "oracle failure": a classifier that refuses
        # the input (for example the tree walk bound) fails that source only.
        def refusing_build_report(*args, **kwargs):
            raise ValueError('tree exceeds the file bound')

        self.prepare_candidate(NEW_SHA, NEW_FILES)
        with patch.object(drift_report.drift, 'build_report', refusing_build_report):
            code, fake = self.run_report(NEW_SHA)
        self.assertEqual(code, 1)
        self.assertEqual(fake.issues, {})
        self.assertFalse((self.output / 'fortress.json').exists())

    def test_an_issue_write_failure_recovers_on_the_next_run(self):
        # Red-green for the spec's "uncertain response": a comment write that
        # dies after GitHub accepted the issue creation is adopted on the next
        # run instead of duplicating the stream.
        self.prepare_candidate(NEW_SHA, NEW_FILES)

        class FlakyComment(FakeIssues):
            def __init__(self):
                super().__init__()
                self.failed_once = False

            def add_comment(self, number, body):
                if not self.failed_once:
                    self.failed_once = True
                    raise drift_report.ToolingError('comment write lost: gateway timeout')
                super().add_comment(number, body)

        flaky = FlakyComment()
        code, fake = self.run_report(NEW_SHA, issues=flaky)
        self.assertEqual(code, 1)
        number = next(iter(fake.issues))
        self.assertEqual(len(fake.comments[number]), 0)
        code, fake = self.run_report(NEW_SHA, issues=fake)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.issues), 1)
        self.assertEqual(len(fake.comments[number]), 1)

    def test_an_empty_summary_argument_is_treated_as_absent(self):
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        code, _ = self.run_report(NEW_SHA, extra=['--summary', ''])
        self.assertEqual(code, 0)

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
        for empty in ('', '   '):
            with self.subTest(identity=empty):
                # An empty identity would own no comments, so every run would
                # re-observe: refuse it instead of silently degrading the
                # cadence (the symmetric guard to the `--summary ''` case).
                with self.assertRaises(drift_report.ToolingError):
                    self.run_report(NEW_SHA, extra=['--reporting-identity', empty])

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

    def test_a_resolver_timeout_does_not_block_the_remaining_sources(self):
        # The spec's exact timeout scenario: a timed-out first source fails
        # alone while the second source still reports (the adapters convert
        # TimeoutExpired; the per-source handler nets any SubprocessError).
        sdk_revision = 'd' * 40
        sdk_latest = 'e' * 40
        sdk_archive = make_archive({'src/a.rs': 'fn main() {}\n'}, f'sdk-{sdk_revision}',
                                   self.cache / 'downloads' / f'{sdk_revision}.tar.gz')
        sdk_digest = hashlib.sha256(sdk_archive.read_bytes()).hexdigest()
        data = json.loads(self.pins.read_text(encoding='utf-8'))
        data['sources']['sdk'] = {
            'revision': sdk_revision, 'repository': 'https://github.com/example/sdk',
            'root': f'sdk-{sdk_revision}',
            'archive': {'url': f'https://github.com/example/sdk/tar.gz/{sdk_revision}',
                        'digest': sdk_digest, 'algorithm': 'sha256'}}
        self.pins.write_text(json.dumps(data), encoding='utf-8')
        self.prepare_candidate(sdk_latest, {'src/a.rs': 'fn main() { 2 }\n'}, stem='sdk')
        import subprocess

        def timing_out_resolve(entry):
            if entry['root'].startswith('fortress-'):
                raise subprocess.TimeoutExpired(cmd='gh', timeout=120)
            return sdk_latest

        def download(entry, revision, destination_dir):
            return self.candidate[revision]

        fake = FakeIssues()
        argv = ['--pins', str(self.pins), '--cache', str(self.cache), '--output', str(self.output),
                '--repo', 'example/fortress']
        with patch.object(drift_report, 'GhIssueClient', lambda repo: fake), \
             patch.object(drift_report, 'download_archive', download), \
             patch.object(drift_report, 'resolve_latest', timing_out_resolve):
            code = drift_report.main_with_args(argv)
        self.assertEqual(code, 1)
        streams = sorted(issue['title'] for issue in fake.issues.values())
        self.assertEqual(streams, ['Upstream drift report: sdk'])

    def test_pins_and_cache_stay_untouched_by_a_reporting_run(self):
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        before = self.pins.read_bytes(), sorted(
            path.name for path in (self.cache).rglob('*') if path.is_file())
        self.run_report(NEW_SHA)
        after = self.pins.read_bytes(), sorted(
            path.name for path in (self.cache).rglob('*') if path.is_file())
        self.assertEqual(before, after)

    def test_partial_failure_still_reports_the_remaining_sources(self):
        # Two sources: the first fails on a corrupt candidate archive, the
        # second still reports, and the run exits 1 naming only the failure.
        sdk_revision = 'd' * 40
        sdk_latest = 'e' * 40
        self.prepare_candidate(NEW_SHA, NEW_FILES)
        sdk_archive = make_archive({'src/a.rs': 'fn main() {}\n'}, f'sdk-{sdk_revision}',
                                   self.cache / 'downloads' / f'{sdk_revision}.tar.gz')
        sdk_digest = hashlib.sha256(sdk_archive.read_bytes()).hexdigest()
        data = json.loads(self.pins.read_text(encoding='utf-8'))
        data['sources']['sdk'] = {
            'revision': sdk_revision, 'repository': 'https://github.com/example/sdk',
            'root': f'sdk-{sdk_revision}',
            'archive': {'url': f'https://github.com/example/sdk/tar.gz/{sdk_revision}',
                        'digest': sdk_digest, 'algorithm': 'sha256'}}
        self.pins.write_text(json.dumps(data), encoding='utf-8')
        self.prepare_candidate(sdk_revision, {'src/a.rs': 'fn main() { 1 }\n'}, stem='sdk')
        self.prepare_candidate(sdk_latest, {'src/a.rs': 'fn main() { 2 }\n'}, stem='sdk')
        broken = Path(self._root.name) / 'broken.tar.gz'
        broken.write_bytes(b'not a gzip file')
        real_download = self.candidate

        def download(entry, revision, destination_dir):
            if revision == NEW_SHA:
                return broken
            return real_download[revision]

        def resolve(entry):
            return sdk_latest if entry['root'].startswith('sdk-') else NEW_SHA

        fake = FakeIssues()
        argv = ['--pins', str(self.pins), '--cache', str(self.cache), '--output', str(self.output),
                '--repo', 'example/fortress']
        with patch.object(drift_report, 'GhIssueClient', lambda repo: fake), \
             patch.object(drift_report, 'download_archive', download), \
             patch.object(drift_report, 'resolve_latest', resolve):
            code = drift_report.main_with_args(argv)
        self.assertEqual(code, 1)
        # sdk still created its stream; fortress has none.
        streams = sorted(issue['title'] for issue in fake.issues.values())
        self.assertEqual(streams, ['Upstream drift report: sdk'])


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
        self.assertEqual(result, [{'number': 2, 'state': 'closed', 'title': '', 'body': 'carrier'},
                                  {'number': 3, 'state': 'open', 'title': '', 'body': ''}])
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

    def test_a_timed_out_gh_call_is_a_named_tooling_error(self):
        # subprocess.TimeoutExpired is not an OSError: the adapters convert it,
        # so a slow gh call fails its source instead of crashing the run.
        import subprocess

        def timeout_run(*args, **kwargs):
            raise subprocess.TimeoutExpired(cmd='gh', timeout=120)

        client = drift_report.GhIssueClient('example/fortress')
        with patch.object(drift_report.subprocess, 'run', timeout_run):
            with self.assertRaises(drift_report.ToolingError) as caught:
                client.list_issues()
        self.assertIn('timed out', str(caught.exception))

    def test_the_reporting_identity_is_resolved_and_validated(self):
        result, calls = self.run_client([('gh-bot\n', 0)], lambda client: client.current_login())
        self.assertEqual(result, 'gh-bot')
        self.assertIn('user', calls[0])

        import subprocess

        def timeout_run(*args, **kwargs):
            raise subprocess.TimeoutExpired(cmd='gh', timeout=120)

        client = drift_report.GhIssueClient('example/fortress')
        with patch.object(drift_report.subprocess, 'run', timeout_run):
            with self.assertRaises(drift_report.ToolingError) as caught:
                client.current_login()
        self.assertIn('timed out', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
