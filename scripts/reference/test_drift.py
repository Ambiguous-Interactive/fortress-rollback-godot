"""Value: upstream drift is classified conservatively and never silently passes.

The classifier must label every synthetic change shape issue #51 lists, route
unmatched shapes to review, and fail closed on broken inputs instead of
reporting no drift.
"""
import hashlib
import json
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import drift


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


class DriftClassificationTests(unittest.TestCase):
    def classify_pair(self, old_files, new_files):
        with make_tree(old_files) as old_base, make_tree(new_files) as new_base:
            return drift.build_report('fortress', old_base, new_base)

    def test_no_changes_reports_no_drift(self):
        files = {'src/session.rs': 'pub fn step() {}\n'}
        report = self.classify_pair(files, files)
        self.assertFalse(report['drift'])
        self.assertEqual(report['requires_review'], [])

    # Data-driven over issue #51's synthetic change shapes. The review gate is
    # conservative: every non-noise change gates, whatever its category, and
    # noise is only blanks, whole-line comments and per-line whitespace in
    # source order — never string contents or line order.
    def test_synthetic_change_shapes(self):
        production = 'pub fn step() -> u32 { 7 }\n'
        cases = [
            # (name, old, new, category, signal or None, requires_review)
            ('whitespace_comment', production, production.replace('{ 7 }', '{  7 }  // tuned\n'),
             'production_source', 'semantic_lines', True),
            ('comments_only', production, '// guide\n' + production,
             'production_source', 'whitespace_or_comment_only', False),
            ('constant', 'pub const LIMIT: u32 = 8;\n', 'pub const LIMIT: u32 = 9;\n',
             'production_source', 'constants_or_statics', True),
            ('attribute', '#[inline]\npub fn step() {}\n', '#[inline(always)]\npub fn step() {}\n',
             'production_source', 'attributes_or_macros', True),
            ('cfg_gate', '#[cfg(target_os = "linux")]\npub fn step() {}\n',
             '#[cfg(unix)]\npub fn step() {}\n', 'production_source', 'cfg_gate_touched', True),
            ('semantic', production, production.replace('7', '11'),
             'production_source', 'semantic_lines', True),
            ('string_url', 'let url = "https://a";\n', 'let url = "https://b";\n',
             'production_source', 'semantic_lines', True),
            ('swapped_lines', 'v.clear();\nv.push(1);\n', 'v.push(1);\nv.clear();\n',
             'production_source', 'semantic_lines', True),
            ('build_script', 'fn main() {}\n', 'fn main() { println!("cargo:rerun-if-changed=x"); }\n',
             'build_logic', 'semantic_lines', True),
            ('dependency_manifest', '[dependencies]\nlog = "0.4"\n', '[dependencies]\nlog = "0.5"\n',
             'dependencies', 'semantic_lines', True),
            ('test_only', '#[test]\nfn a() {}\n', '#[test]\nfn a() {}\n#[test]\nfn b() {}\n',
             'tests_models_fixtures', 'semantic_lines', True),
            ('model_spec', '{"steps": 1}\n', '{"steps": 2}\n',
             'tests_models_fixtures', 'semantic_lines', True),
            ('docs_only', '# Guide\n', '# Guide v2\n', 'documentation', 'semantic_lines', True),
        ]
        for name, old_text, new_text, category, signal, review in cases:
            with self.subTest(shape=name):
                path = {'whitespace_comment': 'src/queue.rs', 'comments_only': 'src/session.rs',
                        'constant': 'src/constants.rs', 'attribute': 'src/hot.rs',
                        'cfg_gate': 'src/platform.rs', 'semantic': 'src/game.rs',
                        'string_url': 'src/endpoint.rs', 'swapped_lines': 'src/order.rs',
                        'build_script': 'build.rs', 'dependency_manifest': 'Cargo.toml',
                        'test_only': 'tests/sim.rs', 'model_spec': 'specs/model.json',
                        'docs_only': 'docs/guide.md'}[name]
                report = self.classify_pair({path: old_text}, {path: new_text})
                self.assertTrue(report['drift'], name)
                self.assertEqual(report['files_changed'], 1, name)
                record = report['records'][0]
                self.assertEqual(record['category'], category, name)
                self.assertIn(signal, record['signals'], name)
                self.assertEqual(record['requires_review'], review, name)
                self.assertEqual(report['requires_review'], ([path] if review else []), name)

    def test_unmatched_path_fails_closed_as_review(self):
        report = self.classify_pair({'weird.bin': 'a'}, {'weird.bin': 'b'})
        record = report['records'][0]
        self.assertEqual(record['category'], 'requires_review')
        self.assertTrue(record['requires_review'])
        self.assertEqual(report['requires_review'], ['weird.bin'])

    def test_indentation_significant_formats_never_classify_as_noise(self):
        # Issue #382 review: a YAML re-indent moves mappings between nesting
        # levels, so the whitespace-only noise label must not exempt it from
        # review. The same re-indent in an indentation-insensitive format
        # keeps its historical noise classification.
        cases = [
            ('src/config.yml', 'outer:\n  enabled: true\n', 'outer:\nenabled: true\n', True),
            ('src/config.yaml', 'outer:\n  enabled: true\n', 'outer:\nenabled: true\n', True),
            ('Makefile', 'all:\n\techo hi\n', 'all:\necho hi\n', True),
            ('src/aligned.rs', 'pub fn a() {\n\tstep();\n}\n', 'pub fn a() {\nstep();\n}\n', False),
        ]
        for path, old_text, new_text, review in cases:
            with self.subTest(path=path):
                report = self.classify_pair({path: old_text}, {path: new_text})
                record = report['records'][0]
                self.assertIn('whitespace_or_comment_only', record['signals'])
                self.assertEqual(record['requires_review'], review)
                self.assertEqual(report['requires_review'], ([path] if review else []))

    def test_non_text_bytes_gate_instead_of_diffing_to_nothing(self):
        # Issue #382 review: `FF` and `FE` both decode to U+FFFD with
        # errors='replace', so a real content change could diff to nothing
        # and classify as no drift. Undecodable content gates instead.
        with make_tree({'fixtures/packet.bin': 'placeholder'}) as old_base, \
                make_tree({'fixtures/packet.bin': 'placeholder'}) as new_base:
            (old_base / 'fixtures' / 'packet.bin').write_bytes(b'\xff\xfe\x01\n')
            (new_base / 'fixtures' / 'packet.bin').write_bytes(b'\xfe\xfe\x01\n')
            report = drift.build_report('fortress', old_base, new_base)
            record = report['records'][0]
            self.assertEqual(record['signals'], ['non_text_bytes'])
            self.assertTrue(record['requires_review'])
            self.assertEqual(report['requires_review'], ['fixtures/packet.bin'])

    def test_addition_deletion_and_rename(self):
        old = {'src/kept.rs': 'pub fn a() {}\n', 'src/gone.rs': 'pub fn b() {}\n',
               'src/old_name.rs': 'pub fn stable() {}\n'}
        new = {'src/kept.rs': 'pub fn a() {}\n', 'src/fresh.rs': 'pub fn c() {}\n',
               'src/new_name.rs': 'pub fn stable() {}\n'}
        report = self.classify_pair(old, new)
        self.assertEqual(report['files_changed'], 0)
        self.assertEqual(report['files_added'], 1)
        self.assertEqual(report['files_deleted'], 1)
        self.assertEqual(report['files_renamed'], 1)
        added = [record for record in report['records'] if record['path'] == 'src/fresh.rs']
        self.assertEqual(added[0]['kind'], 'added')
        deleted = [record for record in report['records'] if record['path'] == 'src/gone.rs']
        self.assertEqual(deleted[0]['kind'], 'deleted')
        # A pure rename: same bytes under a new name is one rename, not churn.
        report = self.classify_pair({'src/old_name.rs': 'pub fn stable() {}\n'},
                                    {'src/new_name.rs': 'pub fn stable() {}\n'})
        self.assertEqual(report['files_renamed'], 1)
        self.assertEqual(report['files_added'], 0)
        self.assertEqual(report['files_deleted'], 0)
        renamed = report['records'][0]
        self.assertEqual(renamed['kind'], 'renamed')
        self.assertEqual(renamed['rename_from'], 'src/old_name.rs')
        self.assertEqual(renamed['category'], 'production_source')
        # A rename moves the ledger key even when the bytes match, so the
        # record gates review unconditionally.
        self.assertTrue(renamed['requires_review'])
        self.assertEqual(report['requires_review'], ['src/new_name.rs'])

    def test_duplicate_rename_candidates_are_consumed_once(self):
        report = self.classify_pair({'src/a.rs': 'pub fn stable() {}\n'},
                                    {'src/b.rs': 'pub fn stable() {}\n',
                                     'src/c.rs': 'pub fn stable() {}\n'})
        self.assertEqual(report['files_renamed'], 1)
        self.assertEqual(report['files_added'], 1)
        added = [record for record in report['records'] if record['kind'] == 'added']
        self.assertEqual([record['path'] for record in added], ['src/c.rs'])
        renamed = [record for record in report['records'] if record['kind'] == 'renamed'][0]
        self.assertEqual(renamed['rename_from'], 'src/a.rs')
        self.assertEqual(renamed['path'], 'src/b.rs')

    def test_ledger_mapping_and_unmapped_paths(self):
        ledger = {'decisions': {'fortress:src/session.rs': {'status': 'covered',
                                                            'applicability': 'applicable',
                                                            'port_test_ids': ['t1']}}}
        with make_tree({'src/session.rs': 'a\n', 'src/other.rs': 'a\n'}) as old_base, \
             make_tree({'src/session.rs': 'b\n', 'src/other.rs': 'b\n'}) as new_base:
            report = drift.build_report('fortress', old_base, new_base, ledger=ledger)
        by_path = {record['path']: record for record in report['records']}
        self.assertEqual(by_path['src/session.rs']['ledger']['status'], 'covered')
        self.assertEqual(by_path['src/other.rs']['ledger'], 'unmapped')
        self.assertEqual(report['ledger_unmapped'], ['src/other.rs'])

    def test_mixed_change_reports_the_stronger_gate(self):
        # A constant edit plus a semantic edit on neighboring lines: the diff
        # contains semantic lines, so the record needs review.
        old = 'pub const LIMIT: u32 = 8;\npub fn step() -> u32 { LIMIT }\n'
        new = 'pub const LIMIT: u32 = 9;\npub fn step() -> u32 { LIMIT + 1 }\n'
        report = self.classify_pair({'src/queue.rs': old}, {'src/queue.rs': new})
        record = report['records'][0]
        self.assertEqual(record['signals'], ['semantic_lines'])
        self.assertTrue(record['requires_review'])


