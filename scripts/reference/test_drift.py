"""Value: upstream drift is classified conservatively and never silently passes.

The classifier must label every synthetic change shape issue #51 lists, route
unmatched shapes to review, and fail closed on broken inputs instead of
reporting no drift.
"""
import json
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

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


if __name__ == '__main__':
    unittest.main()
