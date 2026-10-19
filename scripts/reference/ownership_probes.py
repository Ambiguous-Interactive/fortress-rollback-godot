#!/usr/bin/env python3
"""Verify integer, ownership and production byte sessions on pinned native/Web engines."""
import json
import os
from pathlib import Path
import platform
import shutil
import zipfile

from fetch import CACHE, ROOT, digest, fetch, load_manifest
from receipt_arguments import ReceiptParser
from godot_smoke import run
from run import begin_results, capture

PREFIX = 'FORTRESS_TEST_RESULT '
EXPECTED = {
    'res://tests/unit/test_protocol_codec.gd': {'golden', 'truncation', 'malformed', 'limits', 'types', 'ownership', 'semantics', 'hostile_bytes'},
    'res://tests/unit/test_protocol_handshake_fields.gd': {'compatibility', 'geometry', 'bounds'},
    'res://tests/unit/test_handshake.gd': {'roundtrips', 'echoes', 'mismatch', 'time', 'identity', 'backpressure', 'timeout_pressure', 'ownership'},
    'res://tests/determinism/test_buffer_ownership.gd': {'engine_boundaries', 'owned_input', 'snapshot_wraps', 'snapshot_bounds'},
    'res://tests/determinism/test_integer_encoding.gd': {'arithmetic', 'binary', 'bounds', 'checksum'},
}
EXPECTED.update({
    'res://tests/unit/test_endpoint_lifecycle.gd': {'control_receive', 'strict_timers', 'liveness', 'quality',
        'checksum_goodbye', 'capacity', 'pacing', 'long_running', 'retention_failure', 'status_nudge_capacity'},
    'res://tests/unit/test_peer_lifecycle.gd': {'checksum_export', 'healthy_exchange', 'real_desync', 'terminal_timeout', 'close',
        'checksum_conflict', 'checksum_future', 'stale_checksum', 'interrupted_resume', 'checksum_capacity', 'event_capacity', 'statistics',
        'lockstep_checksums', 'later_peer_expiry'},
    'res://tests/unit/test_input_endpoint.gd': {'loss_ack', 'retry', 'validation', 'retention', 'capacity', 'ownership',
        'status_nudge', 'status_nudge_transitions'},
    'res://tests/unit/test_stalled_gossip.gd': {'drained', 'dropped_reordered', 'missing_receipt', 'step_recovery', 'grouped_locals'},
    'res://tests/unit/test_session_network_seams.gd': {'delay_startup', 'scheduled_sample', 'confirmation_limit', 'mesh_stall_save'},
    'res://tests/unit/test_peer_session.gd': {'mesh', 'loss', 'multiple_locals', 'backpressure', 'ingress',
        'partial_publication', 'reentry', 'begin_preflight', 'long_runtime', 'request_mismatch', 'low_windows', 'packet_service'},
})
EXPECTED.update({
    'res://tests/unit/test_diagnostic_trace.gd': {'owned_window', 'disabled_equality', 'bounds', 'failed_callback', 'local_divergence'},
    'res://tests/unit/test_peer_diagnostic_trace.gd': {'real_divergence', 'healthy_equality'},
    'res://tests/unit/test_replay_callbacks.gd': {'snapshot_failures', 'uninitialized_replay', 'callback_arguments'},
    'res://tests/unit/test_diagnostic_player.gd': {'captured_window', 'canonical_mismatch', 'malformed', 'callbacks', 'bounds'},
    'res://tests/unit/test_diagnostic_viewer.gd': {'imports', 'controls', 'divergence', 'scene_controls'},
    'res://tests/unit/test_replay_viewer.gd': {'controls', 'rejects_incompatible', 'stops_at_divergence', 'scene_controls', 'navigation', 'navigation_boundaries'},
    'res://tests/unit/test_replay.gd': {'records_corrected_match', 'records_metadata', 'detects_changed_rules', 'golden',
        'rejects_malformed_files', 'bounds_recording', 'lockstep_confirmation_limit'},
})
EXPECTED.update({
    'res://tests/unit/test_spectator_session.gd': {'configuration', 'confirmed_playback', 'buffering', 'delay_and_loss',
        'expert_parity', 'host_export', 'storage_budget', 'host_export_repair', 'exhaustion', 'shapes'},
    'res://tests/unit/test_driver_callback_results.gd': {'valid', 'malformed', 'termination', 'peer_failure'},
})
EXPECTED.update({
    'res://tests/unit/test_driver.gd': {'parity', 'reentry', 'failure', 'validation', 'stall',
        'terminate_reconfigure', 'notifications', 'input_validation', 'missing_samples'},
    'res://tests/unit/test_replay_checkpoints.gd': {'cached_navigation', 'bounded_cache', 'restore_failures', 'checkpoint_callbacks'},
    'res://tests/unit/test_spectator_stream.gd': {'wire_golden', 'byte_delivery', 'malformed',
        'lifetime_and_timeout', 'clean_tail', 'bounds', 'busy', 'keepalive'},
    'res://tests/unit/test_driver_callback_signatures.gd': {'arity', 'optional', 'diagnostic', 'argument_types'},
    'res://tests/unit/test_replay_diagnostics.gd': {'playback_evidence', 'restore_evidence', 'viewer_evidence', 'boundary_validation'},
    'res://tests/unit/test_spectator_demo.gd': {'corrected_viewing', 'pause_and_catchup', 'lost_history', 'idle_host_liveness'},
    'res://tests/unit/test_spectator_policy.gd': {'confirmation_policy'},
    'res://tests/unit/test_spectator_publisher.gd': {'retained_publication', 'clean_end', 'lifetime_and_busy'},
    'res://tests/unit/test_replay_speed.gd': {'cadence', 'controls', 'failure', 'scene_speed'},
})
EXPECTED_COUNT = sum(len(cases) for cases in EXPECTED.values())
FILES = [
    'tests/runner/scenario_runner.gd', 'tests/runner/test_context.gd', 'tests/runner/run_tests.gd',
    'tests/determinism/test_buffer_ownership.gd', 'tests/determinism/ownership_slots.gd',
    'tests/determinism/test_integer_encoding.gd', 'tests/determinism/integer_codec.gd', 'tests/determinism/integer_vectors.json',
    '.llm/code-samples/state_checksum.gd',
    'tests/unit/test_protocol_codec.gd', 'tests/unit/test_protocol_handshake_fields.gd', 'tests/fixtures/protocol/golden.json',
    'addons/fortress_rollback/protocol/protocol_codec.gd', 'addons/fortress_rollback/protocol/protocol_types.gd',
    'addons/fortress_rollback/protocol/protocol_reader.gd', 'addons/fortress_rollback/protocol/protocol_validation.gd',
    'addons/fortress_rollback/protocol/protocol_projection.gd',
    'tests/unit/test_handshake.gd', 'addons/fortress_rollback/protocol/handshake.gd',
    'addons/fortress_rollback/protocol/handshake_types.gd', 'addons/fortress_rollback/protocol/handshake_agreement.gd',
]
FILES += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'addons/fortress_rollback/core').glob('*.gd'))]
FILES += ['addons/fortress_rollback/protocol/input_endpoint.gd',
          'addons/fortress_rollback/protocol/lifecycle_types.gd', 'addons/fortress_rollback/protocol/endpoint_lifecycle.gd',
          'tests/unit/test_endpoint_lifecycle.gd', 'tests/unit/test_peer_lifecycle.gd',
          'addons/fortress_rollback/protocol/input_endpoint_types.gd',
          'tests/unit/test_input_endpoint.gd', 'tests/unit/test_session_network_seams.gd',
          'tests/unit/test_peer_session.gd', 'tests/unit/test_stalled_gossip.gd', 'tests/oracle/p2p_game.gd', 'tests/oracle/reference_game.gd']