class DriftInputBoundTests(unittest.TestCase):
    def test_missing_tree_is_a_tooling_error(self):
        with make_tree({'src/a.rs': 'a\n'}) as base:
            with self.assertRaises(ValueError):
                drift.build_report('fortress', base / 'does-not-exist', base)

    def test_walk_bound_fails_closed(self):
        original = drift.MAX_FILES
        drift.MAX_FILES = 2
        try:
            with make_tree({'a.txt': 'a', 'b.txt': 'b', 'c.txt': 'c'}) as base:
                with self.assertRaises(ValueError):
                    drift.build_report('fortress', base, base)
        finally:
            drift.MAX_FILES = original

    def test_oversized_file_fails_closed_instead_of_no_drift(self):
        # Two different oversized files must be a tooling error, never "the
        # hashes are unavailable so nothing changed".
        original = drift.MAX_FILE_BYTES
        drift.MAX_FILE_BYTES = 8
        try:
            with make_tree({'src/huge.rs': 'pub fn a() {}\n'}) as old_base, \
                 make_tree({'src/huge.rs': 'pub fn b() {}\n'}) as new_base:
                with self.assertRaises(ValueError):
                    drift.build_report('fortress', old_base, new_base)
        finally:
            drift.MAX_FILE_BYTES = original

    def test_unreadable_file_is_a_tooling_error(self):
        with make_tree({'src/a.rs': 'a\n'}) as base:
            (base / 'src' / 'a.rs').chmod(0)
            try:
                with self.assertRaises(OSError):
                    drift.build_report('fortress', base, base)
            finally:
                (base / 'src' / 'a.rs').chmod(0o644)

    def test_unlistable_directory_is_a_tooling_error(self):
        # A directory whose listing fails must fail the whole comparison
        # (issue #382 review): os.walk's default silently skips it, so two
        # trees that differ only inside unlistable directories could compare
        # as equal and report no drift.
        with make_tree({'src/a.rs': 'a\n', 'src/deep/b.rs': 'b\n'}) as old_base, \
                make_tree({'src/a.rs': 'a\n', 'src/deep/b.rs': 'changed\n'}) as new_base:
            (old_base / 'src' / 'deep').chmod(0)
            try:
                with self.assertRaises(ValueError):
                    drift.build_report('fortress', old_base, new_base)
            finally:
                (old_base / 'src' / 'deep').chmod(0o755)

    def test_git_directory_is_ignored(self):
        with make_tree({'src/a.rs': 'a\n'}) as base:
            dot_git = base / '.git'
            dot_git.mkdir()
            (dot_git / 'HEAD').write_text('ref: refs/heads/main\n')
            report = drift.build_report('fortress', base, base)
            self.assertFalse(report['drift'])

    def test_main_reports_tooling_failure_without_no_drift(self):
        with tempfile.TemporaryDirectory() as folder:
            missing = str(Path(folder) / 'absent')
            exit_code = drift.main_with_args(['--source', 'fortress', '--old', missing, '--new', missing])
        self.assertEqual(exit_code, 1)


