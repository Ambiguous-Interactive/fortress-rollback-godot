"""Value: keep the exported web probes on one leg without losing a check from either leg."""
import re
import unittest
from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/reference-baseline.yml'

# The checks each matrix leg must keep, in the order the workflow runs them.
SUITES_CHECKS = ['scripts/reference/package_audit.py', 'scripts/reference/test_package_audit.py',
                 'scripts/reference/signalfish_probe.py', 'scripts/reference/test_godot_runner.py',
                 'scripts/run_godot_tests.py']
ORACLES_CHECKS = ['scripts/oracle/queue_launch.py', 'scripts/oracle/launch.py', 'scripts/oracle/replay_launch.py',
                  'scripts/oracle/handshake_launch.py', 'scripts/oracle/p2p_launch.py']


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


class ReferenceBaselineWorkflowTests(unittest.TestCase):
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

    # Value: protects=both pinned engines and both legs; fails_when=the matrix loses a version or a part; seam=workflow text
    def test_the_matrix_keeps_both_engines_and_both_legs(self):
        block = '\n'.join(job_blocks(WORKFLOW.read_text(encoding='utf-8'))['godot'])
        self.assertIn('version: ["4.3", "4.7.2"]', block)
        self.assertIn('part: [suites, oracles]', block)

    # Value: protects=every check of both legs; fails_when=a leg loses native work; seam=workflow text
    def test_every_leg_keeps_its_own_checks(self):
        text = WORKFLOW.read_text(encoding='utf-8')
        suites, oracles = leg_commands(text, 'suites'), leg_commands(text, 'oracles')
        for check in SUITES_CHECKS:
            with self.subTest(check=check):
                self.assertIn(check, suites)
        for check in ORACLES_CHECKS:
            with self.subTest(check=check):
                self.assertIn(check, oracles)
        # The mutant drops the oracle trace comparison from the oracles leg.
        mutant = text.replace('python3 scripts/oracle/launch.py', 'python3 scripts/oracle/launch_disabled.py')
        self.assertNotEqual(mutant, text)
        self.assertNotIn('scripts/oracle/launch.py', leg_commands(mutant, 'oracles'))

    # Value: protects=the published artifacts of every leg; fails_when=the upload step disappears; seam=workflow text
    def test_every_leg_still_publishes_its_artifacts(self):
        uploads = [step for step in godot_steps(WORKFLOW.read_text(encoding='utf-8'))
                   if step['attributes'].get('uses', '').startswith('actions/upload-artifact')]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]['attributes'].get('if'), 'always()')
        self.assertIn('godot-browser-reference-results-${{ matrix.version }}-${{ matrix.part }}', uploads[0]['with'].get('name', ''))
