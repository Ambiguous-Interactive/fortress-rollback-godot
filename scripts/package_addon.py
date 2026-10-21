#!/usr/bin/env python3
"""Build a reproducible addon-only candidate with Python's standard library."""
import argparse
import hashlib
import io
import os
from pathlib import Path
import stat
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ADDON = Path('addons/fortress_rollback')
NOTICES = {'LICENSE', 'NOTICE.md', 'licenses/fortress-LICENSE-MIT'}
DIRECTORIES = {'core', 'protocol', 'transport', 'licenses'}
RUNTIME_SCRIPTS = frozenset({
    'core/config.gd',
    'core/delay_advisor.gd',
    'core/diagnostic_player.gd',
    'core/diagnostic_trace.gd',
    'core/diagnostic_trace_reader.gd',
    'core/driver.gd',
    'core/input_queue.gd',
    'core/peer_checksums.gd',
    'core/peer_session.gd',
    'core/replay.gd',
    'core/replay_player.gd',
    'core/session.gd',
    'core/session_types.gd',
    'core/snapshot_history.gd',
    'core/snapshot_reader.gd',
    'core/snapshot_status.gd',
    'core/snapshot_writer.gd',
    'core/spectator_publisher.gd',
    'core/spectator_negotiation.gd',
    'core/spectator_session.gd',
    'core/spectator_stream.gd',
    'protocol/endpoint_lifecycle.gd',
    'protocol/handshake.gd',
    'protocol/handshake_agreement.gd',
    'protocol/handshake_types.gd',
    'protocol/input_endpoint.gd',
    'protocol/input_endpoint_types.gd',
    'protocol/lifecycle_types.gd',
    'protocol/protocol_codec.gd',
    'protocol/protocol_projection.gd',
    'protocol/protocol_reader.gd',
    'protocol/protocol_types.gd',
    'protocol/protocol_validation.gd',
    'transport/signalfish_adapter.gd',
    'transport/signalfish_fallback.gd',
    'transport/signalfish_membership.gd',
    'transport/signalfish_relay.gd',
    'transport/signalfish_relay_envelope.gd',
    'transport/signalfish_relay_types.gd',
    'transport/signalfish_webrtc.gd',
    'transport/signalfish_webrtc_connection.gd',
    'transport/signalfish_webrtc_multiplayer_peer.gd',
    'transport/signalfish_webrtc_types.gd',
})


def snapshot(root: Path) -> dict[str, bytes]:
    """Validate runtime inputs and freeze their bytes before writing a candidate."""
    addon = root / ADDON
    if (root / 'addons').is_symlink() or addon.is_symlink() or not addon.is_dir():
        raise ValueError('addon root is missing or symlinked')
    files: dict[str, bytes] = {}
    for path in sorted(addon.rglob('*')):
        relative = path.relative_to(addon).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise ValueError('addon contains a symlink')
        if stat.S_ISDIR(mode):
            if relative not in DIRECTORIES:
                raise ValueError('unsupported addon directory')
            continue
        if not stat.S_ISREG(mode):
            raise ValueError('addon contains a nonregular entry')
        if relative not in NOTICES and relative not in RUNTIME_SCRIPTS:
            if not relative.endswith('.gd.uid') or relative[:-4] not in RUNTIME_SCRIPTS:
                raise ValueError(f'unsupported addon file: {relative}')
            if not path.with_suffix('').is_file():
                raise ValueError('unsupported addon file: orphan script UID')
        files[relative] = path.read_bytes()
    if not NOTICES <= files.keys():
        raise ValueError('missing runtime attribution')
    missing_scripts = RUNTIME_SCRIPTS - files.keys()
    if missing_scripts:
        raise ValueError('missing required runtime scripts: ' + ', '.join(sorted(missing_scripts)))
    if any(not files[name].strip() for name in NOTICES):
        raise ValueError('empty runtime attribution')
    for name, source in [('LICENSE', root / 'LICENSE'),
                         ('licenses/fortress-LICENSE-MIT', root / 'docs/reference/licenses/fortress-LICENSE-MIT')]:
        if files[name] != source.read_bytes():
            raise ValueError('runtime license differs from canonical notice')
    return {f'{ADDON.as_posix()}/{name}': data for name, data in files.items()}


def build_archive(root: Path, destination: Path) -> dict[str, bytes]:
    """Atomically write sorted regular tar entries with fixed metadata and no host paths."""
    addon = (root / ADDON).resolve()
    if destination.resolve().is_relative_to(addon):
        raise ValueError('archive output must be outside the addon')
    files = snapshot(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f'.{destination.name}.', dir=destination.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as package:
                for name, data in files.items():
                    entry = tarfile.TarInfo(name)
                    entry.mode = 0o644
                    entry.size = len(data)
                    entry.mtime = 0
                    package.addfile(entry, io.BytesIO(data))
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return files


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True, help='candidate .tar path outside addons/fortress_rollback')
    arguments = parser.parse_args()
    try:
        files = build_archive(ROOT, arguments.output)
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f'Addon candidate failed: {error}\n')
    digest = hashlib.sha256(arguments.output.read_bytes()).hexdigest()
    print(f'{digest}  {arguments.output} ({len(files)} files)')


if __name__ == '__main__':
    main()
