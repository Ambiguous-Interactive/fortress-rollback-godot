"""Tier composition of the GitHub workflows: gate on every push, qualify on main, nightly axes.

Value: the three-tier CI model keeps every existing gate somewhere while making the
per-push path fast. A workflow edit that loses an axis from every tier, puts the
Firefox axis or the Java model checks back on the per-push path, drops the retry
wrapper from any package acquisition, or removes the pre-push cancel behavior
fails here. The full engine-job checks stay in
``scripts/reference/test_reference_baseline_workflow.py``; this file owns which
jobs run in which tier.
"""
import re
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github/workflows'
GATE = WORKFLOWS / 'gate.yml'
QUALIFY = WORKFLOWS / 'reference-baseline.yml'
NIGHTLY = WORKFLOWS / 'nightly.yml'
DEVCONTAINER = WORKFLOWS / 'devcontainer.yml'
LLM_LINT = WORKFLOWS / 'llm-lint.yml'
HANDSHAKE = ROOT / 'scripts/oracle/handshake_launch.py'
PARALLEL = ROOT / 'scripts/oracle/parallel_launchers.py'

# Package-acquisition commands whose failure class (#349 APT mirror hangs) needs
# the bounded retry wrapper. Counts are per workflow file.
ACQUISITION = re.compile(r'playwright install-deps|apt-get install -y')
QUALIFY_ACQUISITIONS = 4
NIGHTLY_ACQUISITIONS = 6
# The qualify ownership matrix keeps the whole Chromium axis: both engine pins,
# both phases, five minimum-pin parts and four current-pin parts.
QUALIFY_CHROMIUM_PARTS = 18
# The nightly ownership matrix owns the Firefox axis with the same shape.
NIGHTLY_FIREFOX_PARTS = 16


def read(path: Path) -> str:
    return path.read_text(encoding='utf-8')


def job_blocks(text):
    """The workflow job blocks, keyed by job name (same seam as the qualify contract)."""
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


def acquisition_commands(text):
    return [line.strip() for line in text.splitlines() if ACQUISITION.search(line)]


def active_lines(text):
    """The workflow text without full-line YAML comments, so a commented-out
    trigger cannot satisfy (or evade) a presence or absence assertion."""
    return '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))


