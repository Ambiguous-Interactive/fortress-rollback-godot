"""Stage and own an actual exported spectator viewer alongside the native host fixture."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import os
from pathlib import Path
import subprocess
import shutil
import threading
import zipfile

from fetch import CACHE, ROOT, digest, fetch, prepare_zip
from godot_smoke import run
from signalfish_probe import inventory
from browser.webrtc_import import freeze_after_import

FILES = ['spectator_browser_host.gd', 'spectator_browser_viewer.gd']


def prepare(project, engine, version, data, arch, offline, output, authored_paths, authored_before):
    templates_name = f'Godot_v{version}-stable_export_templates.tpz'
    templates = fetch(data['artifacts'][templates_name], templates_name, offline)
    environment = os.environ.copy()
    environment['XDG_DATA_HOME'] = str(CACHE / 'godot-data')
    directory = Path(environment['XDG_DATA_HOME']) / 'godot/export_templates' / (version + '.stable')
    directory.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(templates) as package:
        for member in package.namelist():
            if Path(member).name.startswith('web_'):
                target = directory / Path(member).name
                if not target.exists() or digest(target) != hashlib.sha256(package.read(member)).hexdigest():
                    target.write_bytes(package.read(member))
    (project / 'project.godot').write_text('config_version=5\n[application]\nrun/main_scene="res://main.tscn"\n'
                                         '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    (project / 'main.tscn').write_text('[gd_scene load_steps=2 format=3]\n'
                                      '[ext_resource type="Script" path="res://spectator_browser_viewer.gd" id="1"]\n'
                                      '[node name="Viewer" type="Node"]\nscript = ExtResource("1")\n')
    (project / 'export_presets.cfg').write_text('[preset.0]\nname="Web"\nplatform="Web"\nrunnable=true\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\n'
                                              '[preset.0.options]\nvariant/extensions_support=false\nvariant/thread_support=false\n')
    for extracted in ['sdk', 'server']:
        (project / extracted / '.gdignore').write_text('')
    base = [str(engine), '--headless', '--path', str(project)]
    browser_name = f"chromium-{data['browser']['chromium_revision']}-{arch}.zip"
    browser_archive = fetch(data['artifacts'][browser_name], browser_name, offline)
    browser_dir = CACHE / 'verified-browser' / arch
    browser_dir.mkdir(parents=True, exist_ok=True)
    prepare_zip(browser_archive, browser_dir)
    environment['FORTRESS_CHROMIUM_EXECUTABLE'] = str(browser_dir / data['browser']['chromium_executables'][arch])
    environment['FORTRESS_PLAYWRIGHT_PACKAGE'] = str(CACHE / 'browser/node_modules/@playwright/test')
    registry = CACHE / 'browser/node_modules/playwright-core/browsers.json'
    if digest(registry) != data['browser']['browser_registry_sha256']:
        raise ValueError('spectator Playwright registry differs from pin')
    tools = {'templates': templates, 'template_installation': directory, 'browser_archive': browser_archive,
             'browser_registry': registry, 'browser_installation': browser_dir,
             'browser_executable': Path(environment['FORTRESS_CHROMIUM_EXECUTABLE']), 'node': Path(shutil.which('node')).resolve()}
    package = CACHE / 'browser/node_modules'
    tools.update({name: package / relative for name, relative in (
        ('playwright_test', '@playwright/test'), ('playwright', 'playwright'), ('playwright_core', 'playwright-core'))})
    environment['FORTRESS_NODE_EXECUTABLE'] = str(tools['node'])
    tool_inventory = inventory(tools)
    run(base + ['--editor', '--import', '--quit'], environment, output / 'browser-import.log')
    imported = freeze_after_import(authored_paths, authored_before)
    exported = project / 'export'
    exported.mkdir()
    run(base + ['--export-release', 'Web', str(exported / 'index.html')], environment, output / 'browser-export.log')
    if imported != inventory(authored_paths) or tool_inventory != inventory(tools):
        raise ValueError('exported spectator authored sources or tools changed during import/export')
    return exported, environment, tools



class ExportServer:
    def __init__(self, directory):
        class Handler(SimpleHTTPRequestHandler):
            def end_headers(self):
                self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
                self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
                super().end_headers()

            def log_message(self, *_args):
                pass
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(directory)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.url = 'http://127.0.0.1:' + str(self.server.server_port)

    def start(self):
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise ValueError('spectator export server did not stop')


def validate_no_acceptance(control):
    if control.accepted_once is not False or type(control.received) is not int or control.received != 0 or control.done is not None:
        raise ValueError('exported initial-state control accepted or completed playback')


def validate_fault(returncode, browser, host_alive, control, stderr=''):
    if (stderr or type(returncode) is not int or returncode != 1 or host_alive is not True or type(browser) is not dict
            or browser.get('browser') != 'Chromium' or type(browser.get('version')) is not str or not browser['version']
            or browser.get('errors') != [] or type(browser.get('result')) is not dict):
        raise ValueError('exported initial-state control did not reach its intended rejection')
    result = browser['result']
    if result.get('passed') is not False or result.get('reason') != 'browser original-state or membership binding' or result.get('errors') != []:
        raise ValueError('exported initial-state control did not reach its intended rejection')
    expected = {'compared': 0, 'frame': 0, 'simulations': 0, 'accept_pending': False, 'accept_delivered': False}
    observed = browser.get('state')
    if type(observed) is not dict or any(type(observed.get(key)) is not type(value) or observed[key] != value for key, value in expected.items()):
        raise ValueError('exported initial-state control performed acceptance or playback work')
    validate_no_acceptance(control)


def execute(engine, project, runtime, url, environment, output, control, fault=None):
    with (output / 'native.log').open('wb') as log:
        host = subprocess.Popen([str(engine), '--headless', '--path', str(project), '--script', 'res://spectator_browser_host.gd', '--', str(runtime)],
                                stdout=log, stderr=subprocess.STDOUT)
        try:
            try:
                process = subprocess.run([environment['FORTRESS_NODE_EXECUTABLE'], str(ROOT / 'scripts/reference/browser/spectator.cjs'), url, str(runtime)],
                                     env=environment, capture_output=True, encoding='utf-8', timeout=80)
            except subprocess.TimeoutExpired as error:
                (output / 'browser.log').write_bytes((error.stdout or b'') + (error.stderr or b''))
                raise ValueError('exported spectator browser process deadline') from error
            (output / 'browser.log').write_text(process.stdout + process.stderr)
            browser_output = process.stdout
            if fault == 'initial-state':
                browser = json.loads(browser_output)
                validate_fault(process.returncode, browser, host.poll() is None, control, process.stderr)
                return {'fault': fault, 'rejected': True, 'viewer': browser}
            if process.returncode != 0 or process.stderr:
                raise ValueError('exported spectator failed; inspect browser.log')
            host.wait(timeout=10)
        finally:
            if host.poll() is None:
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=5)
    native = (output / 'native.log').read_text()
    rows = [json.loads(line.removeprefix('FORTRESS_BROWSER_HOST_RESULT ')) for line in native.splitlines() if line.startswith('FORTRESS_BROWSER_HOST_RESULT ')]
    if host.returncode != 0 or 'ERROR:' in native or len(rows) != 1:
        raise ValueError('native browser-host witness failed; inspect native.log')
    result = json.loads(browser_output)
    if fault == 'host-departure':
        validate_host_departure(rows[0], result)
    elif fault == 'viewer-departure':
        validate_departure(rows[0], result)
    else:
        validate(rows[0], result)
    return {'host': rows[0], 'viewer': result}


def validate(host, browser):
    if not isinstance(host, dict) or not isinstance(browser, dict) or not isinstance(browser.get('result'), dict):
        raise ValueError('missing exported spectator result')
    viewer = browser['result']
    for row, expected in [(host, {'passed': True, 'frames': 48, 'seated_players': 2, 'confirmed': 47}),
                          (viewer, {'passed': True, 'frames': 48, 'compared': 48, 'viewer_seated': False, 'paused_turns': 12})]:
        for key, value in expected.items():
            if type(row.get(key)) is not type(value) or row[key] != value:
                raise ValueError('incomplete exported spectator evidence: ' + key)
    if type(host.get('host_rollbacks')) is not int or host['host_rollbacks'] < 1:
        raise ValueError('exported witness lacks host rollback')
    if (type(viewer.get('viewer_binary_receives')) is not int or viewer['viewer_binary_receives'] < 1
            or type(viewer.get('paused_rows')) is not int or viewer['paused_rows'] < 2
            or type(viewer.get('catchup_steps')) is not int or not 2 <= viewer['catchup_steps'] <= 4
            or browser.get('browser') != 'Chromium' or type(browser.get('version')) is not str or not browser['version'] or browser.get('errors') != []):
        raise ValueError('missing physical browser playback evidence')


def validate_departure(host, browser):
    if type(host) is not dict or type(browser) is not dict or type(browser.get('result')) is not dict:
        raise ValueError('missing exported physical departure evidence')
    viewer = browser['result']
    expected_host = {'passed': True, 'frames': 48, 'seated_players': 2, 'confirmed': 47,
                     'viewer_departure_observed': True, 'publication_stopped': True, 'host_resumed_frame': 20}
    expected_viewer = {'passed': True, 'departure': 'viewer', 'socket_departed': True, 'playback_stopped': True, 'viewer_seated': False}
    for row, expected in [(host, expected_host), (viewer, expected_viewer)]:
        for key, value in expected.items():
            if type(row.get(key)) is not type(value) or row[key] != value:
                raise ValueError('incomplete exported physical departure evidence: ' + key)
    for key in ['frame', 'compared', 'buffered_rows', 'simulations_before', 'simulations_after']:
        if type(viewer.get(key)) is not int:
            raise ValueError('invalid exported physical departure observation: ' + key)
    if (type(host.get('host_frame_at_departure')) is not int or not 8 <= host['host_frame_at_departure'] <= 20
            or not 8 <= viewer['frame'] < 20 or viewer['compared'] != viewer['frame'] or viewer['buffered_rows'] < 2
            or viewer['simulations_before'] != viewer['frame'] or viewer['simulations_after'] != viewer['simulations_before']
            or type(host.get('host_rollbacks')) is not int or host['host_rollbacks'] < 1
            or browser.get('departureClosed') is not True or browser.get('browser') != 'Chromium'
            or type(browser.get('version')) is not str or not browser['version'] or browser.get('errors') != []):
        raise ValueError('exported physical departure lacks paused history or canonical continuation')


def validate_host_departure(host, browser):
    if type(host) is not dict or type(browser) is not dict or type(browser.get('result')) is not dict:
        raise ValueError('missing exported selected-host departure evidence')
    viewer = browser['result']
    expected_host = {'passed': True, 'departure': 'host', 'frames': 20, 'confirmed': 19, 'socket_closed': True,
                     'remote_host_departure_observed': True, 'publication_stopped': True}
    expected_viewer = {'passed': True, 'departure': 'host', 'socket_departed': False, 'selected_host_departed': True,
                       'playback_stopped': True, 'viewer_seated': False}
    for row, expected in [(host, expected_host), (viewer, expected_viewer)]:
        for key, value in expected.items():
            if type(row.get(key)) is not type(value) or row[key] != value:
                raise ValueError('incomplete exported selected-host departure evidence: ' + key)
    for key in ['frame', 'compared', 'buffered_rows', 'simulations_before', 'simulations_after', 'viewer_binary_receives']:
        if type(viewer.get(key)) is not int:
            raise ValueError('invalid exported selected-host departure observation: ' + key)
    if (type(host.get('viewer_paused_frame')) is not int or host['viewer_paused_frame'] != viewer['frame']
            or not 8 <= viewer['frame'] < 20 or viewer['compared'] != viewer['frame'] or viewer['buffered_rows'] < 2
            or viewer['simulations_before'] != viewer['frame'] or viewer['simulations_after'] != viewer['simulations_before']
            or viewer['viewer_binary_receives'] < 1 or type(host.get('host_rollbacks')) is not int or host['host_rollbacks'] < 1
            or browser.get('departureClosed') is not False or browser.get('browser') != 'Chromium'
            or type(browser.get('version')) is not str or not browser['version'] or browser.get('errors') != []):
        raise ValueError('exported selected-host departure lacks buffered canonical history or independent socket evidence')
