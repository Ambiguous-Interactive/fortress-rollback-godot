"""Value: keep the exported web probes on one leg without losing a check from either leg."""
import importlib.util
import re
import sys
import unittest
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/reference-baseline.yml'
ROOT = Path(__file__).resolve().parents[2]

# The checks each matrix leg must keep, in the order the workflow runs them.
SUITES_CHECKS = ['scripts/reference/package_audit.py', 'scripts/reference/test_package_audit.py',
                 'scripts/reference/signalfish_probe.py', 'scripts/reference/test_godot_runner.py',
                 'scripts/reference/diagnostic_json.py']
TESTS_CHECKS = ['scripts/run_godot_tests.py', '--shard "$shard"']
# The oracle leg keeps the differential launcher wave; the spectator model and the
# handshake formal check are nightly-tier jobs (scripts/tests/test_workflow_tiers.py).
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

    def test_godot_lanes_cover_each_pin_and_unit_suite_once(self):
        text = WORKFLOW.read_text()
        block = '\n'.join(job_blocks(text)['godot'])
        self.assertIn('version: ["4.3", "4.7.2"]', block)
        parts = re.search(r'part: \[(.*?)\]', block).group(1).split(', ')
        self.assertCountEqual(parts, ['suites', 'integration', *[f'tests-{n}of3' for n in range(1, 4)],
                                     *[f'oracle-{n}' for n in range(1, 5)]])
        tests = shared_leg_commands(text, "startsWith(matrix.part, 'tests')")
        for check in TESTS_CHECKS + ['shard="${part#tests-}"', '--results ".cache/tests/runner-$version-$part.json"']:
            self.assertIn(check, tests)
        runner = importlib.util.spec_from_file_location('run_godot_tests_under_test', ROOT / 'scripts/run_godot_tests.py')
        module = importlib.util.module_from_spec(runner)
        runner.loader.exec_module(module)
        suites = module.discover('unit')
        executed = [suite for n in range(1, 4) for suite in module.select_shard(suites, f'{n}of3')]
        self.assertCountEqual(executed, suites)
        for invalid in ('0/2', '1/', '3/2', 'x/y', '1/2', '0of2', '3of2'):
            with self.subTest(shard=invalid), self.assertRaises(ValueError):
                module.select_shard(suites, invalid)

    def test_every_godot_lane_keeps_its_checks_and_editor(self):
        text = WORKFLOW.read_text()
        for check in SUITES_CHECKS:
            self.assertIn(check, leg_commands(text, 'suites'))
        integration = leg_commands(text, 'integration')
        self.assertIn('for case in default_single default_batched readiness_boundary aborted_wait', integration)
        self.assertIn('--category integration --filter "$case"', integration)
        self.assertIn('--category determinism', integration)
        oracles = shared_leg_commands(text, "startsWith(matrix.part, 'oracle-')")
        self.assertIn('scripts/oracle/parallel_launchers.py', oracles)
        self.assertIn('--skip-formal --lane "${part#oracle-}"', oracles)
        self.assertIn('scripts/reference/godot_smoke.py --version "${{ matrix.version }}"', leg_commands(text, 'oracle-4'))
        prepare = shared_leg_commands(text, "matrix.part != 'suites' && matrix.part != 'oracle-4'")
        self.assertIn("prepare_editor(load_manifest(), os.environ['VERSION'])", prepare)

    def test_oracle_lanes_cover_every_comparison_and_wrap_case_once(self):
        sys.path.insert(0, str(RUNNER.parent))
        self.addCleanup(sys.path.remove, str(RUNNER.parent))
        import parallel_launchers
        import p2p_launch
        lanes = parallel_launchers.QUALIFICATION_LANES
        names = [name for lane in lanes for name in lane]
        self.assertCountEqual(names, ['p2p', 'drop-history', 'replay', 'oracle', 'handshake', 'queue', 'sync-floor'])
        self.assertCountEqual([parallel_launchers.LAUNCHERS[name] for name in names],
                              [*RUNNER_LAUNCHERS, 'sync_floor_launch.py'])
        self.assertEqual(parallel_launchers.LAUNCHERS['p2p-wrap'], 'p2p_wrap_launch.py')
        wrap = [case for part in range(1, len(lanes) + 1) for case in p2p_launch.wrap_partition(part)]
        self.assertCountEqual(wrap, p2p_launch.p2p_wrap.NAMES)

    def test_relay_witnesses_share_the_producer_artifact_and_cover_all_cells(self):
        import qualification_transport as transport
        text = WORKFLOW.read_text()
        server = '\n'.join(job_blocks(text)['server'])
        relay = '\n'.join(job_blocks(text)['signalfish'])
        self.assertIn('scripts/reference/signalfish_build_server.py', server)
        self.assertIn('artifact: ${{ steps.publish.outputs.artifact-id }}', server)
        self.assertIn('needs: server', relay)
        self.assertIn('artifact-ids: ${{ needs.server.outputs.artifact }}', relay)
        self.assertIn('qualification_transport.py --version "${{ matrix.version }}" --part "${{ matrix.part }}"', relay)
        self.assertIn('version: ["4.3", "4.7.2"]', relay)
        self.assertCountEqual(re.search(r'part: \[(.*?)\]', relay).group(1).split(', '), transport.PARTS)
        self.assertCountEqual([label for labels in transport.TRANSPORT.values() for label in labels], transport.LABELS)
        self.assertCountEqual([cell for cells in transport.SPECTATORS.values() for cell in cells],
                              ['healthy', 'initial-state', 'room-identity', 'viewer-departure', 'host-departure', 'delayed-accept'])
        self.assertTrue(set(transport.SPECTATORS) <= set(transport.PARTS))
        self.assertIn('online', transport.PARTS)
        self.assertIn('native', transport.PARTS)

    # Value: protects=the published artifacts of every leg; fails_when=the upload step disappears; seam=workflow text
    def test_every_leg_still_publishes_its_artifacts(self):
        uploads = [step for step in godot_steps(WORKFLOW.read_text(encoding='utf-8'))
                   if step['attributes'].get('uses', '').startswith('actions/upload-artifact')]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]['attributes'].get('if'), 'always()')
        self.assertIn('godot-browser-reference-results-${{ matrix.version }}-${{ matrix.part }}', uploads[0]['with'].get('name', ''))
