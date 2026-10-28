extends RefCounted

# Value: protects=trimmed captured replays verify their own final state; fails_when=prefix export discards its recorded endpoint checksum;
# why_new=terminal tests only reject inheriting the original later endpoint; seam=none
const Fixture = preload("res://tests/unit/test_replay_final_coverage.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["captured_prefix_evidence", "prefix_evidence_boundaries", "incomplete_prefix_digests", "incomplete_prefix_storage"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "captured_prefix_evidence":
		_captured_prefix_evidence(context)
	elif name == "incomplete_prefix_storage":
		_incomplete_prefix_storage(context)
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
		var complete_digests: PackedByteArray = source._digests.duplicate()
		source._digests.resize(retained_bytes)
		var original: PackedByteArray = source._digests.duplicate()
		for boundary: int in [0, 1, 2, 4, 5]:
			var prefix: Replay = source.owned_prefix(boundary)
			var expected: PackedByteArray = original.slice(0, mini(boundary, 4) * Replay.DIGEST_BYTES)
			context.equal(prefix._digests, expected, "prefix keeps only original digest bytes")
			var complete: bool = expected.size() == prefix.frame_count() * Replay.DIGEST_BYTES
			context.equal(not prefix.to_bytes().is_empty(), complete, "only complete retained evidence can be exported")
			for expert: bool in [false, true]:
				for paused: bool in [false, true]:
					var player: Player = Player.new()
					var game: Simulation = Simulation.new()
					var code: int = player.configure_expert(prefix, Simulation.SNAPSHOT_BYTES) if expert else player.configure(prefix, game, Simulation.SNAPSHOT_BYTES)
					context.equal(code, Types.Code.OK, "incomplete digest remains a playback-owned failure")
					for frame: int in mini(retained_bytes / Replay.DIGEST_BYTES, prefix.frame_count()):
						context.equal(Fixture.new()._dispatch(player, game) if expert else player.step(), Types.Code.OK, "complete digest rows remain playable")
					if not complete:
						var before: PackedByteArray = game.canonical_bytes()
						var missing: int = retained_bytes / Replay.DIGEST_BYTES
						var actual: PackedByteArray = complete_digests.slice(missing * Replay.DIGEST_BYTES, (missing + 1) * Replay.DIGEST_BYTES)
						if paused:
							code = player.begin_validate_current_frame().code if expert else player.validate_current_frame()
						else:
							code = Fixture.new()._dispatch(player, game) if expert else player.step()
						context.equal(code, Types.Code.DESYNC, "first incomplete digest stops playback")
						context.equal(player.failure_frame(), missing, "failure identifies first incomplete row")
						context.equal(player.failure_kind(), -1, "missing digest fails before dispatching a request")
						context.equal(player.failure_comparison(), "input_digest_missing", "missing digest is distinct from a content mismatch")
						context.equal(player.failure_expected_checksum(), PackedByteArray(), "missing digest cannot fabricate expected evidence")
						context.equal(player.failure_actual_checksum(), actual, "missing digest keeps independently computed row evidence")
						context.bytes_equal(game.canonical_bytes(), before, missing, "digest rejection does not consume input or alter state")
						var returned: PackedByteArray = player.failure_actual_checksum()
						returned.fill(0)
						player.terminate()
						context.equal(player.begin_advance().code, Types.Code.DESYNC, "termination preserves the original digest failure")
						context.equal(player.failure_comparison(), "input_digest_missing", "termination preserves the missing-digest domain")
						context.equal(player.failure_actual_checksum(), actual, "computed evidence is owned and first-cause stable")
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


# Value: protects=trimming cannot fabricate missing gameplay or state evidence; fails_when=prefix padding repairs malformed source storage;
# why_new=digest coverage does not exercise input, status, flag or checksum truncation; seam=none
func _incomplete_prefix_storage(context: RefCounted) -> void:
	for captured: bool in [false, true]:
		for field: String in ["_inputs", "_statuses", "_flags", "_checksums"]:
			var unit: int = Replay.CHECKSUM_BYTES if field == "_checksums" else (1 if field == "_flags" else 2)
			for retained_bytes: int in [0, unit - 1, unit, unit + 1, 4 * unit - 1, 4 * unit]:
				var source: Replay = Fixture.new()._recording(4, captured)
				var original: PackedByteArray = source.get(field)
				original.resize(retained_bytes)
				source.set(field, original.duplicate())
				if field in ["_flags", "_checksums"]:
					for frame: int in 4:
						var available: bool = retained_bytes >= (frame + 1) * unit
						context.equal(source.checksum(frame).size(), Replay.CHECKSUM_BYTES if available else 0, "partial state evidence is unavailable")
				for boundary: int in [0, 1, 2, 4, 5]:
					var prefix: Replay = source.owned_prefix(boundary)
					var frames: int = mini(boundary, 4)
					var expected: PackedByteArray = original.slice(0, frames * unit)
					context.equal(prefix.get(field), expected, field + " prefix cannot add missing bytes")
					var complete: bool = expected.size() == frames * unit
					context.equal(prefix.is_valid(), complete, field + " incomplete storage remains invalid")
					context.equal(not prefix.to_bytes().is_empty(), complete, field + " incomplete storage cannot export")
					for expert: bool in [false, true]:
						var player: Player = Player.new()
						var game: Simulation = Simulation.new()
						var code: int = player.configure_expert(prefix, Simulation.SNAPSHOT_BYTES) if expert else player.configure(prefix, game, Simulation.SNAPSHOT_BYTES)
						context.equal(code, Types.Code.OK if complete else Types.Code.INVALID_CONFIGURATION, field + " missing storage cannot configure playback")
					context.equal(source.get(field), original, field + " prefix leaves source storage unchanged")
	_incomplete_terminal_evidence(context)


# Value: protects=terminal checksum reads expose only complete v6 evidence; fails_when=malformed or historical terminal bytes leak;
# why_new=ordinary checksum-row truncation does not reach the terminal branch; seam=none
func _incomplete_terminal_evidence(context: RefCounted) -> void:
	for frames: int in [0, 4]:
		for version: int in [4, 5, Replay.TERMINAL_VERSION]:
			for retained_bytes: int in [0, 1, 15, 16, 17]:
				var source: Replay = Fixture.new()._recording(frames, true)
				source._format_version = version
				source._terminal_checksum.resize(retained_bytes)
				if version == 4:
					for frame: int in frames:
						var digest: PackedByteArray = source.computed_input_digest(frame)
						for index: int in Replay.DIGEST_BYTES:
							source._digests[frame * Replay.DIGEST_BYTES + index] = digest[index]
				var original: PackedByteArray = source._terminal_checksum.duplicate()
				var available: bool = version == Replay.TERMINAL_VERSION and retained_bytes == Replay.CHECKSUM_BYTES
				var expected: PackedByteArray = original if available else PackedByteArray()
				var prefix: Replay = source.owned_prefix(frames)
				var checksum: PackedByteArray = source.checksum(frames)
				context.equal(checksum, expected, "terminal read requires complete v6 evidence")
				context.equal(prefix.checksum(frames), expected, "full prefix cannot promote malformed terminal evidence")
				checksum.fill(0)
				context.equal(source._terminal_checksum, original, "terminal reads and prefixes preserve owned source bytes")
				context.equal(prefix._terminal_checksum, original, "full prefix preserves malformed source storage for validation")
				var valid: bool = available if version == Replay.TERMINAL_VERSION else retained_bytes == 0
				context.equal(source.is_valid(), valid, "source validity still rejects malformed terminal storage")
				context.equal(not prefix.to_bytes().is_empty(), valid, "full prefix cannot export malformed terminal storage")
