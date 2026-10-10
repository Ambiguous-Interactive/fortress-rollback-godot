#!/usr/bin/env python3
"""Verify integer, ownership and production protocol codec on pinned native/Web engines."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import zipfile

from fetch import CACHE, ROOT, digest, fetch, load_manifest
from godot_smoke import run
from run import begin_results, capture

PREFIX = 'FORTRESS_TEST_RESULT '
EXPECTED = {
    'res://tests/unit/test_protocol_codec.gd': {'golden', 'truncation', 'malformed', 'limits', 'types', 'ownership', 'semantics', 'hostile_bytes'},
    'res://tests/determinism/test_buffer_ownership.gd': {'engine_boundaries', 'owned_input', 'snapshot_wraps', 'snapshot_bounds'},
    'res://tests/determinism/test_integer_encoding.gd': {'arithmetic', 'binary', 'bounds', 'checksum'},
}
EXPECTED_COUNT = sum(len(cases) for cases in EXPECTED.values())
FILES = [
    'tests/runner/scenario_runner.gd', 'tests/runner/test_context.gd', 'tests/runner/run_tests.gd',
    'tests/determinism/test_buffer_ownership.gd', 'tests/determinism/ownership_slots.gd',
    'tests/determinism/test_integer_encoding.gd', 'tests/determinism/integer_codec.gd', 'tests/determinism/integer_vectors.json',
    '.llm/code-samples/state_checksum.gd',
    'tests/unit/test_protocol_codec.gd', 'tests/fixtures/protocol/golden.json',
    'addons/fortress_rollback/protocol/protocol_codec.gd', 'addons/fortress_rollback/protocol/protocol_types.gd',
    'addons/fortress_rollback/protocol/protocol_reader.gd', 'addons/fortress_rollback/protocol/protocol_validation.gd',
    'addons/fortress_rollback/protocol/protocol_projection.gd',
]
HOST = '''extends Node
const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const Suite = preload("res://tests/determinism/test_buffer_ownership.gd")
const Integers = preload("res://tests/determinism/test_integer_encoding.gd")
const Protocol = preload("res://tests/unit/test_protocol_codec.gd")
func _ready() -> void:
\tvar scripts: Array[Script] = [Suite, Integers, Protocol]
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--web', action='store_true')
    args = parser.parse_args()
    results = CACHE / 'results'
    begin_results(results, 'ownership.json', [p.name for p in results.glob('ownership-*.log')])
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
            # Godot exports exclude hidden .llm directories: relocate identical
            # sample bytes and adapt only the preload resource path in both hosts.
            checksum_source = '.llm/code-samples/state_checksum.gd'
            checksum_target = 'tests/determinism/reference_checksum.gd'
            shutil.copyfile(ROOT / checksum_source, project / checksum_target)
            integers = project / 'tests/determinism/test_integer_encoding.gd'
            integers.write_text(integers.read_text().replace('res://' + checksum_source, 'res://' + checksum_target))
            if negative:
                suite = project / FILES[3]
                text = suite.read_text()
                before = 'var history: PackedByteArray = caller.duplicate()'
                if text.count(before) != 1:
                    raise ValueError('negative control mutation no longer applicable')
                suite.write_text(text.replace(before, 'var history: PackedByteArray = caller'))
            (project / 'project.godot').write_text(
                'config_version=5\n[application]\nconfig/name="Ownership probes"\nrun/main_scene="res://main.tscn"\n'
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
    report = {'status': 'passed', 'web_requested': args.web, 'architecture': arch, 'seed': '1701',
              'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'),
              'sources': {p: digest(ROOT / p) for p in FILES + ['scripts/reference/ownership_probes.py', 'scripts/reference/browser/ownership.cjs']},
              'records': records, 'scope': 'Integer/ownership research and production protocol byte boundary; no transport, performance or other-browser/platform claim.'}
    (results / 'ownership.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
