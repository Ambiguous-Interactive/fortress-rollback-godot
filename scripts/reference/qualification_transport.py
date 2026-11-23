"""Run one share of the Chromium transport inventory on a fresh hosted runner."""
import argparse
from pathlib import Path
import subprocess
import sys

from fetch import CACHE, load_manifest, sources
from godot_smoke import prepare_editor
from signalfish_webrtc_probe import LABELS

# Each of the five three-room labels took 71..76 seconds on the 4.7.2 hosted pin.
# Pair each with short labels. The probe still owns the eight-page limit within a lane.
TRANSPORT = {
    'clean': ('clean', 'default', 'peer-drop', 'peer-drop-corrupt', 'peer-drop-process', 'peer-drop-process-missing'),
    'faults': ('faults', 'peer-drop-close', 'peer-drop-answer', 'peer-drop-room-after-drop', 'peer-drop-room-before-drop'),
    'mixed': ('mixed', 'corrupt', 'peer-drop-relay', 'peer-drop-missing'),
    'mixed-default': ('mixed-default', 'mixed-disabled', 'peer-drop-missing-lost', 'peer-drop-commit'),
    'mixed-close': ('mixed-close', 'peer-drop-second', 'peer-drop-rollback', 'recording-pressure'),
    'departures': ('peer-drop-foreign', 'peer-drop-room', 'peer-drop-room-continue'),
}
SPECTATORS = {
    'admission': ('healthy', 'initial-state', 'room-identity'),
    'departures': ('viewer-departure', 'host-departure', 'delayed-accept'),
}
PARTS = (*TRANSPORT, 'admission', 'online', 'native')
REFERENCE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--part', choices=PARTS, required=True)
    args = parser.parse_args()
    if sorted(label for labels in TRANSPORT.values() for label in labels) != sorted(LABELS):
        raise ValueError('transport lanes must execute every browser label exactly once')
    data = load_manifest()
    sources_by_name = sources(data)
    results = CACHE / 'results'
    build = CACHE / 'server-build'
    server = ['--server', str(build / 'target/debug/signal-fish-server'), '--server-source', str(sources_by_name['server']),
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


if __name__ == '__main__':
    main()
