"""The oracle launchers must find a Godot executable the way the Make targets name it.

`Makefile` sets `GODOT ?= godot`, so the documented commands pass a bare
name. The launchers used to turn that name into a working-directory path,
so a pinned engine installed on `PATH` was never found. The failure also
came late: the Rust toolchain was installed and the oracle was built
before the engine was touched.

These tests cover the resolver and every launcher entry point:

* a bare name on `PATH`, a relative path and an absolute path resolve to
  the same executable bytes;
* a name that names nothing fails with a readable message;
* every launcher resolves the engine once, before it starts the
  expensive work, and uses that resolved path for the version probe, the
  execution, the digest and the receipt.
"""

import hashlib
import importlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'reference'))

from engine_path import resolve_engine

ORACLE = Path(__file__).resolve().parent

# Every launcher that takes `--godot`, with the receipt it writes, the
# calls that stand in for the expensive work, and the exact expressions
# that must use the resolved path.
LAUNCHERS = {
    'launch.py': ('receipt.json', ('sources',), ("'engine_path': str(engine)", "execute([str(engine), '--version']", 'digest(engine)')),
    'queue_launch.py': ('receipt.json', ('sources', 'observation_source'),
                        ("'engine_path': str(engine)", "execute([str(engine), '--version']", 'digest(engine)')),
    'replay_launch.py': ('replay.json', ('sources', 'verified_engine'),
                         ('engine_path=str(engine)', 'digest(engine) != engine_hash')),
    'handshake_launch.py': ('receipt.json', ('sources', 'ensure_jar'),
                            ("'engine_path': str(engine)", "execute([str(engine), '--version']", 'digest(engine)')),
    'p2p_launch.py': ('receipt.json', ('sources',),
                      ("'engine_path': str(engine)", "execute([str(engine), '--version']", 'executable_identity(engine)')),
}

RESOLVER = (
    'import sys;'
    'sys.path.insert(0, {reference!r});'
    'from engine_path import resolve_engine;'
    'print(resolve_engine(sys.argv[1]))'
)


class ReachedWork(Exception):
    """Raised in place of the toolchain install and the oracle build."""


def executable(path: Path) -> Path:
    """Write a runnable stand-in for the pinned engine."""
    path.write_text('#!/bin/sh\necho "4.7.2.stable.official"\n', encoding='utf-8')
    path.chmod(0o755)
    return path


def resolve_in_subprocess(candidate: str, environment=None, cwd=None) -> str:
    """Resolve a candidate in a fresh process and return its standard output."""
    result = subprocess.run([sys.executable, '-c', RESOLVER.format(reference=str(ORACLE.parent / 'reference')),
                             candidate], capture_output=True, text=True, env=environment, cwd=cwd)
    if result.returncode:
        raise AssertionError(result.stderr.strip() or 'resolver failed')
    return result.stdout.strip()