OLD_REVISION = 'a' * 40
NEW_REVISION = 'b' * 40


def make_archive(folder, name, root, files):
    """A deterministic-enough tar.gz candidate archive for the pin flow."""
    import tarfile
    archive = Path(folder) / name
    staged = Path(folder) / ('stage-' + name)
    for relative, text in files.items():
        target = staged / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    with tarfile.open(archive, 'w:gz') as tar:
        for path in sorted(staged.rglob('*')):
            if path.is_file():
                tar.add(path, arcname=str(Path(root) / path.relative_to(staged)))
    return archive


class DriftPinFlowTests(unittest.TestCase):
    """Value: the observed tree is bound to its claimed revision before any
    bookkeeping is recorded, an observation never advances the pin by itself,
    and a failed binding leaves pins.json byte-identical."""

    def corpus(self, folder, tree_files=None, archive_root='sdk-' + NEW_REVISION, archive_files=None):
        base = Path(folder)
        pins = base / 'pins.json'
        old_files = {'src/lib.rs': 'pub fn step() -> u32 { 1 }\n', 'Cargo.toml': '[package]\nname = "sdk"\n'}
        unchanged = {'src/lib.rs': 'pub fn step() -> u32 { 2 }\n', 'Cargo.toml': '[package]\nname = "sdk"\n'}
        new_files = tree_files if tree_files is not None else unchanged
        # The reviewed archive binds --old: tarball the old tree under its
        # pinned root, seed the offline fetch cache with it and record the
        # digest in the manifest exactly like a real pin would.
        reviewed = make_archive(base, 'reviewed.tar.gz', 'sdk-' + OLD_REVISION, old_files)
        downloads = base / 'cache' / 'downloads'
        downloads.mkdir(parents=True, exist_ok=True)
        (downloads / (OLD_REVISION + '.tar.gz')).write_bytes(reviewed.read_bytes())
        pins.write_text(json.dumps({
            'schema_version': 1,
            'sources': {'sdk': {
                'repository': 'https://github.com/example/sdk',
                'revision': OLD_REVISION,
                'archive': {'url': f'https://codeload.github.com/example/sdk/tar.gz/{OLD_REVISION}',
                            'digest': hashlib.sha256(reviewed.read_bytes()).hexdigest(),
                            'algorithm': 'sha256'},
                'root': 'sdk-' + OLD_REVISION,
            }},
            'artifacts': {'sample.bin': {'url': 'https://example.com/sample.bin',
                                         'digest': '3' * 64, 'algorithm': 'sha256'}},
        }), encoding='utf-8')
        old_tree = base / 'old-tree'; old_tree.mkdir()
        new_tree = base / 'new-tree'; new_tree.mkdir()
        for name, text in old_files.items():
            (old_tree / name).parent.mkdir(parents=True, exist_ok=True); (old_tree / name).write_text(text)
        for name, text in new_files.items():
            (new_tree / name).parent.mkdir(parents=True, exist_ok=True); (new_tree / name).write_text(text)
        archive = make_archive(base, 'candidate.tar.gz', archive_root,
                               archive_files if archive_files is not None else unchanged)
        return pins, old_tree, new_tree, archive

    def run_flow(self, folder, advance=False, source='sdk', revision=NEW_REVISION, **corpus):
        pins, old_tree, new_tree, archive = self.corpus(folder, **corpus)
        report = Path(folder) / 'report.json'
        argv = ['--source', source, '--old', str(old_tree), '--new', str(new_tree),
                '--pins', str(pins), '--new-revision', revision, '--archive', str(archive),
                '--report', str(report)]
        if advance:
            argv.append('--advance')
        # The pin flow reads the reviewed archive from the fetch cache the
        # corpus seeds; point the tool's cache root at it.
        with patch.object(drift, 'CACHE', Path(folder) / 'cache'):
            code = drift.main_with_args(argv)
        return code, pins, report

    def test_observation_records_bookkeeping_without_advancing_the_pin(self):
        import hashlib
        from datetime import date
        with tempfile.TemporaryDirectory() as folder:
            code, pins, report = self.run_flow(folder)
            self.assertEqual(code, 0)
            data = json.loads(pins.read_text())
            entry = data['sources']['sdk']
            self.assertEqual(entry['revision'], OLD_REVISION)
            review = entry['review']
            self.assertEqual(review['observed_revision'], NEW_REVISION)
            self.assertEqual(review['observed_on'], date.today().isoformat())
            self.assertNotIn('advanced_from', review)
            self.assertEqual(review['report_sha256'], hashlib.sha256(report.read_bytes()).hexdigest())
            self.assertEqual(review['archive_sha256'],
                             hashlib.sha256((Path(folder) / 'candidate.tar.gz').read_bytes()).hexdigest())
            written = json.loads(report.read_text())
            self.assertEqual(written['candidate_revision'], NEW_REVISION)
            self.assertEqual(written['candidate_url'], f'https://github.com/example/sdk/tree/{NEW_REVISION}')
            self.assertEqual(written['records'][0]['url'], f'https://github.com/example/sdk/blob/{NEW_REVISION}/src/lib.rs')
            self.assertEqual(written['requires_review'], ['src/lib.rs'])

    def test_advance_rewrites_the_pin_and_the_manifest_stays_loadable(self):
        from datetime import date
        import fetch
        with tempfile.TemporaryDirectory() as folder:
            code, pins, report = self.run_flow(folder, advance=True)
            self.assertEqual(code, 0)
            data = json.loads(pins.read_text())
            entry = data['sources']['sdk']
            self.assertEqual(entry['revision'], NEW_REVISION)
            self.assertEqual(entry['archive']['url'],
                             f'https://codeload.github.com/example/sdk/tar.gz/{NEW_REVISION}')
            self.assertEqual(entry['root'], 'sdk-' + NEW_REVISION)
            self.assertEqual(entry['review']['advanced_from'], OLD_REVISION)
            self.assertEqual(entry['review']['advanced_on'], date.today().isoformat())
            # The rewritten manifest must load and validate exactly like a
            # hand-reviewed pin bump would.
            fetch.load_manifest(pins)

    # Data-driven over the fail-closed binding controls: every refused flow must
    # leave pins.json byte-identical and write no report at all.
    def test_broken_candidates_refuse_without_bookkeeping(self):
        import hashlib
        cases = [
            ('tree_exceeds_archive', {'tree_files': {'src/lib.rs': 'pub fn step() -> u32 { 2 }\n',
                                                     'Cargo.toml': '[package]\n', 'src/extra.rs': 'x\n'}}),
            ('archive_root_drift', {'archive_root': 'sdk-' + 'c' * 40}),
            ('malformed_revision', {'revision': 'not-a-sha'}),
            ('unknown_source', {'source': 'server'}),
            ('content_mismatch', {'archive_files': {'src/lib.rs': 'pub fn step() -> u32 { 3 }\n',
                                                    'Cargo.toml': '[package]\nname = "sdk"\n'}}),
        ]
        for name, options in cases:
            with self.subTest(case=name):
                with tempfile.TemporaryDirectory() as folder:
                    code, pins, report = self.run_flow(folder, advance=True, **options)
                    self.assertEqual(code, 1, name)
                    self.assertFalse(report.exists(), name)
                    self.assertNotIn('review', json.loads(pins.read_text())['sources']['sdk'], name)

    def test_oversized_compared_tree_is_a_tooling_error_before_any_write(self):
        # The comparison bounds run before any binding or bookkeeping, so an
        # oversized compared tree refuses with pins.json byte-identical and no
        # report on disk.
        original = drift.MAX_FILE_BYTES
        drift.MAX_FILE_BYTES = 8
        try:
            with tempfile.TemporaryDirectory() as folder:
                files = {'src/lib.rs': 'pub fn step() -> u32 { 2 }  /* long enough */\n',
                         'Cargo.toml': '[package]\nname = "sdk"\n'}
                code, pins, report = self.run_flow(folder, tree_files=files)
                self.assertEqual(code, 1)
                self.assertFalse(report.exists())
                self.assertNotIn('review', json.loads(pins.read_text())['sources']['sdk'])
        finally:
            drift.MAX_FILE_BYTES = original

    def test_incomplete_flag_sets_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            for argv in (['--source', 'sdk', '--old', str(base), '--new', str(base), '--pins', str(base / 'p.json')],
                         ['--source', 'sdk', '--old', str(base), '--new', str(base), '--new-revision', NEW_REVISION,
                          '--archive', str(base), '--advance'],
                         ['--source', 'sdk', '--old', str(base), '--new', str(base),
                          '--report', str(base / 'r.json'), '--advance']):
                self.assertEqual(drift.main_with_args(argv), 1, argv)

    def test_advance_creates_a_missing_cache_root(self):
        # A fresh checkout has no .cache/reference yet; the extraction staging
        # area creates its root instead of refusing the whole pin flow. The
        # reviewed archive still comes from the seeded fetch cache.
        with tempfile.TemporaryDirectory() as folder:
            pins, old_tree, new_tree, archive = self.corpus(folder)
            cache = Path(folder) / 'fresh' / 'reference'
            (cache / 'downloads').mkdir(parents=True)
            seed = Path(folder) / 'cache' / 'downloads' / (OLD_REVISION + '.tar.gz')
            (cache / 'downloads' / (OLD_REVISION + '.tar.gz')).write_bytes(seed.read_bytes())
            report = Path(folder) / 'report.json'
            argv = ['--source', 'sdk', '--old', str(old_tree), '--new', str(new_tree),
                    '--pins', str(pins), '--new-revision', NEW_REVISION, '--archive', str(archive),
                    '--report', str(report), '--advance']
            with patch.object(drift, 'CACHE', cache):
                self.assertEqual(drift.main_with_args(argv), 0)
            self.assertTrue((Path(folder) / 'report.json').exists())

    def test_advance_refuses_a_wrong_old_tree(self):
        # The compared old tree must byte-match the reviewed pin's cached
        # archive: a second copy of the candidate (or any other tree) fails
        # closed before the comparison runs, so the report's reviewed_revision
        # always describes the tree actually compared.
        with tempfile.TemporaryDirectory() as folder:
            pins, old_tree, new_tree, archive = self.corpus(folder)
            report = Path(folder) / 'report.json'
            argv = ['--source', 'sdk', '--old', str(new_tree), '--new', str(new_tree),
                    '--pins', str(pins), '--new-revision', NEW_REVISION, '--archive', str(archive),
                    '--report', str(report), '--advance']
            with patch.object(drift, 'CACHE', Path(folder) / 'cache'):
                self.assertEqual(drift.main_with_args(argv), 1)
            entry = json.loads(pins.read_text(encoding='utf-8'))['sources']['sdk']
            self.assertEqual(entry['revision'], OLD_REVISION)
            self.assertNotIn('review', entry)
            self.assertFalse(report.exists())

    def test_advance_refuses_when_the_report_cannot_land(self):
        # A failed report write must leave the pin untouched: never an advanced
        # revision whose recorded report digest names bytes that never existed.
        with tempfile.TemporaryDirectory() as folder:
            pins, old_tree, new_tree, archive = self.corpus(folder)
            report = Path(folder) / 'missing-dir' / 'report.json'
            argv = ['--source', 'sdk', '--old', str(old_tree), '--new', str(new_tree),
                    '--pins', str(pins), '--new-revision', NEW_REVISION, '--archive', str(archive),
                    '--report', str(report), '--advance']
            self.assertEqual(drift.main_with_args(argv), 1)
            entry = json.loads(pins.read_text(encoding='utf-8'))['sources']['sdk']
            self.assertEqual(entry['revision'], OLD_REVISION)
            self.assertNotIn('review', entry)
            self.assertFalse(report.exists())
            self.assertEqual(list(Path(folder).iterdir()),
                             [p for p in Path(folder).iterdir() if p.name not in ('report.json.tmp',)])

    def test_advance_refuses_a_directory_report_destination(self):
        # The staging write succeeds beside a directory destination and the
        # final replace then fails — the refusal must fire before the pins
        # advance, not after.
        with tempfile.TemporaryDirectory() as folder:
            pins, old_tree, new_tree, archive = self.corpus(folder)
            report = Path(folder) / 'report-dir'; report.mkdir()
            argv = ['--source', 'sdk', '--old', str(old_tree), '--new', str(new_tree),
                    '--pins', str(pins), '--new-revision', NEW_REVISION, '--archive', str(archive),
                    '--report', str(report), '--advance']
            self.assertEqual(drift.main_with_args(argv), 1)
            entry = json.loads(pins.read_text(encoding='utf-8'))['sources']['sdk']
            self.assertEqual(entry['revision'], OLD_REVISION)
            self.assertNotIn('review', entry)
            self.assertEqual(list(report.iterdir()), [], 'no staged report litter')

    def test_advance_refuses_identical_trees(self):
        # The review evidence is the A-to-B drift itself: a B-versus-B
        # submission produces a clean report whatever the trees are and can
        # never justify rewriting the pin.
        with tempfile.TemporaryDirectory() as folder:
            pins, old_tree, new_tree, archive = self.corpus(folder, tree_files={
                'src/lib.rs': 'pub fn step() -> u32 { 1 }\n', 'Cargo.toml': '[package]\nname = "sdk"\n'})
            report = Path(folder) / 'report.json'
            argv = ['--source', 'sdk', '--old', str(old_tree), '--new', str(new_tree),
                    '--pins', str(pins), '--new-revision', NEW_REVISION, '--archive', str(archive),
                    '--report', str(report), '--advance']
            self.assertEqual(drift.main_with_args(argv), 1)
            entry = json.loads(pins.read_text(encoding='utf-8'))['sources']['sdk']
            self.assertEqual(entry['revision'], OLD_REVISION)
            self.assertNotIn('review', entry)
            self.assertFalse(report.exists())

    def test_plain_report_failure_is_a_named_tooling_error(self):
        with tempfile.TemporaryDirectory() as folder:
            pins, old_tree, new_tree, archive = self.corpus(folder)
            report = Path(folder) / 'missing-dir' / 'report.json'
            argv = ['--source', 'sdk', '--old', str(old_tree), '--new', str(new_tree),
                    '--report', str(report)]
            self.assertEqual(drift.main_with_args(argv), 1)
            self.assertFalse(report.exists())

    def test_malformed_bookkeeping_fails_manifest_load(self):
        import fetch
        with tempfile.TemporaryDirectory() as folder:
            pins = Path(folder) / 'pins.json'
            pins.write_text(json.dumps({
                'schema_version': 1,
                'sources': {'sdk': {
                    'repository': 'https://github.com/example/sdk', 'revision': OLD_REVISION,
                    'archive': {'url': f'https://codeload.github.com/example/sdk/tar.gz/{OLD_REVISION}',
                                'digest': '1' * 64, 'algorithm': 'sha256'},
                    'root': 'sdk-' + OLD_REVISION,
                    'review': {'observed_revision': NEW_REVISION, 'observed_on': '2026-11-16',
                               'report_sha256': 'short', 'archive_sha256': '2' * 64},
                }},
                'artifacts': {},
            }), encoding='utf-8')
            with self.assertRaises(ValueError):
                fetch.load_manifest(pins)


if __name__ == '__main__':
    unittest.main()