FILES += ['tests/unit/test_diagnostic_trace.gd', 'tests/unit/test_peer_diagnostic_trace.gd', 'tests/unit/test_driver.gd']
FILES += ['tests/unit/test_replay_callbacks.gd', 'tests/unit/test_replay.gd', 'tests/fixtures/replay/golden.json', 'examples/integration/game.gd']
FILES += ['tests/unit/test_diagnostic_player.gd', 'tests/unit/test_replay_viewer.gd',
          'examples/online/replay_viewer.gd', 'examples/online/replay_scene.gd', 'examples/online/replay.tscn', 'examples/offline/simulation.gd']
FILES += ['tests/unit/test_diagnostic_viewer.gd', 'examples/online/diagnostic_viewer.gd',
          'examples/online/diagnostic_scene.gd', 'examples/online/diagnostic.tscn']
FILES += ['tests/unit/test_spectator_session.gd', 'tests/unit/test_driver_callback_results.gd']
FILES += ['tests/unit/test_replay_checkpoints.gd', 'tests/unit/test_spectator_stream.gd']
FILES += ['tests/unit/test_driver_callback_signatures.gd', 'tests/unit/test_replay_diagnostics.gd']
FILES += ['tests/unit/test_spectator_demo.gd', 'examples/spectator/demo.gd',
          'examples/integration/demo.gd', 'examples/integration/loop.gd', 'examples/integration/effects.gd']