class WorkflowTierTests(unittest.TestCase):

    def test_relay_server_workflows_use_the_verified_manifest_source(self):
        for path, job_name in ((QUALIFY, 'server'), (NIGHTLY, 'signalfish')):
            with self.subTest(workflow=path.name):
                job = '\n'.join(job_blocks(active_lines(read(path)))[job_name])
                self.assertNotRegex(job, r'signal-fish-server-(?:[0-9a-f]{40}|\*)')
                steps = {}
                for step in job.split('      - name: ')[1:]:
                    name, _, body = step.partition('\n')
                    steps[name] = body
                pinned = steps['Verify the pinned sources and name the server build cache']
                self.assertLess(pinned.index('python3 scripts/reference/fetch.py'), pinned.index("jq -er '.sources.server.root' docs/reference/pins.json"))
                self.assertIn('sha256sum "$server_source/Cargo.lock"', pinned)
                self.assertIn('echo "source=$server_source" >> "$GITHUB_OUTPUT"', pinned)
                build = steps['Build the pinned local SignalFish server']
                self.assertIn('SERVER_SOURCE: ${{ steps.pinned.outputs.source }}', build)
                self.assertIn('--source "$SERVER_SOURCE"', build)
                if path == NIGHTLY:
                    witness = steps['Verify real browser WebRTC on the pinned engine']
                    self.assertIn('SERVER_SOURCE: ${{ steps.pinned.outputs.source }}', witness)
                    self.assertIn('--server-source "$SERVER_SOURCE"', witness)

    # Value: protects=bounded Web setup and browser inventory; fails_when=setup shares room budget or loses dependencies; seam=workflow shell
    def test_native_web_setup_is_bounded_and_preserves_dependencies(self):
        workflow = active_lines(read(WORKFLOWS / 'gdextension-experiment.yml'))
        steps = workflow.split('      - name: ')

        def named_step(name):
            return next((step for step in steps if step.startswith(name + '\n')), '')

        acquire = named_step('Install native Web browser dependencies')
        download = named_step('Install pinned native Web browsers')
        room_dependencies = named_step('Install native SignalFish room dependencies')
        exported = named_step('Run exported match and both controls')
        qualify = named_step('Qualify the playable native SignalFish rooms')
        for step in (acquire, download, room_dependencies):
            self.assertIn("if: matrix.target == 'web'", step)
            self.assertRegex(step, r'timeout-minutes: (?:[1-9]|10)\n')
        self.assertIn("&& env.BROWSER_PAIR != 'chromium'", room_dependencies)
        self.assertIn('npm install --prefix "$RUNNER_TEMP/browsers" playwright@1.64.1', acquire)
        self.assertIn('playwright" install chromium firefox webkit', download)
        order = [steps.index(step) for step in (acquire, download, exported, room_dependencies, qualify)]
        self.assertEqual(order, sorted(order))
        self.assertNotIn('install --with-deps', workflow)
        self.assertNotIn('apt-get install', acquire)
        self.assertNotIn('apt-get install', qualify)
        script = acquire.split('        run: |\n', 1)[1]
        room_script = room_dependencies.split('        run: |\n', 1)[1]
        mock = r'''
sudo() {
    printf 'sudo %s\n' "$*"
    [[ "$FAIL_STEP" != mirrors || "$*" != *prepare_ubuntu_apt.sh* ]]
}
bash() {
    printf 'bash %s\n' "$*"
    [[ "$FAIL_STEP" != packages || "$*" != *install-deps* ]]
}
npm() { printf 'npm %s\n' "$*"; }
xdotool() { :; }
'''
        for profile, packages, failure in (
            ('chromium', [], ''), ('chromium-webkit', ['coturn'], ''),
            ('firefox', ['coturn', 'xdotool'], ''), ('firefox', [], 'mirrors'), ('firefox', [], 'packages'),
        ):
            with self.subTest(profile=profile, failure=failure):
                commands = mock + script + (room_script if profile != 'chromium' else '')
                result = subprocess.run(['bash', '-eu', '-c', commands], capture_output=True, text=True,
                                        env={'BROWSER_PAIR': profile, 'RUNNER_TEMP': '/runner', 'FAIL_STEP': failure, 'GITHUB_ENV': '/dev/null'})
                self.assertEqual(result.returncode, int(bool(failure)), result.stderr)
                calls = result.stdout.splitlines()
                self.assertIn('prepare_ubuntu_apt.sh', calls[0])
                wrapped = 'bash scripts/reference/retry_apt_fetch.sh /runner/browsers/node_modules/.bin/playwright install-deps chromium firefox webkit'
                self.assertEqual(calls.count(wrapped), int(failure != 'mirrors'))
                self.assertEqual([line.rsplit(' ', 1)[-1] for line in calls if 'apt-get install -y ' in line], packages)

    def test_native_browser_dispatch_can_focus_one_room(self):
        workflow = active_lines(read(WORKFLOWS / 'gdextension-experiment.yml'))
        self.assertRegex(workflow, r"cell:\n +description: .+\n +type: choice\n +default: all")
        self.assertIn("format(' / {0}', inputs.cell)", workflow.partition('\non:')[0])
        declared = re.search(r'^ +options: \[all, (.+)\]$', workflow, re.MULTILINE)
        self.assertIsNotNone(declared)
        runner = ROOT / 'scripts/reference/native_online_probe.py'
        help_text = subprocess.check_output([sys.executable, str(runner), '--help'], text=True)
        choices = re.search(r'--cell \{([^}]+)\}', help_text)
        self.assertIsNotNone(choices)
        self.assertCountEqual(re.findall(r"'([^']+)'", declared[1]), choices[1].split(','))
        platform = '\n'.join(job_blocks(workflow)['platform'])
        self.assertIn("inputs.cell && inputs.cell != 'all' || inputs.qualification", platform)
        self.assertIn("NATIVE_BROWSER_CELL: ${{ inputs.cell }}", platform)
        selector = platform.split('          cell_args=()', 1)[1].split('      - uses:', 1)[0]
        selector = selector.replace('${{ matrix.version }}', '4.3')
        run = 'xvfb-run() { printf "%s\\n" "$@"; }\ncell_args=()' + selector
        for cell in ('', 'all', 'relay:8', 'mesh-startup:4'):
            with self.subTest(cell=cell):
                result = subprocess.run(
                    ['bash', '-eu', '-c', run],
                    env={'NATIVE_BROWSER_CELL': cell, 'BROWSER_PAIR': 'firefox', 'output': 'test-output'},
                    check=True, capture_output=True, text=True,
                )
                arguments = result.stdout.splitlines()
                self.assertEqual(arguments[arguments.index('--browser-pair') + 1], 'firefox')
                expected = [] if cell in ('', 'all') else [cell]
                self.assertEqual([value for flag, value in zip(arguments, arguments[1:]) if flag == '--cell'], expected)
                self.assertEqual(arguments.count('--cell'), len(expected))

    # Value: protects=hosted trace provenance; fails_when=wrong server or an unsupported room is run; why_new=cell control only checks room args; seam=workflow shell
    def test_native_browser_dispatch_selects_traced_server(self):
        workflow = active_lines(read(WORKFLOWS / 'gdextension-experiment.yml'))
        steps = workflow.split('    steps:\n', 1)[1]
        self.assertTrue(steps.startswith('      - name: Validate native relay inputs\n'))
        validation = steps.split('      - uses:', 1)[0]
        self.assertIn('if: inputs.relay_trace', validation)
        guard = validation.split('        run: |\n', 1)[1]
        step = workflow.split('      - name: Qualify the playable native SignalFish rooms\n')[1].split('      - uses:', 1)[0]
        self.assertIn('fromJSON((inputs.relay_trace ||', workflow)
        self.assertIn('NATIVE_RELAY_TRACE: ${{ inputs.relay_trace }}', workflow)
        artifact_root = '.cache/native-experiment/${{ matrix.version }}/${{ matrix.target }}'
        for artifact in ('native-online-trace/build-receipt.json', 'native-online-trace/build.log', 'native-online/*.json', 'native-online/*.log'):
            self.assertIn(f'{artifact_root}/{artifact}', workflow)
        script = step.split('        run: |\n', 1)[1]
        tools = r"""
python() {
    printf '%s\n' "$@"
    if [[ "$1" == */signalfish_build_trace_server.py && "$FAIL_BUILD" == true ]]; then return 7; fi
}
jq() { printf '%s\n' pin; }
node() { printf '%s\n' browser; }
rustup() { printf '%s\n' cargo; }
sudo() { :; }
xdotool() { :; }
xvfb-run() { printf '%s\n' "$@"; }
"""
        cases = (
            ('4.3', 'chromium', '', 'all', 0),
            ('4.3', 'chromium', 'false', 'relay:8', 0),
            ('4.3', 'chromium', 'true', 'relay:2', 0),
            ('4.7.2', 'chromium-firefox', 'true', 'relay:4', 0),
            ('4.7.2', 'firefox', 'true', 'relay:8', 0),
            ('4.3', 'chromium', 'true', 'all', 1),
            ('4.3', 'chromium', 'true', 'mesh:8', 1),
            ('4.7.2', 'firefox', 'true', 'relay:8', 7),
        )
        for version, pair, trace, cell, exit_code in cases:
            with self.subTest(version=version, pair=pair, trace=trace, cell=cell, exit_code=exit_code):
                qualified_step = script.replace('${{ matrix.version }}', version)
                result = subprocess.run(
                    ['bash', '-eu', '-c', tools + (guard if trace == 'true' else '') + qualified_step],
                    env={'BROWSER_PAIR': pair, 'NATIVE_BROWSER_CELL': cell, 'NATIVE_RELAY_TRACE': trace, 'FAIL_BUILD': str(exit_code == 7).lower()},
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, exit_code, result.stderr)
                calls = result.stdout.splitlines()
                if exit_code == 1:
                    self.assertEqual(calls, [])
                    self.assertIn('Relay tracing requires an explicit relay cell.', result.stderr)
                    continue
                traced = trace == 'true'
                self.assertEqual('scripts/reference/signalfish_build_server.py' in calls, not traced)
                self.assertEqual('scripts/reference/signalfish_build_trace_server.py' in calls, traced)
                self.assertEqual('scripts/reference/native_online_probe.py' in calls, exit_code == 0)
                if exit_code:
                    continue
                self.assertEqual('--relay-trace-server' in calls, traced)
                if traced:
                    receipt = calls[calls.index('--relay-trace-server') + 1]
                    self.assertEqual(receipt, f'.cache/native-experiment/{version}/web/native-online-trace/build-receipt.json')
                    self.assertEqual(calls[calls.index('--cell') + 1], cell)

    def test_native_release_controls_keep_all_attempts_after_a_room_failure(self):
        workflow = active_lines(read(WORKFLOWS / 'gdextension-experiment.yml'))
        self.assertRegex(workflow, r'release_controls:\n +description: .+\n +type: boolean\n +default: false')
        guard = workflow.split('    steps:\n', 1)[1].split('        run: |\n', 1)[1].split('      - uses:', 1)[0]
        step = workflow.split('          cell_args=()', 1)[1].split('      - uses:', 1)[0].replace('${{ matrix.version }}', '4.7.2')
        mock = r"""
xvfb-run() {
    printf '%s\n' "$*"
    [[ "$*" != *'--output test-output/native-online' ]]
}
"""
        for pair, cell, trace, allowed in (
            ('firefox', 'relay:8', 'false', True),
            ('chromium', 'relay:8', 'false', False),
            ('firefox', 'relay:4', 'false', False),
            ('firefox', 'relay:8', 'true', False),
        ):
            with self.subTest(pair=pair, cell=cell, trace=trace):
                env = {'NATIVE_BROWSER_PROFILE': pair, 'NATIVE_BROWSER_CELL': cell, 'BROWSER_PAIR': pair,
                       'NATIVE_RELAY_TRACE': trace, 'NATIVE_RELEASE_CONTROLS': 'true', 'output': 'test-output'}
                result = subprocess.run(['bash', '-eu', '-c', mock + guard + '\ntrace_args=(); cell_args=()' + step],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                calls = result.stdout.splitlines()
                if not allowed:
                    self.assertEqual(calls, [])
                    self.assertIn('Release controls require an untraced Firefox relay:8 cell.', result.stderr)
                    continue
                self.assertEqual(len(calls), 5)
                for call, arguments in zip(calls, (
                    'firefox --cell relay:8 --output test-output/native-online',
                    'firefox --cell relay:4 --output test-output/native-release-controls/firefox-4',
                    'chromium --cell relay:8 --output test-output/native-release-controls/chromium-8',
                    'firefox --cell relay:8 --release-delay delivery --output test-output/native-release-controls/delivery',
                    'firefox --cell relay:8 --release-delay continuation --output test-output/native-release-controls/continuation',
                ), strict=True):
                    self.assertTrue(call.endswith('--browser-pair ' + arguments), call)
                    self.assertIn('--version 4.7.2 --addon test-output/addon.zip', call)

    def test_reference_tiers_have_no_pull_request_trigger(self):
        # The Gate workflow owns per-push and pull-request runs and the merge
        # queue's grouped candidates; the qualify and nightly tiers trigger on
        # merges, schedules and explicit dispatches only. The devcontainer
        # build intentionally keeps its pull_request trigger outside the tier
        # model. Assertions read active workflow lines only: a commented-out
        # trigger neither satisfies nor evades them.
        gate = active_lines(read(GATE))
        self.assertIn('pull_request:', gate)
        # The queue requires the Gate checks on grouped merge candidates; a
        # missing merge_group trigger would leave the queue hanging forever.
        self.assertIn('merge_group:', gate)
        # Feature branches verify through their pull_request run; a push
        # trigger on every branch would run the whole gate twice per change.
        self.assertRegex(gate, r'on:\n\s+push:\n\s+branches: \[main\]')
        for path in (NIGHTLY,):
            with self.subTest(workflow=path.name):
                self.assertNotIn('pull_request:', active_lines(read(path)))
        self.assertFalse(LLM_LINT.exists(), 'the harness checks moved into gate.yml')

    def test_gate_jobs_cover_harness_changed_unit_and_controls(self):
        text = read(GATE)
        blocks = job_blocks(text)
        for job in ('harness', 'unit-fast', 'controls', 'detect'):
            with self.subTest(job=job):
                self.assertIn(job, blocks)
        # The harness job keeps every llm-lint check so the absorbed workflow loses nothing.
        harness = '\n'.join(blocks['harness'])
        for check in ('check_llm_file_lengths.py', 'generate_llm_index.py --check',
                      'generate_skill_stubs.py --check', 'lint_llm_instructions.py',
                      'make lint-source', 'make test-llm'):
            with self.subTest(check=check):
                self.assertIn(check, harness)
        detect = '\n'.join(blocks['detect'])
        worker = '\n'.join(blocks['unit-part'])
        verdict = '\n'.join(blocks['unit-fast'])
        self.assertIn('fetch-depth: 0', detect)
        self.assertIn('scripts/unit_gate.py plan --base "$BASE"', detect)
        self.assertIn("if: github.event_name != 'merge_group' &&", worker)
        self.assertIn('scripts/unit_gate.py run --part "$PART"', worker)
        self.assertIn("needs: [detect, unit-part, qualify]", verdict)
        self.assertIn("if: always()", verdict)
        self.assertIn('test "$QUALIFIED" = success', verdict)
        self.assertIn('scripts/unit_gate.py verify', verdict)
        self.assertIn('merge-multiple: true', verdict)
        self.assertIn('path: .cache/tests/gate-unit-part-${{ matrix.part }}.json', worker)
        self.assertIn('set -o pipefail', verdict)
        self.assertNotIn('4.7.2', worker)
        workers = '\n'.join(blocks['control-work'])
        self.assertIn("needs.detect.outputs.scripts == 'true'", workers)
        self.assertIn("github.event_name == 'merge_group'", workers)
        self.assertIn('family: [reference, oracle]', workers)
        self.assertIn('make test-${{ matrix.family }}', workers)
        controls = '\n'.join(blocks['controls'])
        self.assertIn('needs: [detect, control-work]', controls)
        self.assertIn('if: always()', controls)
        self.assertIn('test "$WORK" = success', controls)

    def test_gate_base_resolution_fails_closed(self):
        detect = '\n'.join(job_blocks(read(GATE))['detect'])
        for source in ('github.event.pull_request.base.sha', 'github.event.merge_group.base_sha', 'github.event.before'):
            self.assertIn(source, detect)
        self.assertIn('0000000000000000000000000000000000000000', detect)
        self.assertIn('base="unavailable"', detect)
        self.assertIn('.github/actions', detect)
        self.assertIn('scripts=true', detect)
        self.assertIn('set -o pipefail', detect)

    def test_gate_cancels_superseded_runs(self):
        text = read(GATE)
        self.assertIn('concurrency:', text)
        self.assertIn('cancel-in-progress: ${{ github.event_name == \'pull_request\' }}', text)
        devcontainer = read(DEVCONTAINER)
        self.assertIn('concurrency:', devcontainer)
        self.assertIn('cancel-in-progress: ${{ github.event_name == \'pull_request\' }}', devcontainer)

    def test_qualify_drops_the_moved_axes(self):
        text = read(QUALIFY).lower()
        for moved in ('firefox', 'xvfb', 'java', 'spectator_launch', 'schedule:', 'push:'):
            with self.subTest(moved=moved):
                self.assertNotIn(moved, text)
        # Group candidates call the same matrix the dispatch entry point runs.
        self.assertIn('workflow_call:', active_lines(read(QUALIFY)))
        self.assertIn('workflow_dispatch:', active_lines(read(QUALIFY)))
        self.assertNotIn('pull_request:', active_lines(read(QUALIFY)))
        self.assertNotIn('merge_group:', active_lines(read(QUALIFY)))
        self.assertEqual(len(re.findall(r'^\s*- \{version: "[^"]+", browser: chromium,', text, re.MULTILINE)), QUALIFY_CHROMIUM_PARTS)
        self.assertIn('pair: [chromium]', text)
        self.assertIn("--skip-formal", text)
        self.assertNotIn('--formal off', text)

    def test_qualification_summary_gates_the_merge_queue(self):
        gate = job_blocks(read(GATE))
        caller = '\n'.join(gate['qualify'])
        self.assertIn("if: github.event_name == 'merge_group'", caller)
        self.assertIn('uses: ./.github/workflows/reference-baseline.yml', caller)
        summary = '\n'.join(gate['qualification'])
        for fragment in ('name: Qualification summary', 'needs: [controls, qualify]', 'if: always()',
                         'test "$CONTROLS" = success', 'test "$MATRIX" = success'):
            self.assertIn(fragment, summary)
        blocks = job_blocks(read(QUALIFY))
        dispatch = '\n'.join(blocks['contracts'])
        self.assertIn("if: github.event_name == 'workflow_dispatch'", dispatch)
        for family in ('reference', 'oracle'):
            self.assertIn(f'make test-{family}', dispatch)
        verify = '\n'.join(blocks['qualification'])
        self.assertIn('if: always()', verify)
        declared_jobs = set(re.findall(r'^  ([a-z][a-z-]+):$', read(QUALIFY).split('\njobs:\n', 1)[1], re.MULTILINE))
        needs = re.search(r'needs: \[([^\]]+)\]', verify).group(1).split(', ')
        self.assertCountEqual(needs, declared_jobs - {'qualification'})
        self.assertTrue({'contracts', 'rust', 'ownership', 'godot', 'server', 'signalfish'}.issubset(needs))
        self.assertIn('toJSON(needs)', verify)
        self.assertIn('all(to_entries[]; .value.result == (if .key == "contracts" then $contracts else "success" end))', verify)

    def test_gate_acquires_no_system_packages(self):
        # The fast tier is pure Python plus the manifest-fetched editor: an apt
        # or Playwright acquisition added to the gate must be a deliberate tier
        # change that updates this pin and gains the retry wrapper below.
        text = read(GATE)
        self.assertEqual(acquisition_commands(text), [], acquisition_commands(text))

    def test_qualify_and_nightly_acquisitions_keep_the_retry_wrapper(self):
        for path, expected in ((QUALIFY, QUALIFY_ACQUISITIONS), (NIGHTLY, NIGHTLY_ACQUISITIONS)):
            text = read(path)
            commands = acquisition_commands(text)
            with self.subTest(workflow=path.name, count=len(commands)):
                self.assertEqual(len(commands), expected, commands)
            for command in commands:
                with self.subTest(workflow=path.name, command=command):
                    self.assertIn('scripts/reference/retry_apt_fetch.sh', command, command)

    def test_every_acquisition_job_prepares_the_apt_mirror(self):
        # jobs.md: an APT mirror hang consumed the whole job budget before
        # verification started; every job that installs packages must prepare the
        # mirror list first (the gate installs nothing).
        for path in (GATE, QUALIFY, NIGHTLY):
            text = read(path)
            for name, block in job_blocks(text).items():
                joined = '\n'.join(block)
                if ACQUISITION.search(joined):
                    with self.subTest(workflow=path.name, job=name):
                        self.assertIn('prepare_ubuntu_apt.sh', joined)

    def test_nightly_owns_the_moved_axes(self):
        text = read(NIGHTLY)
        self.assertIn('schedule:', text)
        self.assertIn('workflow_dispatch:', text)
        self.assertNotIn('pull_request:', text)
        self.assertEqual(len(re.findall(r'^\s*- \{version: "[^"]+", browser: firefox,', text, re.MULTILINE)), NIGHTLY_FIREFOX_PARTS)
        transport = '\n'.join(job_blocks(text)['signalfish'])
        self.assertIn('pair: [firefox, chromium-firefox]', transport)
        self.assertIn('nightly-signalfish-${{ matrix.pair }}-results-${{ matrix.version }}-${{ matrix.part }}', transport)
        self.assertIn('--browser-pair "$BROWSER_PAIR"', transport)
        self.assertIn('spectator_launch.py', text)
        self.assertIn('handshake_launch.py', text)
        # Nightly runs the formal model check (default on); the flag that skips it
        # must never appear in the nightly invocation.
        self.assertNotIn('--formal off', text)
        for name, block in job_blocks(text).items():
            joined = '\n'.join(block)
            if ACQUISITION.search(joined):
                with self.subTest(job=name):
                    self.assertIn('prepare_ubuntu_apt.sh', joined)

    def test_nightly_ownership_matrix_rows_and_artifacts_are_unique(self):
        # Both nightly phases reuse the compact -part-N suffixes, so the artifact
        # name must carry the phase itself: upload-artifact v4+ fails a job whose
        # name collides with an already-uploaded artifact of the same run.
        text = read(NIGHTLY)
        self.assertIn('nightly-ownership-firefox-results-${{ matrix.version }}-firefox-${{ matrix.phase }}'
                      '${{ matrix.part_suffix }}', text)
        rows = re.findall(r'version: "(4\.3|4\.7\.2)", browser: firefox, phase: (negative|positive), '
                          r'suite_part: "([1-4])"', text)
        self.assertEqual(len(rows), NIGHTLY_FIREFOX_PARTS)
        self.assertEqual(len(set(rows)), NIGHTLY_FIREFOX_PARTS, rows)

    def test_handshake_formal_check_is_tier_scoped(self):
        launcher = read(HANDSHAKE)
        self.assertIn("--formal", launcher)
        self.assertIn('formal_skipped', launcher)
        self.assertIn("args.formal == 'on'", launcher)
        parallel = read(PARALLEL)
        self.assertIn('--skip-formal', parallel)
        self.assertIn("'--formal', 'off'", parallel)

    def test_parallel_launcher_forwards_the_formal_skip_only_to_handshake(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('parallel_launchers_under_test', PARALLEL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        script = module.ORACLE_DIR / 'handshake_launch.py'
        other = module.ORACLE_DIR / 'p2p_launch.py'
        handshake_base = [module.sys.executable, str(script), '--godot', 'godot', '--output', 'out']
        p2p_base = [module.sys.executable, str(other), '--godot', 'godot', '--output', 'out']
        # Default: unchanged command shape for every launcher.
        self.assertEqual(module.launcher_command('handshake', script, 'godot', 'out'), handshake_base)
        self.assertEqual(module.launcher_command('p2p', other, 'godot', 'out'), p2p_base)
        # Skip flag: only the handshake launcher gains the formal-off arguments.
        self.assertEqual(module.launcher_command('handshake', script, 'godot', 'out', skip_formal=True),
                         handshake_base + ['--formal', 'off'])
        self.assertEqual(module.launcher_command('p2p', other, 'godot', 'out', skip_formal=True), p2p_base)


DRIFT_REPORT = WORKFLOWS / 'drift-report.yml'


class DriftReportWorkflowTests(unittest.TestCase):
    """The M2 schedule may only ever report: weekly and manual triggers, a
    minimal issue-writing scope, and no path that advances a pin."""

    def test_drift_report_triggers_and_scope(self):
        text = read(DRIFT_REPORT)
        active = active_lines(text)
        # Weekly plus explicit dispatches only; a push trigger would rerun the
        # report on every session push and the pull-request path owns review.
        self.assertIn('workflow_dispatch:', active)
        self.assertRegex(active, r'schedule:\n\s+- cron:')
        self.assertNotIn('push:', active)
        self.assertNotIn('pull_request:', active)
        # The reporter writes one deduplicated issue per source and nothing
        # else, so the token scope stays at issues-write over read-only contents.
        self.assertRegex(active, r'permissions:\n\s+contents: read\n\s+issues: write')
        for forbidden in ('contents: write', 'pull-requests: write', 'actions: write'):
            self.assertNotIn(forbidden, active)
        # Reporting-only: the workflow may not pass the reviewed operator's
        # advancement flags or rewrite the pins manifest.
        self.assertIn('drift_report.py', active)
        self.assertNotIn('--advance', active)
        self.assertNotRegex(active, r'drift\.py')
        # Serialized runs keep the observation order deterministic.
        self.assertIn('group: drift-report', active)
        # The Actions installation token cannot resolve `gh api user` (HTTP
        # 403), so the scheduled run names its reporting identity explicitly.
        self.assertNotIn('--reporting-identity', active)
        self.assertIn('  actions: read', active)
        self.assertIn('--checkout-sha "$GITHUB_SHA"', active)


    # Value: protects=observations link uploaded evidence; fails_when=publish precedes upload or reruns replace receipts; why_new=only trigger checks; seam=none
    def test_drift_publication_requires_an_immutable_upload(self):
        active = active_lines(read(DRIFT_REPORT))
        phases = ('--stage', 'uses: actions/upload-artifact@', '/actions/artifacts/$ARTIFACT_ID/zip', '--publish-staged')
        for phase in phases:
            self.assertIn(phase, active)
        stage, upload, download, publish = map(active.index, phases)
        self.assertLess(stage, upload)
        self.assertLess(upload, download)
        self.assertLess(download, publish)
        self.assertIn('name: drift-reports-${{ github.run_attempt }}', active)
        self.assertNotIn('overwrite:', active)
        self.assertIn("!cancelled() && steps.evidence.outcome == 'success' && steps.evidence.outputs.artifact-url != ''",
                      active[upload:publish])
        self.assertIn('ARTIFACT_URL: ${{ steps.evidence.outputs.artifact-url }}', active[upload:publish])
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$ARTIFACT_ID/zip"', active[upload:publish])
        self.assertIn('ARTIFACT_ID: ${{ steps.evidence.outputs.artifact-id }}', active[download:publish])
        self.assertIn('--artifact-id "$ARTIFACT_ID" --run-id "$GITHUB_RUN_ID"', active[publish:])
        self.assertIn("!cancelled() && steps.receipt.outcome == 'success'", active[upload:publish])
        self.assertIn('--artifact-url "$ARTIFACT_URL"', active[publish:])
        self.assertIn('--artifact-archive "$RUNNER_TEMP/drift-reports.zip"', active[publish:])


if __name__ == '__main__':
    unittest.main()
