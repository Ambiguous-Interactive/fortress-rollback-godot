extends RefCounted

# Value: protects=trimmed captured replays verify their own final state; fails_when=prefix export discards its recorded endpoint checksum;
# why_new=terminal tests only reject inheriting the original later endpoint; seam=none
const Fixture = preload("res://tests/unit/test_replay_final_coverage.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["captured_prefix_evidence", "prefix_evidence_boundaries", "incomplete_prefix_digests"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "captured_prefix_evidence":
		_captured_prefix_evidence(context)
	elif name == "incomplete_prefix_digests":
		_incomplete_prefix_digests(context)
	else:
		_prefix_evidence_boundaries(context)
	context.finish()


# Value: protects=prefixes preserve incomplete digest evidence; fails_when=trimming fabricates zero-padded digests;
# why_new=prefix tests only use complete recording storage; seam=none
func _incomplete_prefix_digests(context: RefCounted) -> void:
	for retained_bytes: int in [0, 15, 16, 17, 63, 64]:
		var source: Replay = Fixture.new()._recording(4, true)
		source._digests.resize(retained_bytes)
		var original: PackedByteArray = source._digests.duplicate()
		for boundary: int in [0, 1, 2, 4, 5]:
			var prefix: Replay = source.owned_prefix(boundary)
			var expected: PackedByteArray = original.slice(0, mini(boundary, 4) * Replay.DIGEST_BYTES)
			context.equal(prefix._digests, expected, "prefix keeps only original digest bytes")
			var complete: bool = expected.size() == prefix.frame_count() * Replay.DIGEST_BYTES
			context.equal(not prefix.to_bytes().is_empty(), complete, "only complete retained evidence can be exported")
			for expert: bool in [false, true]:
				var player: Player = Player.new()
				var game: Simulation = Simulation.new()
				var code: int = player.configure_expert(prefix, Simulation.SNAPSHOT_BYTES) if expert else player.configure(prefix, game, Simulation.SNAPSHOT_BYTES)
				context.equal(code, Types.Code.OK, "incomplete digest remains a playback-owned failure")
				for frame: int in mini(retained_bytes / Replay.DIGEST_BYTES, prefix.frame_count()):
					context.equal(Fixture.new()._dispatch(player, game) if expert else player.step(), Types.Code.OK, "complete digest rows remain playable")
				if not complete:
					context.equal(Fixture.new()._dispatch(player, game) if expert else player.step(), Types.Code.DESYNC, "first incomplete digest stops playback")
					context.equal(player.failure_frame(), retained_bytes / Replay.DIGEST_BYTES, "failure identifies first incomplete row")
				context.state(game.frame, game.canonical_bytes())
		context.equal(source._digests, original, "prefix generation preserves source digest evidence")


func _captured_prefix_evidence(context: RefCounted) -> void:
	var source: Replay = Fixture.new()._recording(4, true)
	var original: PackedByteArray = source.to_bytes()
	for boundary: int in [0, 1, 3]:
		var expected: Simulation = Simulation.new()
		for frame: int in boundary:
			expected.simulate_frame(frame, source.inputs(frame))
		var checksum: PackedByteArray = Simulation.checksum(expected.canonical_bytes())
		context.equal(source.checksum(boundary), checksum, "source pre-input checksum covers exactly the trimmed final state")
		var prefix: Replay = source.owned_prefix(boundary)
		context.equal(prefix.frame_count(), boundary, "trim keeps exactly the requested input prefix")
		context.equal(prefix.checksum(boundary), checksum, "captured prefix preserves its own endpoint evidence")
		context.equal(prefix.to_bytes().decode_u16(4), Replay.TERMINAL_VERSION, "captured prefix retains terminal format")
		var decoded: Replay = Replay.new()
		context.equal(decoded.decode(prefix.to_bytes()), Replay.DecodeCode.OK, "trimmed terminal bytes decode")
		context.equal(decoded.to_bytes(), prefix.to_bytes(), "trimmed terminal bytes round trip exactly")
		for expert: bool in [false, true]:
			for changed: bool in [false, true]:
				var game: Simulation = Simulation.new()
				var player: Player = Player.new()
				var configured: int = player.configure_expert(decoded, Simulation.SNAPSHOT_BYTES) if expert else player.configure(decoded, game, Simulation.SNAPSHOT_BYTES)
				context.equal(configured, Types.Code.OK, "configure trimmed captured replay")
				for frame: int in boundary:
					context.equal(Fixture.new()._dispatch(player, game) if expert else player.step(), Types.Code.OK, "play unchanged prefix")
				context.bytes_equal(game.canonical_bytes(), expected.canonical_bytes(), boundary, "prefix reconstructs independently calculated state")
				if changed:
					game.rng_state ^= 1
				context.equal(player.is_complete(), false, "terminal evidence awaits its own SAVE")
				var result: int = Fixture.new()._dispatch(player, game) if expert else player.step()
				context.equal(result, Types.Code.DESYNC if changed else Types.Code.OK, "final-only divergence is checked at the trimmed endpoint")
				context.equal(player.is_final_state_validated(), not changed, "only matching final state qualifies")
				if changed:
					context.equal(player.failure_frame(), boundary, "mismatch names the new endpoint")
					context.equal(player.failure_comparison(), "state_checksum", "mismatch is a final-state comparison")
				context.state(boundary, game.canonical_bytes())
	context.equal(source.to_bytes(), original, "trimming leaves the source recording and original final evidence unchanged")
	for boundary: int in [4, 5, 9223372036854775807]:
		context.equal(source.owned_prefix(boundary).to_bytes(), original, "full-length and clamped prefixes preserve original bytes")


func _prefix_evidence_boundaries(context: RefCounted) -> void:
	var source: Replay = Fixture.new()._recording(4, true)
	source._flags[2] = 0
	var prefix: Replay = source.owned_prefix(2)
	context.equal(prefix.checksum(2).is_empty(), true, "absent boundary checksum cannot inherit the original final evidence")
	context.equal(prefix.to_bytes().decode_u16(4), Replay.FORMAT_VERSION, "missing evidence falls back to historical format")
	context.equal(source.owned_prefix(-1).checksum(0), source.checksum(0), "negative prefix clamps to the initial boundary evidence")
	source._checksums[Replay.CHECKSUM_BYTES] ^= 1
	var damaged: Replay = source.owned_prefix(1)
	context.equal(damaged.checksum(1), source.checksum(1), "trim preserves stored checksum evidence instead of recomputing it")
	var checksum: PackedByteArray = damaged.checksum(1)
	checksum.fill(0)
	context.equal(damaged.checksum(1), source.checksum(1), "trimmed terminal checksum remains owned")
	var historical: Replay = Fixture.new()._recording(4, false)
	for version: int in [4, 5]:
		historical._format_version = version
		for frame: int in historical.frame_count():
			var digest: PackedByteArray = historical.computed_input_digest(frame)
			for index: int in Replay.DIGEST_BYTES:
				historical._digests[frame * Replay.DIGEST_BYTES + index] = digest[index]
		var historical_prefix: Replay = historical.owned_prefix(1)
		context.equal(historical_prefix.checksum(1).is_empty(), true, "historical final boundaries do not opt into terminal validation")
		context.equal(historical_prefix.to_bytes().decode_u16(4), version, "historical format remains unchanged")
