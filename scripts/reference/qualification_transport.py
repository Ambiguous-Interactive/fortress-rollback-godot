"""Run one share of the Chromium transport inventory on a fresh hosted runner."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import tempfile

from fetch import CACHE, fetch, load_manifest
from godot_smoke import prepare_editor
from signalfish_live_probe import extract
from signalfish_webrtc_probe import LABELS
from web_templates import web_template_archive

# Use both pins' measured label times with the probe's eight-live-page packing.
# Three-room labels took up to 82 seconds on the merge group; full lanes took up to 146 seconds of browser time.
TRANSPORT = {
    'clean': ('clean', 'peer-drop-process-missing', 'peer-drop-room-after-drop', 'peer-drop-second-after-ack'),
    'faults': ('faults', 'peer-drop-foreign', 'peer-drop-room-before-drop', 'peer-drop-second-last-turn'),
    'mixed': ('mixed', 'corrupt', 'peer-drop-missing', 'peer-drop-second', 'peer-drop-overlap'),
    'mixed-default': ('mixed-default', 'mixed-disabled', 'peer-drop-missing-lost', 'peer-drop-commit'),
    'mixed-close': ('mixed-close', 'peer-drop', 'peer-drop-corrupt', 'peer-drop-room-continue'),
    'departures': ('default', 'peer-drop-close', 'peer-drop-answer', 'peer-drop-relay', 'peer-drop-rollback',
                   'peer-drop-room', 'peer-drop-process', 'recording-pressure'),
}
SPECTATORS = {
    'admission': ('healthy', 'initial-state', 'room-identity', 'viewer-departure', 'host-departure', 'delayed-accept'),
}
PARTS = (*TRANSPORT, 'admission', 'online', 'native')
REFERENCE = Path(__file__).resolve().parent


def prepare_browser_archives(data, version, arch):
    if version not in (data['godot']['minimum'], data['godot']['current_stable']):
        raise ValueError('unknown Godot version')
    template = f'Godot_v{version}-stable_export_templates.tpz'
    browser = f"chromium-{data['browser']['chromium_revision']}-{arch}.zip"
    editor = f'Godot_v{version}-stable_linux.{arch}.zip'
    with ThreadPoolExecutor(max_workers=3) as pool:
        tasks = [pool.submit(web_template_archive, data['artifacts'][template], template, False, CACHE, fetch)]
        tasks.extend(pool.submit(fetch, data['artifacts'][name], name) for name in (browser, editor))
        for task in tasks:
            task.result()


def run_lanes(args, data, server_source):
    results = CACHE / 'results'
    build = CACHE / 'server-build'
    server = ['--server', str(build / 'target/debug/signal-fish-server'), '--server-source', str(server_source),
              '--build-receipt', str(build / 'build-receipt.json')]
    if args.part in TRANSPORT or args.part == 'online':
        online = args.part == 'online'
        labels = ['--online-example'] if online else ['--label=' + label for label in TRANSPORT[args.part]]
        subprocess.run([sys.executable, str(REFERENCE / 'signalfish_webrtc_probe.py'), '--version', args.version, *labels,
                        *server, '--output', str(results / ('online-example' if online else 'signalfish-webrtc'))], check=True)
    if args.part in SPECTATORS or args.part == 'native':
        editor = str(prepare_editor(data, args.version))
        for cell in SPECTATORS.get(args.part, ()):
            flags = []
            if cell == 'delayed-accept':
                flags = ['--browser-fault', 'viewer-departure', '--acceptance-delay-ms', '1500']
            elif cell != 'healthy':
                flags = ['--browser-fault', cell]
            subprocess.run([sys.executable, str(REFERENCE / 'signalfish_spectator_live.py'), '--godot', editor,
                            '--browser-viewer', *flags, *server, '--output', str(results / f'spectator-browser-{args.version}-{cell}')], check=True)
        if args.part == 'native':
            subprocess.run([sys.executable, str(REFERENCE / 'signalfish_native_probes.py'), '--godot', editor, *server,
                            '--version', args.version, '--results', str(results), '--jobs', '2'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--part', choices=PARTS, required=True)
    parser.add_argument('--prepare-browser', action='store_true', help='fetch the three pinned Linux x86_64 browser inputs for the hosted runner')
    args = parser.parse_args()
    if sorted(label for labels in TRANSPORT.values() for label in labels) != sorted(LABELS):
        raise ValueError('transport lanes must execute every browser label exactly once')
    data = load_manifest()
    if args.prepare_browser:
        prepare_browser_archives(data, args.version, 'x86_64')
        return
    pin = data['sources']['server']
    archive = fetch(pin['archive'], 'server.tar.gz')
    with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
        run_lanes(args, data, extract(archive, pin, Path(temporary)))


if __name__ == '__main__':
    main()