class ResolutionTest(unittest.TestCase):
    """The resolver's rule, exercised through real subprocesses."""

    def test_a_path_name_relative_path_and_absolute_path_name_the_same_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = executable(root / 'godot')
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get('PATH', ''))
            by_name = resolve_in_subprocess('godot', environment=environment)
            by_relative = resolve_in_subprocess('./godot', cwd=root)
            by_absolute = resolve_in_subprocess(str(engine))
            self.assertEqual(by_name, str(engine))
            self.assertEqual(by_relative, str(engine))
            self.assertEqual(by_absolute, str(engine))

    def test_a_relative_path_is_not_redirected_to_the_path(self):
        """`./godot` names the file in the working directory, not a name on PATH."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = executable(root / 'godot')
            other = Path(tempfile.mkdtemp())
            executable(other / 'godot')
            environment = dict(os.environ, PATH=str(other) + os.pathsep + os.environ.get('PATH', ''))
            self.assertEqual(resolve_in_subprocess('./godot', environment=environment, cwd=root), str(local))

    def test_the_resolved_executable_identifies_the_same_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = executable(root / 'godot')
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get('PATH', ''))
            by_name = Path(resolve_in_subprocess('godot', environment=environment))
            by_absolute = Path(resolve_in_subprocess(str(engine)))
            self.assertEqual(hashlib.sha256(by_name.read_bytes()).hexdigest(),
                             hashlib.sha256(by_absolute.read_bytes()).hexdigest())

    def test_a_name_that_names_nothing_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable(root / 'godot')
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get('PATH', ''))
            for candidate in ('godot-that-is-not-installed', 'missing/godot'):
                with self.subTest(candidate=candidate):
                    with self.assertRaises(ValueError) as error:
                        resolve_engine(candidate)
                    self.assertIn('godot executable not found', str(error.exception))

    def test_a_file_that_cannot_run_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            plain = Path(temporary) / 'godot'
            plain.write_text('not an executable', encoding='utf-8')
            with self.assertRaises(ValueError) as error:
                resolve_engine(plain)
            self.assertIn('not executable', str(error.exception))

    def test_a_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError) as error:
                resolve_engine(Path(temporary))
            self.assertIn('godot executable not found', str(error.exception))


class LauncherEntryPointTest(unittest.TestCase):
    """Every launcher resolves the engine before it starts the expensive work."""

    def launch(self, name, candidate):
        """Run one launcher up to the point where the expensive work starts.

        Returns the outcome, the files the launcher left behind and the
        error it raised, if any.
        """
        module = importlib.import_module(name[:-3])
        _, stand_ins, _ = LAUNCHERS[name]
        directory = Path(tempfile.mkdtemp())
        try:
            output = directory / 'out'
            argv = [name, '--godot', candidate, '--output', str(output)]
            patches = [patch.object(module, attribute, side_effect=ReachedWork(attribute))
                       for attribute in stand_ins]
            outcome = {'reached_work': False, 'error': None}
            with patch.object(sys, 'argv', argv):
                for stand_in in patches:
                    stand_in.start()
                try:
                    module.main()
                except ReachedWork:
                    outcome['reached_work'] = True
                except ValueError as error:
                    outcome['error'] = error
                finally:
                    for stand_in in patches:
                        stand_in.stop()
            outcome['files'] = sorted(path.name for path in output.iterdir()) if output.is_dir() else []
            return outcome
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_every_launcher_resolves_the_candidate_once_and_uses_that_path(self):
        """The launcher must resolve the raw name, not a path built from it."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = executable(root / 'godot')
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ.get('PATH', ''))
            for name in LAUNCHERS:
                with self.subTest(launcher=name), patch.dict(os.environ, environment, clear=True):
                    module = importlib.import_module(name[:-3])
                    seen = []

                    def spy(candidate, _seen=seen):
                        _seen.append(candidate)
                        return resolve_engine(candidate)

                    with patch.object(module, 'resolve_engine', side_effect=spy):
                        outcome = self.launch(name, 'godot')
                    self.assertEqual(seen, ['godot'], f'{name} did not resolve the candidate it was given')
                    self.assertIsNone(outcome['error'], f'{name} rejected a name from PATH: {outcome["error"]}')
                    self.assertTrue(outcome['reached_work'], f'{name} did not reach the work it starts')

    def test_every_launcher_rejects_a_name_that_names_nothing(self):
        for name, (receipt_name, _, _) in LAUNCHERS.items():
            with self.subTest(launcher=name):
                outcome = self.launch(name, 'godot-that-is-not-installed')
                self.assertIsNotNone(outcome['error'], f'{name} accepted an engine that does not exist')
                self.assertIn('godot executable not found', str(outcome['error']))
                self.assertNotIn(receipt_name, outcome['files'], 'a stale success receipt must not survive')
                self.assertEqual(outcome['files'], [], 'the engine must be resolved before the build')

    def test_a_missing_engine_fails_in_a_fresh_process_without_building_anything(self):
        for name, (receipt_name, _, _) in LAUNCHERS.items():
            with self.subTest(launcher=name), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'out'
                receipt = output / receipt_name
                receipt.parent.mkdir(parents=True, exist_ok=True)
                receipt.write_text('{"passed":true}')
                result = subprocess.run([sys.executable, str(ORACLE / name), '--godot', 'godot-that-is-not-installed',
                                         '--output', str(output)], capture_output=True, text=True, timeout=120)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('godot executable not found', result.stderr)
                self.assertFalse(receipt.exists(), 'a stale success receipt must not survive')
                self.assertEqual(list(output.iterdir()), [],
                                 'the engine must be resolved before the toolchain and the build')


class ResolvedPathUseTest(unittest.TestCase):
    """The resolved path, not the raw name, reaches the probe and the receipt."""

    def test_every_launcher_uses_the_resolved_path(self):
        for name, (_, _, expressions) in LAUNCHERS.items():
            with self.subTest(launcher=name):
                source = (ORACLE / name).read_text(encoding='utf-8')
                for expression in expressions:
                    self.assertIn(expression, source)


if __name__ == '__main__':
    unittest.main()
