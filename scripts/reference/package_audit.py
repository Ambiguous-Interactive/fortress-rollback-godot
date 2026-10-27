#!/usr/bin/env python3
"""Audit an addon-only candidate in a clean project without development tooling."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

from engine_path import resolve_engine
from receipt_arguments import ReceiptParser

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.package_addon import ADDON, build_archive

ROOT = Path(__file__).resolve().parents[2]
MARKER = 'FORTRESS_ADDON_PACKAGE_OK'
SMOKE = '''extends SceneTree
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Handshake = preload("res://addons/fortress_rollback/protocol/handshake.gd")
const HandshakeTypes = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const InputTypes = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const ProtocolTypes = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
var kinds: Dictionary = {}

class Game:
    extends RefCounted
    var ticks: int = 0
    func save_state(_frame: int, writer: RefCounted) -> Driver.SaveResult:
        writer.write_bytes(PackedByteArray([ticks]))
        var checksum: PackedByteArray = PackedByteArray()
        checksum.resize(16)
        checksum.fill(255)
        checksum.encode_s64(0, ticks)
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

class SpectatorGame:
    extends Game
    func simulate_frame(_frame: int, inputs: RefCounted) -> bool:
        for player: int in range(2):
            var input: RefCounted = inputs.read(player)
            ticks = (ticks * 17 + input.bytes[0] + input.status * 31) % 251
        return true

func _initialize() -> void:
    if not _load_runtime_scripts("res://addons/fortress_rollback"):
        quit(1)
        return
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
    if not _handshake() or not _peer_session() or not _spectator_session():
        quit(1)
        return
    print("FORTRESS_ADDON_PACKAGE_OK")
    quit(0)

func _load_runtime_scripts(path: String) -> bool:
    var directory: DirAccess = DirAccess.open(path)
    if directory == null:
        return false
    for child: String in directory.get_directories():
        if not _load_runtime_scripts(path + "/" + child):
            return false
    for file: String in directory.get_files():
        if file.ends_with(".gd"):
            var script: Script = load(path + "/" + file) as Script
            if script == null or not script.can_instantiate():
                return false
    return true


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
        local.config.desync_interval = 5
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


func _peer_session() -> bool:
    var peers: Array[Peer] = []
    var games: Array[Game] = []
    var roster: Array[PackedByteArray] = [PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0]), PackedByteArray([2, 0, 0, 0, 0, 0, 0, 0])]
    for slot: int in range(2):
        var config: Config = Config.new()
        config.local_players = PackedInt32Array([slot])
        config.sync_test = false
        config.check_distance = 0
        config.max_snapshot_bytes = 1
        config.storage_budget_bytes = 100000
        var local: ProtocolTypes.Message = ProtocolTypes.Message.new()
        local.kind = ProtocolTypes.Kind.SYNC_REQUEST
        local.sender_id = roster[slot].duplicate()
        local.connection_id = roster[slot].duplicate()
        local.session_id.fill(1)
        local.config.roster = roster
        local.config.desync_interval = 5
        var options: HandshakeTypes.Options = HandshakeTypes.Options.new()
        options.roundtrips = 1
        var game: Game = Game.new()
        var peer: Peer = Peer.new()
        if peer.configure(config, local, game, options, InputTypes.Options.new()) != InputTypes.Code.OK:
            return false
        local.token.fill(slot + 1)
        if peer.begin(0, [local.token]) != InputTypes.Code.OK:
            return false
        peers.append(peer)
        games.append(game)
    for tick: int in range(6):
        if not _deliver(peers, roster, tick):
            return false
    for frame: int in range(70):
        var now_us: int = (frame + 1) * 16667
        for slot: int in range(2):
            var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([1]))]
            if peers[slot].step(now_us, samples).code != Types.Code.OK:
                return false
        if not _deliver(peers, roster, now_us) or not _deliver(peers, roster, now_us):
            return false
    if games[0].ticks != 70 or games[1].ticks != 70 or peers[0].status().confirmed_frame < 68:
        return false
    for kind: int in [ProtocolTypes.Kind.QUALITY_REPORT, ProtocolTypes.Kind.QUALITY_REPLY, ProtocolTypes.Kind.CHECKSUM_REPORT]:
        if kinds.get(kind, 0) < 1:
            return false
    for slot: int in range(2):
        peers[slot].poll(3400000)
        var terminal: bool = false
        for event: Dictionary in peers[slot].drain_events():
            terminal = terminal or event.kind == "disconnected"
        var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, 70, PackedByteArray([1]))]
        if not terminal or peers[slot].step(3400000, samples).code != Types.Code.TERMINATED or games[slot].ticks != 70:
            return false
    return true


func _spectator_session() -> bool:
    var config: Config = Config.new()
    config.spectator = true
    config.sync_test = false
    config.local_players = PackedInt32Array()
    config.max_prediction_frames = 0
    config.check_distance = 0
    config.max_snapshot_bytes = 1
    config.storage_budget_bytes = 100000
    config.replay_max_frames = 3
    var session: Spectator = Spectator.new()
    if session.configure(config) != Types.Code.OK:
        return false
    var game: SpectatorGame = SpectatorGame.new()
    var driver: Driver = Driver.new(session, game)
    var empty: Array[Driver.LocalInput] = []
    if driver.step(0, empty).code != Types.Code.PREDICTION_STALL or game.ticks != 0:
        return false
    if session.submit_local_input(0, 0, PackedByteArray([1])).code != Types.Code.UNSUPPORTED:
        return false
    var expected: PackedInt32Array = PackedInt32Array([75, 244, 158])
    for frame: int in range(3):
        var row: Array[PackedByteArray] = [PackedByteArray([frame + 1]), PackedByteArray([frame + 2])]
        var statuses: PackedByteArray = PackedByteArray([1, 1 if frame == 0 else 3])
        if session.receive_host_frame(frame, row, statuses).code != Types.Code.OK:
            return false
        var result: Driver.StepResult = driver.step(frame + 1, empty)
        if result.code != Types.Code.OK or result.frame_after != frame + 1 or game.ticks != expected[frame]:
            return false
    if driver.capture_replay_boundary().code != Types.Code.OK:
        return false
    if session.finish_host() != Types.Code.OK or driver.step(4, empty).code != Types.Code.TERMINATED:
        return false
    var recording: Replay = Replay.new()
    if recording.decode(driver.replay().to_bytes()) != Replay.DecodeCode.OK or recording.frame_count() != 3:
        return false
    if recording.skipped_frames() != 0 or recording.checksum(3).size() != 16:
        return false
    if recording.inputs(1).read(1).status != 3 or recording.inputs(2).read(1).bytes != PackedByteArray([4]):
        return false
    for expert: bool in [false, true]:
        var playback: Player = Player.new()
        var replay_game: SpectatorGame = SpectatorGame.new()
        var code: int = playback.configure_expert(recording, 1) if expert else playback.configure(recording, replay_game, 1)
        if code != Types.Code.OK:
            return false
        for _work: int in range(4):
            if expert:
                if not _replay_requests(playback, replay_game):
                    return false
            elif playback.step() != Types.Code.OK:
                return false
        if not playback.is_complete() or not playback.is_final_state_validated() or replay_game.ticks != expected[2]:
            print("installed_spectator_replay: final state not validated")
            return false
    var corrupt: PackedByteArray = recording.to_bytes()
    corrupt[corrupt.size() - 1] ^= 128
    var broken: Replay = Replay.new()
    if broken.decode(corrupt) != Replay.DecodeCode.OK:
        return false
    for expert: bool in [false, true]:
        var playback: Player = Player.new()
        var replay_game: SpectatorGame = SpectatorGame.new()
        var code: int = playback.configure_expert(broken, 1) if expert else playback.configure(broken, replay_game, 1)
        if code != Types.Code.OK:
            return false
        for _work: int in range(4):
            if expert:
                if not _replay_requests(playback, replay_game):
                    break
            elif playback.step() != Types.Code.OK:
                break
        if playback.failure_code() != Types.Code.DESYNC or playback.failure_frame() != 3 or playback.is_final_state_validated():
            print("installed_spectator_replay: corrupted final checksum accepted")
            return false
    return true


func _replay_requests(playback: Player, game: SpectatorGame) -> bool:
    var opened: Types.Result = playback.begin_advance()
    if opened.code != Types.Code.READY:
        return false
    while true:
        var request: Types.Request = opened.batch.next_request()
        if request == null:
            return true
        var checksum: PackedByteArray = PackedByteArray()
        var ok: bool
        if request.kind == Types.Kind.SAVE:
            var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
            ok = saved.ok
            checksum = saved.checksum
        else:
            ok = game.simulate_frame(request.frame, request.inputs)
        if playback.complete_request(request.batch_id, request.request_id, ok, checksum).code != Types.Code.OK:
            return false
    return true



func _deliver(peers: Array[Peer], roster: Array[PackedByteArray], now_us: int) -> bool:
    for slot: int in range(2):
        for packet: Peer.Packet in peers[slot].drain_outbox():
            var decoded: ProtocolTypes.Result = Codec.decode(packet.bytes, ProtocolTypes.Limits.new())
            if decoded.code != ProtocolTypes.Code.OK:
                return false
            kinds[decoded.message.kind] = kinds.get(decoded.message.kind, 0) + 1
            if peers[1 - slot].receive(packet.bytes, roster[slot], now_us) != InputTypes.Code.OK:
                return false
        peers[slot].drain_events()
        peers[slot].drain_transitions()
    return true
'''


def main():
    parser = ReceiptParser(description=__doc__, receipt='package-audit.json')
    parser.add_argument('--godot', required=True, help='engine name on PATH or a path to it')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'package-audit.json'
    receipt.write_text('{"passed": false, "failure": "in_progress"}\n')
    archive = args.output / 'fortress-addon-candidate.tar'
    files = build_archive(ROOT, archive)
    with tempfile.TemporaryDirectory(prefix='fortress-clean-addon-') as temporary:
        project = Path(temporary)
        with tarfile.open(archive) as package:
            entries = package.getnames()
            if entries != list(files):
                raise ValueError('archive differs from addon allowlist')
            for member in package.getmembers():
                if not member.isfile() or package.extractfile(member).read() != files[member.name]:
                    raise ValueError('archive bytes differ from frozen addon inputs')
            package.extractall(project, filter='data')
        (project / 'project.godot').write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
        (project / 'smoke.gd').write_text(SMOKE)
        # The engine is resolved only once the package itself has passed.
        # A defective candidate must be reported as such, not as a missing
        # engine.
        executable = resolve_engine(args.godot)
        command = [str(executable), '--headless', '--path', str(project), '--script', 'res://smoke.gd']
        process = subprocess.run(command, capture_output=True, encoding='utf-8', timeout=30)
        output = process.stdout + process.stderr
        (args.output / 'clean-addon.log').write_text(output)
        if process.returncode != 0 or MARKER not in output or 'ERROR:' in output:
            raise ValueError('clean addon failed; see clean-addon.log')
    report = {'passed': True, 'entries': entries, 'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
              'command': command, 'engine_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
              'exit': process.returncode, 'marker': MARKER,
              'limits': 'Addon-only candidate: every runtime script loads without SignalFish; one driver tick, 70 two-peer gameplay steps, '
                        'full checksum/quality bytes, terminal timeout and status-sensitive spectator recording with callback/expert final replay validation; '
                        'not a supported release or browser networking gate.'}
    receipt.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'files': len(entries), 'results': str(receipt)}))


if __name__ == '__main__':
    main()