FILES += ['tests/unit/test_spectator_policy.gd', 'tests/unit/test_replay_speed.gd', 'tests/unit/test_spectator_publisher.gd']
FILES = list(dict.fromkeys(FILES))
HOST = '''extends Node
const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const Suite = preload("res://tests/determinism/test_buffer_ownership.gd")
const Integers = preload("res://tests/determinism/test_integer_encoding.gd")
const Protocol = preload("res://tests/unit/test_protocol_codec.gd")
const HandshakeFields = preload("res://tests/unit/test_protocol_handshake_fields.gd")
const Handshake = preload("res://tests/unit/test_handshake.gd")
const Endpoint = preload("res://tests/unit/test_input_endpoint.gd")
const Seams = preload("res://tests/unit/test_session_network_seams.gd")
const Peers = preload("res://tests/unit/test_peer_session.gd")
const Lifecycle = preload("res://tests/unit/test_endpoint_lifecycle.gd")
const PeerLifecycle = preload("res://tests/unit/test_peer_lifecycle.gd")
const DiagnosticTrace = preload("res://tests/unit/test_diagnostic_trace.gd")
const PeerTrace = preload("res://tests/unit/test_peer_diagnostic_trace.gd")
const StalledGossip = preload("res://tests/unit/test_stalled_gossip.gd")
const Replay = preload("res://tests/unit/test_replay.gd")
const ReplayCallbacks = preload("res://tests/unit/test_replay_callbacks.gd")
const DiagnosticPlayer = preload("res://tests/unit/test_diagnostic_player.gd")
const DiagnosticViewer = preload("res://tests/unit/test_diagnostic_viewer.gd")
const ReplayViewer = preload("res://tests/unit/test_replay_viewer.gd")
const Spectator = preload("res://tests/unit/test_spectator_session.gd")
const DriverInputs = preload("res://tests/unit/test_driver.gd")
const ReplayCheckpoints = preload("res://tests/unit/test_replay_checkpoints.gd")
const SpectatorStream = preload("res://tests/unit/test_spectator_stream.gd")
const CallbackResults = preload("res://tests/unit/test_driver_callback_results.gd")
const CallbackSignatures = preload("res://tests/unit/test_driver_callback_signatures.gd")
const ReplayDiagnostics = preload("res://tests/unit/test_replay_diagnostics.gd")
const SpectatorDemo = preload("res://tests/unit/test_spectator_demo.gd")
const SpectatorPolicy = preload("res://tests/unit/test_spectator_policy.gd")
const SpectatorPublisher = preload("res://tests/unit/test_spectator_publisher.gd")
const ReplaySpeed = preload("res://tests/unit/test_replay_speed.gd")
func _ready() -> void:
\tvar scripts: Array[Script] = [Suite, Integers, Protocol, HandshakeFields, Handshake, Endpoint, Seams, Peers, Lifecycle, PeerLifecycle, StalledGossip, DiagnosticTrace,
\t\tPeerTrace, Replay, ReplayCallbacks, DiagnosticPlayer, DiagnosticViewer, ReplayViewer, Spectator, CallbackResults, DriverInputs,
\t\tReplayCheckpoints, SpectatorStream, CallbackSignatures, ReplayDiagnostics, SpectatorDemo, SpectatorPolicy, SpectatorPublisher, ReplaySpeed]
\tscripts.sort_custom(func(first: Script, second: Script) -> bool: return first.resource_path < second.resource_path)
\tvar result: Dictionary = Scenarios.new().execute(scripts, "determinism", "", 1701)
\tvar text: String = JSON.stringify(result)
\tJavaScriptBridge.eval("document.body.dataset.fortressOwnership = " + JSON.stringify(text))
'''


