#!/usr/bin/env python3
"""Run minimum/current pinned editors and optionally real Chromium web exports."""
import json
import os
from pathlib import Path
import platform
import shutil
import zipfile

from fetch import CACHE, ROOT, digest, fetch, load_manifest, prepare_zip
from receipt_arguments import ReceiptParser
from run import begin_results, capture

MARKER = 'FORTRESS_BASELINE_SMOKE_OK:78563412'


def run(cmd, environment, log, timeout=180):
    returncode, output = capture(cmd, environment, log, timeout=timeout)
    if returncode or 'SCRIPT ERROR:' in output or any(line.startswith('ERROR:') for line in output.splitlines()):
        raise RuntimeError(f'Godot/browser command failed: {cmd}; see {log}')
    return output


def main():
    parser = ReceiptParser(description=__doc__, receipt='godot-baseline.json', output=CACHE / 'results')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--web', action='store_true', help='require templates and installed pinned Playwright Chromium')
    parser.add_argument('--version', action='append', help='pinned engine version; defaults to minimum and current')
    args = parser.parse_args()
    results = CACHE / 'results'
    begin_results(results, 'godot-baseline.json', [p.name for p in results.glob('godot-*.log')])
    data = load_manifest()
    arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}.get(platform.machine())
    if arch is None or platform.system() != 'Linux':
        raise ValueError('editor bootstrap supports Linux arm64/x86_64 only')
    records = []
    pinned = [data['godot']['minimum'], data['godot']['current_stable']]
    if any(version not in pinned for version in args.version or []):
        parser.error('only pinned engine versions are accepted')
    for version in [version for version in pinned if version in (args.version or pinned)]:
        name = f'Godot_v{version}-stable_linux.{arch}.zip'
        archive = fetch(data['artifacts'][name], name, args.offline)
        directory = CACHE / 'editors' / version
        directory.mkdir(parents=True, exist_ok=True)
        prepare_zip(archive, directory, executable_members=(name[:-4],))
        editor = directory / name[:-4]
        editor.chmod(0o755)
        environment = os.environ.copy()
        environment['XDG_DATA_HOME'] = str(CACHE / 'godot-data')
        actual = run([str(editor), '--version'], environment, results / f'godot-{version}-version.log').strip()
        if not actual.startswith(version + '.stable.'):
            raise ValueError(f'wrong editor version: {actual}')
        project = CACHE / 'godot-projects' / version
        if project.exists():
            shutil.rmtree(project)
        project.mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/reference/smoke.gd', project / 'smoke.gd')
        (project / 'project.godot').write_text(
            'config_version=5\n[application]\nconfig/name="Reference smoke"\nrun/main_scene="res://main.tscn"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
        (project / 'main.tscn').write_text(
            '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://smoke.gd" id="1"]\n'
            '[node name="Smoke" type="Node"]\nscript = ExtResource("1")\n')
        base = [str(editor), '--headless', '--path', str(project)]
        run(base + ['--editor', '--quit'], environment, results / f'godot-{version}-import.log')
        for repeat in (1, 2):
            output = run(base, environment, results / f'godot-{version}-headless-{repeat}.log')
            if MARKER not in output:
                raise ValueError(f'{version}: missing headless marker')
        invalid = project / 'invalid.gd'
        invalid.write_text('extends SceneTree\nfunc _initialize() -> void:\n\tthis is not valid GDScript\n')
        try:
            run(base + ['--script', str(invalid)], environment, results / f'godot-{version}-negative-control.log')
        except RuntimeError:
            if 'SCRIPT ERROR: Parse Error:' not in (results / f'godot-{version}-negative-control.log').read_text():
                raise
        else:
            raise ValueError(f'{version}: invalid script accepted')
        invalid.unlink()
        record = {'invalid_script_rejected': True, 'version': actual, 'editor_artifact': name, 'headless_repeats': 2, 'marker': MARKER}
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
                '[preset.0]\nname="Web"\nplatform="Web"\nrunnable=true\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\n'
                '[preset.0.options]\nvariant/extensions_support=false\nvariant/thread_support=false\n')
            export = CACHE / 'web-exports' / version
            if export.exists():
                shutil.rmtree(export)
            export.mkdir(parents=True)
            run(base + ['--export-release', 'Web', str(export / 'index.html')], environment, results / f'godot-{version}-export.log')
            environment['FORTRESS_PLAYWRIGHT_PACKAGE'] = str(CACHE / 'browser/node_modules/@playwright/test')
            browser_name = f"chromium-{data['browser']['chromium_revision']}-{arch}.zip"
            browser_zip = fetch(data['artifacts'][browser_name], browser_name, args.offline)
            browser_dir = CACHE / 'verified-browser' / arch
            browser_dir.mkdir(parents=True, exist_ok=True)
            prepare_zip(browser_zip, browser_dir)
            environment['FORTRESS_CHROMIUM_EXECUTABLE'] = str(browser_dir / data['browser']['chromium_executables'][arch])
            registry = CACHE / 'browser/node_modules/playwright-core/browsers.json'
            if digest(registry) != data['browser']['browser_registry_sha256']:
                raise ValueError('Playwright browser registry differs from pin')
            output = run(['node', str(ROOT / 'scripts/reference/browser/smoke.cjs'), str(export)], environment,
                         results / f'godot-{version}-browser.log')
            record.update(browser_artifact=browser_name, template_artifact=template_name, browser=json.loads(output))
        records.append(record)
        print(f'Godot {version}: headless twice' + (' and Chromium export passed' if args.web else ' passed'))
    report = {'status': 'passed', 'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'), 'smoke_source_sha256': digest(ROOT / 'scripts/reference/smoke.gd'),
              'records': records, 'limits': 'Engine/codec smoke only; no addon, rollback, SignalFish or mixed-browser parity evidence.'}
    (results / 'godot-baseline.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
