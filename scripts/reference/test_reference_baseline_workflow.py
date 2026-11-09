"""Value: keep the exported web probes on one leg without losing a check from either leg."""
import importlib.util
import re
import unittest
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/reference-baseline.yml'
ROOT = Path(__file__).resolve().parents[2]

# The checks each matrix leg must keep, in the order the workflow runs them.
SUITES_CHECKS = ['scripts/reference/package_audit.py', 'scripts/reference/test_package_audit.py',
                 'scripts/reference/signalfish_probe.py', 'scripts/reference/test_godot_runner.py',
                 'scripts/reference/diagnostic_json.py']
# The two shard legs together own the whole unit inventory exactly once; the second shard
# also keeps the integration and determinism categories.
TESTS_CHECKS = ['scripts/run_godot_tests.py', '--shard "$shard"']
ORACLES_CHECKS = ['scripts/oracle/parallel_launchers.py', 'scripts/oracle/spectator_launch.py']
# The runner's table owns the six upstream comparisons; a dropped entry would silently
# remove its launch from CI, so the table itself is pinned here.
RUNNER_LAUNCHERS = ['queue_launch.py', 'launch.py', 'replay_launch.py',
                    'handshake_launch.py', 'p2p_launch.py', 'drop_history_launch.py']
RUNNER = Path(__file__).resolve().parents[2] / 'scripts/oracle/parallel_launchers.py'


def job_blocks(text):
    """The workflow job blocks, keyed by job name."""
    blocks, name, lines = {}, None, []
    for line in text.splitlines():
        start = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', line)
        if start:
            if name is not None:
                blocks[name] = lines
            name, lines = start.group(1), []
        elif name is not None:
            lines.append(line)
    if name is not None:
        blocks[name] = lines
    return blocks


def job_steps(lines):
    """The steps of a job block, each with its attributes and its command lines."""
    steps, current, attribute = [], None, None
    for line in lines:
        start = re.match(r'^      - ([A-Za-z_]+): (.*)$', line)
        if start:
            current = {'attributes': {start.group(1): start.group(2)}, 'commands': []}
            steps.append(current)
            attribute = None
            continue
        if current is None:
            continue
        entry = re.match(r'^        ([A-Za-z_]+):(?: (.*))?$', line)
        if entry:
            attribute = entry.group(1)
            current['attributes'][attribute] = entry.group(2) or ''
            continue
        nested = re.match(r'^          ([A-Za-z0-9_-]+): (.*)$', line)
        if nested and attribute == 'with':
            current.setdefault('with', {})[nested.group(1)] = nested.group(2)
            continue
        continuation = re.match(r'^          (.*)$', line)
        if continuation and attribute == 'run':
            current['commands'].append(continuation.group(1))
    return steps


def command(step):
    """The full command of a step, including the lines of a block command."""
    return ' '.join([step['attributes'].get('run', '')] + step['commands'])


def godot_steps(text):
    return job_steps(job_blocks(text)['godot'])


def web_probe_conditions(text):
    """The conditions that gate the exported web probes of the engine matrix."""
    return [step['attributes'].get('if') for step in godot_steps(text) if '--web' in command(step)]


def leg_commands(text, part):
    """The commands that the given matrix leg runs."""
    commands = []
    for step in godot_steps(text):
        if step['attributes'].get('if') == f"matrix.part == '{part}'":
            commands.append(command(step))
    return ' '.join(commands)


def shared_leg_commands(text, condition):
    """The commands of every step gated by the given shared matrix condition."""
    return ' '.join(command(step) for step in godot_steps(text) if step['attributes'].get('if') == condition)