def validate(result, negative):
    required = {'format', 'complete', 'count', 'errors', 'passed', 'records'}
    if not isinstance(result, dict) or not required.issubset(result):
        raise ValueError('missing result fields')
    if type(result['format']) is not int or type(result['count']) is not int or type(result['passed']) is not bool:
        raise ValueError('incorrect result scalar types')
    if not isinstance(result['errors'], list) or not isinstance(result['records'], list):
        raise ValueError('incorrect result collection types')
    for record in result['records']:
        fields = {'suite', 'case', 'category', 'seed', 'runs'}
        if not isinstance(record, dict) or not fields.issubset(record):
            raise ValueError('missing record fields')
        if any(not isinstance(record[key], str) for key in ('suite', 'case', 'category', 'seed')):
            raise ValueError('incorrect record scalar types')
        if not isinstance(record['runs'], list):
            raise ValueError('incorrect repetition collection type')
        for repetition in record['runs']:
            fields = {'assertions', 'states', 'failures'}
            if not isinstance(repetition, dict) or not fields.issubset(repetition):
                raise ValueError('missing repetition fields')
            if type(repetition['assertions']) is not int or repetition['assertions'] < 1:
                raise ValueError('incorrect assertion count')
            if any(not isinstance(repetition[key], list) for key in ('states', 'failures')):
                raise ValueError('incorrect repetition collection types')
            if any(not isinstance(item, dict) for key in ('states', 'failures') for item in repetition[key]):
                raise ValueError('incorrect diagnostic/state record types')
    if result.get('format') != 1 or result.get('complete') is not True or result.get('count') != EXPECTED_COUNT:
        raise ValueError('missing/incomplete ownership result')
    observed = {(record['suite'], record['case']) for record in result['records']}
    expected = {(suite, case) for suite, cases in EXPECTED.items() for case in cases}
    if result.get('errors') or observed != expected:
        raise ValueError('wrong inventory or repeat divergence')
    if len(result['records']) != EXPECTED_COUNT or result['passed'] != (not negative):
        raise ValueError('unexpected ownership verdict')
    failures = []
    for record in result['records']:
        if record['seed'] != '1701' or record['category'] != 'determinism' or len(record['runs']) != 2:
            raise ValueError('incorrect seed, category or repetition accounting')
        if record['runs'][0] != record['runs'][1]:
            raise ValueError('repeat divergence')
        for repetition in record['runs']:
            if repetition['assertions'] < 1:
                raise ValueError('unasserted case')
            if repetition['failures'] and (record['suite'], record['case']) != ('res://tests/determinism/test_buffer_ownership.gd', 'owned_input'):
                raise ValueError('failure outside the intended alias control')
            failures.extend(repetition['failures'])
    expected_labels = ['copied submission survives caller mutation', 'callback copy cannot edit history']
    if negative:
        expected_failures = [
            {'kind': 'bytes', 'label': label, 'frame': 0, 'byte': 0, 'expected': '0100', 'actual': '0909'}
            for label in expected_labels for _ in range(2)
        ]
        if sorted(failures, key=lambda f: f.get('label', '')) != sorted(expected_failures, key=lambda f: f['label']):
            raise ValueError('negative control failed for unexpected reason')
    elif failures:
        raise ValueError('ownership assertions failed')
    return result


def source_inventory():
    helpers = ['scripts/reference/ownership_probes.py', 'scripts/reference/browser/ownership.cjs',
               'scripts/reference/fetch.py', 'scripts/reference/run.py', 'scripts/reference/godot_smoke.py', 'scripts/reference/receipt_arguments.py',
               'docs/reference/pins.json', 'project.godot']
    return {filename: digest(ROOT / filename) for filename in FILES + helpers}


