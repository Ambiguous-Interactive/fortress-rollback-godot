#!/usr/bin/env python3
"""Audit an addon-only candidate in a clean project without development tooling."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ADDON = Path('addons/fortress_rollback')
MARKER = 'FORTRESS_ADDON_PACKAGE_OK'
SMOKE = '''extends SceneTree
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Handshake = preload("res://addons/fortress_rollback/protocol/handshake.gd")
const HandshakeTypes = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const ProtocolTypes = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")

class Game:
    extends RefCounted
    var ticks: int = 0
    func save_state(_frame: int, writer: RefCounted) -> Driver.SaveResult:
        writer.write_bytes(PackedByteArray([ticks]))
        var checksum: PackedByteArray = PackedByteArray()
        checksum.resize(16)
        return Driver.SaveResult.new(true, checksum)
    func load_state(_frame: int, reader: RefCounted) -> bool:
        var restored: RefCounted = reader.read_bytes(1)
        if restored.code != 0 or not reader.is_complete():
            return false
        ticks = restored.bytes[0]
        return true
    func simulate_frame(_frame: int, inputs: RefCounted) -> bool:
        for player: int in range(2):
            if inputs.read(player).bytes.size() != 1:
                return false
        ticks += 1
        return true

func _initialize() -> void:
    var config: Config = Config.new()
    config.max_snapshot_bytes = 1
    config.storage_budget_bytes = 100000
    var session: Session = Session.new()
    if session.configure(config) != Types.Code.OK:
        quit(1)
        return
    var game: Game = Game.new()
    var driver: Driver = Driver.new(session, game)
    var samples: Array[Driver.LocalInput] = []
    for player: int in range(2):
        samples.append(Driver.LocalInput.new(player, 0, PackedByteArray([1])))
    var result: Driver.StepResult = driver.step(0, samples)
    if result.code != Types.Code.OK or result.frame_after != 1 or game.ticks != 1:
        quit(1)
        return
    if not _handshake():
        quit(1)
        return
    print("FORTRESS_ADDON_PACKAGE_OK")
    quit(0)

func _handshake() -> bool:
    var peers: Array[Handshake] = []
    var roster: Array[PackedByteArray] = [PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0]), PackedByteArray([2, 0, 0, 0, 0, 0, 0, 0])]
    for slot: int in range(2):
        var local: ProtocolTypes.Message = ProtocolTypes.Message.new()
        local.kind = ProtocolTypes.Kind.SYNC_REQUEST
        local.sender_id = roster[slot].duplicate()
        local.connection_id = roster[slot].duplicate()
        local.session_id.fill(1)
        local.config.roster = roster
        var options: HandshakeTypes.Options = HandshakeTypes.Options.new()
        options.roundtrips = 1
        var peer: Handshake = Handshake.new()
        if peer.configure(local, roster[1 - slot], options) != HandshakeTypes.Code.OK:
            return false
        local.token.fill(slot + 1)
        if peer.begin(0, local.token) != HandshakeTypes.Code.OK:
            return false
        peers.append(peer)
    for packet: PackedByteArray in peers[0].drain_outbox():
        if peers[1].receive(packet, roster[0], 0) != HandshakeTypes.Code.OK:
            return false
    for packet: PackedByteArray in peers[1].drain_outbox():
        if peers[0].receive(packet, roster[1], 0) != HandshakeTypes.Code.OK:
            return false
    for packet: PackedByteArray in peers[0].drain_outbox():
        if peers[1].receive(packet, roster[0], 0) != HandshakeTypes.Code.OK:
            return false
    return peers[0].status().state == "running" and peers[1].status().state == "running"
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'package-audit.json'
    receipt.write_text('{"passed": false, "failure": "in_progress"}\n')
    executable = Path(shutil.which(str(args.godot)) or args.godot).resolve()
    if (ROOT / ADDON).is_symlink() or not (ROOT / ADDON).is_dir():
        raise ValueError('addon root is missing or symlinked')
    paths = sorted((ROOT / ADDON).rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise ValueError('addon contains a symlink')
    if any(not path.is_dir() and not path.is_file() for path in paths):
        raise ValueError('addon contains a nonregular entry')
    files = [path for path in paths if path.is_file()]
    required = {'LICENSE', 'NOTICE.md', 'licenses/fortress-LICENSE-MIT'}
    if not required <= {str(path.relative_to(ROOT / ADDON)) for path in files}:
        raise ValueError('missing runtime attribution')
    if any(not (ROOT / ADDON / name).read_bytes().strip() for name in required):
        raise ValueError('empty runtime attribution')
    for name, source in [('LICENSE', ROOT / 'LICENSE'),
                         ('licenses/fortress-LICENSE-MIT', ROOT / 'docs/reference/licenses/fortress-LICENSE-MIT')]:
        if (ROOT / ADDON / name).read_bytes() != source.read_bytes():
            raise ValueError('runtime license differs from canonical notice')
    if any(path.suffix not in ('.gd', '.uid', '.md') and str(path.relative_to(ROOT / ADDON)) not in required for path in files):
        raise ValueError('unsupported addon file or symlink')
    archive = args.output / 'fortress-addon-candidate.tar'
    with tarfile.open(archive, 'w') as package:
        for path in files:
            package.add(path, arcname=str(path.relative_to(ROOT)), recursive=False)
    with tempfile.TemporaryDirectory(prefix='fortress-clean-addon-') as temporary:
        project = Path(temporary)
        with tarfile.open(archive) as package:
            entries = package.getnames()
            if entries != [str(path.relative_to(ROOT)) for path in files]:
                raise ValueError('archive differs from addon allowlist')
            package.extractall(project, filter='data')
        (project / 'project.godot').write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
        (project / 'smoke.gd').write_text(SMOKE)
        command = [str(executable), '--headless', '--path', str(project), '--script', 'res://smoke.gd']
        process = subprocess.run(command, capture_output=True, encoding='utf-8', timeout=30)
        output = process.stdout + process.stderr
        (args.output / 'clean-addon.log').write_text(output)
        if process.returncode != 0 or MARKER not in output or 'ERROR:' in output:
            raise ValueError('clean addon failed; see clean-addon.log')
    report = {'passed': True, 'entries': entries, 'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
              'command': command, 'engine_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
              'exit': process.returncode, 'marker': MARKER,
              'limits': 'Addon-only candidate, one native tick and two-peer byte handshake; not a supported release or browser networking gate.'}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'files': len(entries), 'results': str(receipt)}))


if __name__ == '__main__':
    main()
