"""Self-test: pruning must remove scratch and never remove evidence.

The pruner deletes files, so its safety properties are the whole point of
the tool. These tests pin them:

* a path named by a tracked file is never pruned, whatever its age;
* a cited directory protects itself but not its children;
* the pinned reference toolchain is never pruned; only run outputs are;
* an archive is pruned only when its extracted sibling already exists;
* scratch entries that are recent, in use, or runtime-owned are kept;
* the newest app-server release survives; superseded ones do not;
* a dry run is the default.

A final guardrail test fails if any repository script copies the whole
working tree, which is what turned one scratch copy into 634 GB.
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import prune_caches
import scratch_workspace

REPO = prune_caches.ROOT


def age(path: Path, days: float) -> None:
    """Backdate a path so the retention rule treats it as old."""
    stamp = time.time() - days * 86400
    os.utime(path, (stamp, stamp))


class CitedPathTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ.get('TMPDIR', '/tmp')) / 'frg-prune-cited'
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / '.cache' / 'reference' / 'results').mkdir(parents=True, exist_ok=True)
        (self.root / 'doc.md').write_text(
            'see .cache/reference/results/keep.json and .cache/reference/results/pair-{a,b}/out.json\n', encoding='utf-8')

    def test_citation_expands_braces_and_names_files(self):
        cited = prune_caches.cited_paths(self.root)
        self.assertIn(self.root / '.cache' / 'reference' / 'results' / 'keep.json', cited)
        self.assertIn(self.root / '.cache' / 'reference' / 'results' / 'pair-a' / 'out.json', cited)
        self.assertIn(self.root / '.cache' / 'reference' / 'results' / 'pair-b' / 'out.json', cited)

    def test_cited_directory_does_not_freeze_its_children(self):
        (self.root / '.cache' / 'reference' / 'results' / 'generic').mkdir(parents=True, exist_ok=True)
        (self.root / 'doc.md').write_text('all of .cache/reference/results/ is uploaded\n', encoding='utf-8')
        protected = prune_caches.protection_set(prune_caches.cited_paths(self.root))
        self.assertTrue(prune_caches.is_protected(self.root / '.cache' / 'reference' / 'results', protected))
        self.assertFalse(prune_caches.is_protected(self.root / '.cache' / 'reference' / 'results' / 'generic', protected))

    def test_cited_child_protects_its_ancestors(self):
        protected = prune_caches.protection_set(prune_caches.cited_paths(self.root))
        self.assertTrue(prune_caches.is_protected(self.root / '.cache' / 'reference' / 'results' / 'pair-a', protected))


class ProtectionSetTest(unittest.TestCase):
    """A citation protects the path it names and the paths above it.

    The expansion replaces a pairwise comparison of every candidate against
    every citation, which cost 96 of the 99 seconds the first full report
    took. These cases pin the semantics the expansion has to preserve.
    """

    ROOT = Path('/workspace/project')

    def test_named_path_and_its_ancestors_are_protected(self):
        cited = {self.ROOT / '.cache' / 'reference' / 'results' / 'run' / 'receipt.json'}
        protected = prune_caches.protection_set(cited)
        for path in (self.ROOT / '.cache' / 'reference' / 'results' / 'run' / 'receipt.json',
                     self.ROOT / '.cache' / 'reference' / 'results' / 'run',
                     self.ROOT / '.cache' / 'reference' / 'results',
                     self.ROOT / '.cache' / 'reference',
                     self.ROOT / '.cache',
                     self.ROOT):
            self.assertTrue(prune_caches.is_protected(path, protected), path)

    def test_children_of_a_cited_path_stay_prunable(self):
        cited = {self.ROOT / '.cache' / 'reference' / 'results'}
        protected = prune_caches.protection_set(cited)
        self.assertFalse(prune_caches.is_protected(self.ROOT / '.cache' / 'reference' / 'results' / 'run', protected))

    def test_uncited_siblings_stay_prunable(self):
        cited = {self.ROOT / '.cache' / 'reference' / 'results' / 'run' / 'receipt.json'}
        protected = prune_caches.protection_set(cited)
        self.assertFalse(prune_caches.is_protected(self.ROOT / '.cache' / 'reference' / 'results' / 'other', protected))

    def test_empty_citations_protect_nothing(self):
        self.assertEqual(prune_caches.protection_set(set()), set())


class WorkspacePlanTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ.get('TMPDIR', '/tmp')) / 'frg-prune-workspace'
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True, exist_ok=True)
        self.cache = self.root / '.cache'
        self.results = self.cache / 'reference' / 'results'
        self.results.mkdir(parents=True, exist_ok=True)
        (self.cache / 'tests').mkdir(parents=True, exist_ok=True)
        (self.cache / 'session-001').mkdir(parents=True, exist_ok=True)
        (self.cache / 'reference' / 'editors').mkdir(parents=True, exist_ok=True)
        self.cited = prune_caches.protection_set({self.results / 'keep.json'})

    def test_cited_result_is_never_planned(self):
        keep = self.results / 'keep.json'
        keep.write_text('{}', encoding='utf-8')
        age(keep, 365)
        plans = prune_caches.plan_workspace(self.root, 7.0, self.cited)
        self.assertNotIn(keep, [plan.path for plan in plans])

    def test_uncited_result_older_than_ttl_is_planned(self):
        stale = self.results / 'stale'
        stale.mkdir(parents=True, exist_ok=True)
        age(stale, 30)
        plans = prune_caches.plan_workspace(self.root, 7.0, self.cited)
        self.assertIn(stale, [plan.path for plan in plans])

    def test_recent_result_is_kept(self):
        fresh = self.results / 'fresh'
        fresh.mkdir(parents=True, exist_ok=True)
        plans = prune_caches.plan_workspace(self.root, 7.0, self.cited)
        self.assertNotIn(fresh, [plan.path for plan in plans])

    def test_session_scratch_is_prunable(self):
        stale = self.cache / 'session-001'
        age(stale, 30)
        plans = prune_caches.plan_workspace(self.root, 7.0, self.cited)
        self.assertIn(stale, [plan.path for plan in plans])

    def test_pinned_reference_toolchain_is_never_planned(self):
        editor = self.cache / 'reference' / 'editors' / '4.7.2'
        editor.mkdir(parents=True, exist_ok=True)
        age(editor, 365)
        plans = prune_caches.plan_workspace(self.root, 0.0, self.cited)
        self.assertNotIn(editor, [plan.path for plan in plans])

    def test_redundant_archive_is_planned_only_with_extracted_sibling(self):
        """A redundant archive is dropped; a cited archive is not."""
        archive = self.results / 'run-1.zip'
        archive.write_bytes(b'zip')
        self.assertEqual(prune_caches.redundant_archives(self.cache, set()), [])
        (self.results / 'run-1').mkdir(parents=True, exist_ok=True)
        planned = prune_caches.redundant_archives(self.cache, set())
        self.assertIn(archive, [plan.path for plan in planned])
        cited = prune_caches.redundant_archives(self.cache, prune_caches.protection_set({archive}))
        self.assertEqual(cited, [])


class ScratchCopyPlanTest(unittest.TestCase):
    """The approved scratch location must be prunable, but not while it is in use."""

    def setUp(self):
        self.root = Path(os.environ.get('TMPDIR', '/tmp')) / 'frg-prune-copies'
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True, exist_ok=True)
        self.cache = self.root / '.cache'
        self.scratch = self.cache / 'scratch'
        self.scratch.mkdir(parents=True, exist_ok=True)

    def test_an_old_uncited_scratch_copy_is_planned(self):
        stale = self.scratch / 'probe-01'
        stale.mkdir(parents=True, exist_ok=True)
        age(stale, 30)
        plans = prune_caches.plan_workspace(self.root, 7.0, set())
        self.assertIn(stale, [plan.path for plan in plans])

    def test_a_recent_scratch_copy_is_kept(self):
        fresh = self.scratch / 'probe-02'
        fresh.mkdir(parents=True, exist_ok=True)
        plans = prune_caches.plan_workspace(self.root, 7.0, set())
        self.assertNotIn(fresh, [plan.path for plan in plans])

    def test_a_scratch_copy_in_use_is_kept(self):
        busy = self.scratch / 'probe-03'
        busy.mkdir(parents=True, exist_ok=True)
        age(busy, 30)
        with unittest.mock.patch.object(prune_caches, 'in_use', return_value=True):
            plans = prune_caches.plan_workspace(self.root, 7.0, set())
        self.assertNotIn(busy, [plan.path for plan in plans])


class InUseTest(unittest.TestCase):
    """A live session must never be deleted from under itself."""

    def setUp(self):
        self.root = Path(os.environ.get('TMPDIR', '/tmp')) / 'frg-prune-inuse'
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True, exist_ok=True)
        self.target = self.root / 'copy'
        self.target.mkdir(parents=True, exist_ok=True)

    def test_the_current_directory_inside_the_candidate_counts_as_in_use(self):
        inside = self.target / 'inner'
        inside.mkdir(parents=True, exist_ok=True)
        script = ('import os, sys\n'
                  'os.chdir(sys.argv[1])\n'
                  'print(os.getcwd(), flush=True)\n'
                  'sys.stdin.read()\n')
        process = subprocess.Popen([sys.executable, '-c', script, str(inside)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        try:
            process.stdout.readline()
            self.assertTrue(prune_caches.in_use(self.target))
        finally:
            process.stdin.close()
            process.stdout.close()
            process.wait(timeout=10)

    def test_an_open_handle_on_the_candidate_counts_as_in_use(self):
        handle = (self.target / 'held.txt').open('w')
        try:
            self.assertTrue(prune_caches.in_use(self.target))
        finally:
            handle.close()

    def test_an_unrelated_path_is_not_in_use(self):
        self.assertFalse(prune_caches.in_use(self.root / 'absent'))


class ScratchPlanTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ.get('TMPDIR', '/tmp')) / 'frg-prune-scratch'
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True, exist_ok=True)

    def test_runtime_directories_are_never_planned(self):
        for name in ('arg0-linux', 'codex-daemon-1000', 'claude-1000'):
            path = self.root / name
            path.mkdir(parents=True, exist_ok=True)
            age(path, 365)
        plans = prune_caches.plan_scratch(self.root, 1.0)
        self.assertEqual([plan.path for plan in plans], [])

    def test_recent_entry_is_kept(self):
        path = self.root / 'fresh'
        path.mkdir(parents=True, exist_ok=True)
        plans = prune_caches.plan_scratch(self.root, 24.0)
        self.assertNotIn(path, [plan.path for plan in plans])

    def test_stale_entry_is_planned(self):
        path = self.root / 'stale'
        path.mkdir(parents=True, exist_ok=True)
        age(path, 3)
        plans = prune_caches.plan_scratch(self.root, 1.0)
        self.assertIn(path, [plan.path for plan in plans])


class ContainerPlanTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(os.environ.get('TMPDIR', '/tmp')) / 'frg-prune-home'
        shutil.rmtree(self.home, ignore_errors=True)
        self.home.mkdir(parents=True, exist_ok=True)

    def test_superseded_release_is_planned_and_newest_is_kept(self):
        releases = self.home / '.codex' / 'packages' / 'app-server-daemon' / 'releases'
        (releases / '0.1.0').mkdir(parents=True, exist_ok=True)
        (releases / '0.2.0').mkdir(parents=True, exist_ok=True)
        plans = prune_caches.plan_container(self.home)
        planned = [plan.path for plan in plans]
        self.assertIn(releases / '0.1.0', planned)
        self.assertNotIn(releases / '0.2.0', planned)


class MeasurementTest(unittest.TestCase):
    # Value: protects=du results need no second traversal; fails_when=eager defaults walk again; why_new=no measurement coverage; seam=du process
    def test_du_sizes_skip_fallback_and_only_missing_roots_are_walked(self):
        roots = [Path('/cache/a'), Path('/cache/b'), Path('/cache/c')]
        result = subprocess.CompletedProcess([], 1, '12\t/cache/a\ninvalid\t/cache/b\n34\t/cache/c\n', '')
        with unittest.mock.patch.object(prune_caches.subprocess, 'run', return_value=result), \
                unittest.mock.patch.object(prune_caches, 'tree_bytes', return_value=56) as fallback:
            sizes = prune_caches.measure(roots)
        self.assertEqual(sizes, {roots[0]: 12, roots[1]: 56, roots[2]: 34})
        self.assertEqual([call.args[0] for call in fallback.call_args_list], [roots[1]])
        with unittest.mock.patch.object(prune_caches.subprocess, 'run', side_effect=FileNotFoundError), \
                unittest.mock.patch.object(prune_caches, 'tree_bytes', return_value=78) as fallback:
            self.assertEqual(prune_caches.measure(roots), dict.fromkeys(roots, 78))
        self.assertEqual([call.args[0] for call in fallback.call_args_list], roots)

    # Value: protects=wide inventory work scales with depth; fails_when=pairwise ancestor scan returns; why_new=small safety fixtures hide cost; seam=path comparison count
    def test_wide_inventory_preserves_roots_with_bounded_comparisons(self):
        class CountedPath(type(Path())):
            comparisons = 0

            def __eq__(self, other):
                type(self).comparisons += 1
                return super().__eq__(other)

            __hash__ = type(Path()).__hash__

        roots = [CountedPath('/cache') / f'run-{index}' for index in range(400)]
        candidates = [path / 'nested' / 'receipt' for path in reversed(roots)] + roots + [roots[0], CountedPath('/cache/run-0-other')]
        expected = set(roots + [CountedPath('/cache/run-0-other')])
        payload = ''.join(f'1\t{path}\n' for path in expected)
        result = subprocess.CompletedProcess([], 0, payload, '')
        with unittest.mock.patch.object(prune_caches.subprocess, 'run', return_value=result) as du:
            sizes = prune_caches.measure(candidates)
        comparisons = CountedPath.comparisons
        self.assertEqual(set(sizes), expected)
        actual = {Path(name) for name in du.call_args.kwargs['input'].split('\0') if name}
        self.assertEqual(actual, expected)
        self.assertLess(comparisons, len(candidates) * 20, 'sibling candidates must not be compared pairwise')


class DiagnosticTest(unittest.TestCase):
    # Value: protects=JSON and local citations; fails_when=diagnostics pollute output or skip notes; why_new=no large CLI fixture; seam=real CLI
    def test_diagnostics_keep_json_and_citations_in_large_local_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            results = root / '.cache' / 'reference' / 'results'
            results.mkdir(parents=True)
            notes = root / 'progress'
            notes.mkdir()
            for index in range(240):
                kept = results / f'run-{index}'
                kept.mkdir()
                (kept / 'receipt.json').write_text('{}')
                extra = kept / 'uncited.bin'
                extra.write_bytes(b'old')
                age(extra, 30)
                (notes / f'note-{index}.md').write_text(f'.cache/reference/results/run-{index}/receipt.json')
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'receipt.json').write_text('{}')
            (outside / 'uncited.bin').write_bytes(b'keep outside the cache')
            age(outside / 'uncited.bin', 30)
            (results / 'linked').symlink_to(outside, target_is_directory=True)
            age(results / 'linked', 30)
            lease = results / 'lease'
            lease.mkdir()
            (lease / 'host.lock').write_text('')
            age(lease / 'host.lock', 30)
            age(lease, 30)
            (root / 'tracked.md').write_text('.cache/reference/results/tracked.json .cache/reference/results/linked/receipt.json')
            subprocess.run(['git', '-C', str(root), 'add', 'tracked.md'], check=True)
            kept_file = results / 'tracked.json'
            kept_file.write_text('{}')
            age(kept_file, 30)
            command = [sys.executable, str(REPO / 'scripts' / 'prune_caches.py'), '--root', str(root), '--scope', 'workspace', '--json']
            environment = dict(os.environ, FORTRESS_HOST_CAPACITY_DIR=str(lease))
            control = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30, env=environment)
            observed = subprocess.run(command + ['--diagnostics'], capture_output=True, text=True, check=True, timeout=30, env=environment)
            self.assertEqual(json.loads(control.stdout), json.loads(observed.stdout))
            summary = json.loads(observed.stdout)
            self.assertEqual({entry['path'] for entry in summary['entries']}, {str(results / f'run-{index}' / 'uncited.bin') for index in range(240)})
            events = [json.loads(line.removeprefix('prune: ')) for line in observed.stderr.splitlines()]
            self.assertEqual(events[0]['event'], 'started')
            completed = {event['phase']: event for event in events if event['event'] == 'completed'}
            self.assertEqual(completed['citations']['read_files'], 241)
            self.assertGreater(completed['citations']['read_bytes'], 0)
            self.assertEqual(completed['measure']['candidate_paths'], 240)
            self.assertTrue(kept_file.is_file(), 'diagnostic dry run must preserve cited evidence')
            self.assertTrue((results / 'linked').is_symlink())
            self.assertTrue((lease / 'host.lock').is_file())

    # Value: protects=start emitted before slow discovery; fails_when=reports buffered until done; why_new=CLI output alone proves only final report; seam=main discovery boundary
    def test_phase_start_is_emitted_before_discovery_and_errors_stop_reporting(self):
        output, errors = io.StringIO(), io.StringIO()
        def discovery(*_):
            self.assertIn('"phase": "inventory", "event": "started"', errors.getvalue())
            self.assertEqual(output.getvalue(), '')
            raise OSError('inventory unavailable')
        with unittest.mock.patch.object(sys, 'argv', ['prune_caches.py', '--diagnostics', '--json']), \
                unittest.mock.patch.object(prune_caches, 'tracked_files', side_effect=discovery), redirect_stdout(output), redirect_stderr(errors):
            with self.assertRaisesRegex(OSError, 'inventory unavailable'):
                prune_caches.main()
        self.assertIn('"event": "failed"', errors.getvalue())


class DryRunTest(unittest.TestCase):
    def test_default_invocation_deletes_nothing(self):
        root = Path(os.environ.get('TMPDIR', '/tmp')) / 'frg-prune-dry'
        root.mkdir(parents=True, exist_ok=True)
        (root / '.cache' / 'results').mkdir(parents=True, exist_ok=True)
        stale = root / '.cache' / 'results' / 'stale'
        stale.mkdir(parents=True, exist_ok=True)
        age(stale, 30)
        result = subprocess.run([sys.executable, str(REPO / 'scripts' / 'prune_caches.py'),
                                 '--root', str(root), '--scope', 'workspace'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(stale.is_dir(), 'a dry run must not delete anything')


class WholeTreeCopyGuardTest(unittest.TestCase):
    """No repository script may copy the working tree wholesale.

    A bare `shutil.copytree` of the repository also copies the gitignored
    `.cache/` tree. That single line produced 634 GB of stale scratch.
    """

    ROOT_TOKENS = {'ROOT', 'REPO_ROOT', 'REPO', 'repo_root', 'root', 'SOURCE', 'source_root'}
    SKIP_DIRS = {'.git', '.cache', 'node_modules', '__pycache__'}

    def test_no_script_copies_the_repository_root(self):
        offenders = []
        for path in sorted((REPO / 'scripts').rglob('*.py')):
            text = path.read_text(encoding='utf-8', errors='ignore')
            for number, line in enumerate(text.splitlines(), 1):
                if 'copytree' not in line:
                    continue
                source = line.split('copytree', 1)[1].lstrip(' (').split(',')[0].strip()
                if source in self.ROOT_TOKENS or source in ("'.'", '"."', 'Path.cwd()'):
                    offenders.append(f'{path.relative_to(REPO)}:{number}: {line.strip()}')
                elif source.startswith('Path(__file__)') and 'parents[' in source and '/' not in source:
                    offenders.append(f'{path.relative_to(REPO)}:{number}: {line.strip()}')
        self.assertEqual(offenders, [], f'unbounded whole-tree copies: {offenders}')

    def test_no_source_tree_contains_a_copied_cache(self):
        """The symptom guard: a copied workspace carries a nested cache tree."""
        offenders = []
        for root, dirs, _ in os.walk(REPO):
            relative = Path(root).relative_to(REPO)
            if relative.parts and relative.parts[0] in self.SKIP_DIRS:
                dirs[:] = []
                continue
            if len(relative.parts) >= 2 and relative.parts[0] == '.claude' and relative.parts[1] == 'worktrees':
                dirs[:] = []
                continue
            for name in list(dirs):
                if name != '.cache':
                    continue
                nested = Path(root) / name
                if relative.parts and ((nested / 'reference').is_dir() or (nested / 'tests').is_dir()):
                    offenders.append(str(nested.relative_to(REPO)))
        self.assertEqual(offenders, [], f'copied cache trees found: {offenders}')

    def test_scratch_helper_excludes_the_cache_tree(self):
        self.assertIn('.cache', scratch_workspace.excluded_names())
        self.assertIn('.git', scratch_workspace.excluded_names())

    def test_scratch_helper_excludes_agent_worktrees(self):
        self.assertIn('worktrees', scratch_workspace.excluded_names())

    def test_scratch_copy_is_small_and_has_no_cache(self):
        """A scratch copy must not carry the cache tree it is meant to isolate."""
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'copy'
            scratch_workspace.copy_workspace(destination)
            self.assertTrue((destination / 'scripts').is_dir())
            self.assertFalse((destination / '.cache').exists())
            self.assertFalse((destination / '.git').exists())
            self.assertFalse((destination / '.godot').exists())


if __name__ == '__main__':
    unittest.main()