class ReferenceBaselineWorkflowTests(unittest.TestCase):
    # Value: protects=native-only oracle jobs avoid unused browser setup; fails_when=setup runs on both legs; seam=workflow text
    def test_browser_dependencies_are_only_installed_for_web_work(self):
        steps = godot_steps(WORKFLOW.read_text(encoding='utf-8'))
        setup = [step for step in steps if step['attributes'].get('uses', '').startswith('actions/setup-node')
                 or 'playwright install-deps' in command(step)]
        self.assertEqual(len(setup), 2)
        for step in setup:
            self.assertEqual(step['attributes'].get('if'), "matrix.part == 'suites'")

    # Value: protects=one exported web probe per pinned engine; fails_when=both legs run it; seam=workflow text
    def test_the_exported_web_probes_run_once_per_pinned_engine(self):
        text = WORKFLOW.read_text(encoding='utf-8')
        self.assertEqual(web_probe_conditions(text), ["matrix.part == 'suites'"])
        steps = [step for step in godot_steps(text) if '--web' in command(step)]
        self.assertEqual(len(steps), 1)
        self.assertIn('--version "${{ matrix.version }}"', command(steps[0]))
        # The mutant runs the exported web probes in both legs again.
        mutant = text.replace("        if: matrix.part == 'suites'\n        run: python3 scripts/reference/godot_smoke.py --web",
                              "        run: python3 scripts/reference/godot_smoke.py --web")
        self.assertNotEqual(mutant, text)
        self.assertNotEqual(web_probe_conditions(mutant), ["matrix.part == 'suites'"])

    # Value: protects=both pinned engines and every leg; fails_when=the matrix loses a version or a part; seam=workflow text
    def test_the_matrix_keeps_both_engines_and_both_legs(self):
        block = '\n'.join(job_blocks(WORKFLOW.read_text(encoding='utf-8'))['godot'])
        self.assertIn('version: ["4.3", "4.7.2"]', block)
        self.assertIn('part: [suites, oracles, tests-1of2, tests-2of2]', block)

    # Value: protects=both shard legs keep the whole unit inventory exactly once; fails_when=a shard drops or repeats suites; seam=workflow text and runner selector
    def test_the_test_shards_cover_the_whole_unit_inventory_exactly_once(self):
        text = WORKFLOW.read_text(encoding='utf-8')
        block = job_blocks(text)['godot']
        self.assertIn('part: [suites, oracles, tests-1of2, tests-2of2]', '\n'.join(block))
        shard_steps = [step for step in godot_steps(text) if '--shard "$shard"' in command(step)]
        self.assertEqual(len(shard_steps), 1)
        self.assertEqual(shard_steps[0]['attributes'].get('if'), "startsWith(matrix.part, 'tests')")
        self.assertIn('shard="${part#tests-}"', command(shard_steps[0]))
        self.assertIn('--results ".cache/tests/runner-$version-$part.json"', command(shard_steps[0]))
        self.assertIn('--category integration', command(shard_steps[0]))
        self.assertIn('--category determinism', command(shard_steps[0]))
        # Integration and determinism run on the declared last shard only; a shard
        # count change must move this literal with the matrix.
        self.assertIn('[[ "$shard" == 2of2 ]]', command(shard_steps[0]))
        runner = importlib.util.spec_from_file_location('run_godot_tests_under_test', ROOT / 'scripts/run_godot_tests.py')
        module = importlib.util.module_from_spec(runner)
        runner.loader.exec_module(module)
        suites = module.discover('unit')
        first = module.select_shard(suites, '1of2')
        second = module.select_shard(suites, '2of2')
        self.assertEqual(sorted(first + second), suites)
        self.assertEqual(set(first) & set(second), set())
        for invalid in ('0/2', '1/', '3/2', 'x/y', '1/2', '0of2', '3of2'):
            with self.subTest(shard=invalid), self.assertRaises(ValueError):
                module.select_shard(suites, invalid)

    # Value: protects=every check of all legs; fails_when=a leg loses native work; seam=workflow text
    def test_every_leg_keeps_its_own_checks(self):
        text = WORKFLOW.read_text(encoding='utf-8')
        suites, oracles = leg_commands(text, 'suites'), leg_commands(text, 'oracles')
        for check in SUITES_CHECKS:
            with self.subTest(check=check):
                self.assertIn(check, suites)
        for check in ORACLES_CHECKS:
            with self.subTest(check=check):
                self.assertIn(check, oracles)
        tests = shared_leg_commands(text, "startsWith(matrix.part, 'tests')")
        for check in TESTS_CHECKS:
            with self.subTest(check=check):
                self.assertIn(check, tests)
        runner = RUNNER.read_text(encoding='utf-8')
        namespace = {'__name__': 'parallel_launchers_under_test', '__file__': str(RUNNER)}
        exec(compile(runner, str(RUNNER), 'exec'), namespace)
        self.assertTrue(set(RUNNER_LAUNCHERS) <= set(namespace['LAUNCHERS'].values()),
                        'the active launcher table dropped a pinned upstream comparison')
        # The mutant comments out one launcher entry; the active table loses it and
        # this validation detects the omission.
        mutant = runner.replace("    'p2p': 'p2p_launch.py',", "    # 'p2p': 'p2p_launch.py',")
        self.assertNotEqual(mutant, runner)
        mutant_namespace = {'__name__': 'parallel_launchers_mutant', '__file__': str(RUNNER)}
        exec(compile(mutant, str(RUNNER), 'exec'), mutant_namespace)
        self.assertFalse(set(RUNNER_LAUNCHERS) <= set(mutant_namespace['LAUNCHERS'].values()))
        # The mutant drops the oracle trace comparison from the oracles leg.
        mutant = text.replace('python3 scripts/oracle/parallel_launchers.py',
                              'python3 scripts/oracle/parallel_launchers_disabled.py')
        self.assertNotEqual(mutant, text)
        self.assertNotIn('scripts/oracle/parallel_launchers.py', leg_commands(mutant, 'oracles'))
        # The mutant drops one test shard leg, losing half the unit inventory.
        mutant = text.replace('part: [suites, oracles, tests-1of2, tests-2of2]', 'part: [suites, oracles, tests-1of2]')
        self.assertNotEqual(mutant, text)
        self.assertEqual(leg_commands(mutant, 'tests-2of2'), '')

    # Value: protects=the pinned engine of the oracle leg; fails_when=the oracle launchers lose it; seam=workflow text
    def test_the_oracle_leg_still_installs_the_pinned_engine(self):
        text = WORKFLOW.read_text(encoding='utf-8')
        oracles = leg_commands(text, 'oracles')
        # The oracle launchers run the pinned editor, so the native probes stay in this leg.
        self.assertIn('scripts/reference/godot_smoke.py', oracles)
        self.assertIn('--version "${{ matrix.version }}"', oracles)
        self.assertNotIn('--web', oracles)
        # The mutant moves the native probes out of the oracle leg and leaves it without an engine.
        mutant = text.replace(
            '      - name: Execute the native engine probes for the oracle launchers\n'
            '        # The oracle launchers need the pinned engine, so this leg keeps the native probes\n'
            '        # and leaves the exported web probe to the suites leg.\n'
            '        if: matrix.part == \'oracles\'\n'
            '        run: python3 scripts/reference/godot_smoke.py --version "${{ matrix.version }}"\n', '')
        self.assertNotEqual(mutant, text)
        self.assertNotIn('scripts/reference/godot_smoke.py', leg_commands(mutant, 'oracles'))

    # Value: protects=the published artifacts of every leg; fails_when=the upload step disappears; seam=workflow text
    def test_every_leg_still_publishes_its_artifacts(self):
        uploads = [step for step in godot_steps(WORKFLOW.read_text(encoding='utf-8'))
                   if step['attributes'].get('uses', '').startswith('actions/upload-artifact')]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]['attributes'].get('if'), 'always()')
        self.assertIn('godot-browser-reference-results-${{ matrix.version }}-${{ matrix.part }}', uploads[0]['with'].get('name', ''))