def verify_sources(expected):
    for filename, checksum in expected.items():
        path = ROOT / filename
        if not path.is_file() or digest(path) != checksum:
            raise ValueError(f'ownership source changed during execution: {filename}')


def main():
    parser = ReceiptParser(description=__doc__, receipt='ownership.json', output=CACHE / 'results')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--web', action='store_true')
    args = parser.parse_args()
    results = CACHE / 'results'
    begin_results(results, 'ownership.json', [p.name for p in results.glob('ownership-*.log')])
    frozen_sources = source_inventory()
    data = load_manifest()
    arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}.get(platform.machine())
    if platform.system() != 'Linux' or arch is None:
        raise ValueError('ownership tool bootstrap supports Linux arm64/x86_64')
    environment = os.environ.copy()
    environment['XDG_DATA_HOME'] = str(CACHE / 'godot-data')
    records = []
    for version in [data['godot']['minimum'], data['godot']['current_stable']]:
        name = f'Godot_v{version}-stable_linux.{arch}.zip'
        archive = fetch(data['artifacts'][name], name, args.offline)
        editor_dir = CACHE / 'ownership-editors' / version
        editor_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as package:
            package.extractall(editor_dir)
        editor = editor_dir / name[:-4]
        editor.chmod(0o755)
        actual = run([str(editor), '--version'], environment, results / f'ownership-{version}-version.log').strip()
        if not actual.startswith(version + '.stable.'):
            raise ValueError('incorrect editor version')
        for negative in (True, False):
            label = f'{version}-' + ('negative' if negative else 'positive')
            project = CACHE / 'ownership-projects' / label
            if project.exists():
                shutil.rmtree(project)
            project.mkdir(parents=True)
            for filename in FILES:
                target = project / filename
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / filename, target)
                if digest(target) != frozen_sources[filename]:
                    raise ValueError(f'ownership copied source changed before execution: {filename}')
            # Godot exports exclude hidden .llm directories: relocate identical
            # sample bytes and adapt only the preload resource path in both hosts.
            checksum_source = '.llm/code-samples/state_checksum.gd'
            checksum_target = 'tests/determinism/reference_checksum.gd'
            shutil.copyfile(project / checksum_source, project / checksum_target)
            if digest(project / checksum_target) != frozen_sources[checksum_source]:
                raise ValueError(f'ownership copied source changed before execution: {checksum_target}')
            integers_source = 'tests/determinism/test_integer_encoding.gd'
            integers = project / integers_source
            if digest(integers) != frozen_sources[integers_source]:
                raise ValueError(f'ownership copied source changed before adaptation: {integers_source}')
            preload = ('res://' + checksum_source).encode('utf-8')
            original_integers = integers.read_bytes()
            if original_integers.count(preload) != 1:
                raise ValueError('checksum preload adaptation no longer applicable')
            adapted_integers = original_integers.replace(preload, ('res://' + checksum_target).encode('utf-8'))
            integers.write_bytes(adapted_integers)
            if integers.read_bytes() != adapted_integers:
                raise ValueError(f'ownership copied source changed after adaptation: {integers_source}')
            if negative:
                suite = project / FILES[3]
                text = suite.read_text()
                before = 'var history: PackedByteArray = caller.duplicate()'
                if text.count(before) != 1:
                    raise ValueError('negative control mutation no longer applicable')
                suite.write_text(text.replace(before, 'var history: PackedByteArray = caller'))
            # Replays record the addon version, which tests compare with the project setting.
            versions = [line for line in (ROOT / 'project.godot').read_text().splitlines() if line.startswith('config/version=')]
            if len(versions) != 1:
                raise ValueError('project version line missing or duplicated')
            (project / 'project.godot').write_text(
                f'config_version=5\n[application]\nconfig/name="Ownership probes"\n{versions[0]}\nrun/main_scene="res://main.tscn"\n'
                '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            (project / 'host.gd').write_text(HOST)
            (project / 'main.tscn').write_text(
                '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://host.gd" id="1"]\n'
                '[node name="Ownership" type="Node"]\nscript = ExtResource("1")\n')
            base = [str(editor), '--headless', '--path', str(project)]
            run(base + ['--editor', '--quit'], environment, results / f'ownership-{label}-import.log')
            # A failed negative test is expected, so inspect the exit code separately.
            code, output = capture(base + ['--script', 'tests/runner/run_tests.gd', '--', '--category', 'determinism']
                                   + [argument for suite in EXPECTED for argument in ('--suite', suite)],
                                   environment, results / f'ownership-{label}-native.log', timeout=180)
            if code != (1 if negative else 0) or 'SCRIPT ERROR:' in output or any(s.startswith('ERROR:') for s in output.splitlines()):
                raise ValueError('native command failed outside the intended control')
            markers = [line[len(PREFIX):] for line in output.splitlines() if line.startswith(PREFIX)]
            if len(markers) != 1:
                raise ValueError('missing/duplicate native report')
            native = validate(json.loads(markers[0]), negative)
            record = {'version': actual, 'editor_artifact': name, 'negative_control': negative, 'native': native}
            if args.web:
                template_name = f'Godot_v{version}-stable_export_templates.tpz'
                templates = fetch(data['artifacts'][template_name], template_name, args.offline)
                template_dir = Path(environment['XDG_DATA_HOME']) / 'godot/export_templates' / (version + '.stable')
                template_dir.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(templates) as package:
                    for member in package.namelist():
                        if Path(member).name.startswith('web_'):
                            (template_dir / Path(member).name).write_bytes(package.read(member))
                (project / 'export_presets.cfg').write_text(
                    '[preset.0]\nname="Web"\nplatform="Web"\nrunnable=true\nexport_filter="all_resources"\ninclude_filter="*.json"\nexclude_filter=""\n'
                    '[preset.0.options]\nvariant/extensions_support=false\nvariant/thread_support=false\n')
                export = CACHE / 'ownership-exports' / label
                export.mkdir(parents=True, exist_ok=True)
                run(base + ['--export-release', 'Web', str(export / 'index.html')], environment, results / f'ownership-{label}-export.log')
                browser_name = f'chromium-1194-{arch}.zip'
                browser_zip = fetch(data['artifacts'][browser_name], browser_name, args.offline)
                browser_dir = CACHE / 'verified-browser' / arch
                browser_dir.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(browser_zip) as package:
                    package.extractall(browser_dir)
                    for member in package.infolist():
                        if not member.is_dir():
                            (browser_dir / member.filename).chmod((member.external_attr >> 16) & 0o777 or 0o644)
                environment['FORTRESS_CHROMIUM_EXECUTABLE'] = str(browser_dir / 'chrome-linux/chrome')
                environment['FORTRESS_PLAYWRIGHT_PACKAGE'] = str(CACHE / 'browser/node_modules/@playwright/test')
                registry = CACHE / 'browser/node_modules/playwright-core/browsers.json'
                if digest(registry) != data['browser']['browser_registry_sha256']:
                    raise ValueError('browser registry differs from pin')
                output = run(['node', str(ROOT / 'scripts/reference/browser/ownership.cjs'), str(export)], environment,
                             results / f'ownership-{label}-browser.log')
                browser = json.loads(output)
                validate(browser['result'], negative)
                if browser['result'] != native:
                    raise ValueError('native/web ownership divergence')
                record.update(browser=browser, browser_artifact=browser_name, template_artifact=template_name)
            records.append(record)
            print(f'Ownership {label}: native' + (' and Web' if args.web else '') + ' verified')
    verify_sources(frozen_sources)
    report = {'status': 'passed', 'web_requested': args.web, 'architecture': arch, 'seed': '1701',
              'manifest_sha256': frozen_sources['docs/reference/pins.json'],
              'sources': frozen_sources,
              'records': records, 'scope': 'Integer/ownership, byte handshakes, input recovery, 2–8-player gameplay and replay playback; '
              'no real transport, performance or other-browser/platform claim.'}
    (results / 'ownership.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
