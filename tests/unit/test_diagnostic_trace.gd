extends RefCounted

# Value: protects=owned bounded divergence evidence; fails_when=trace changes simulation or exports identities;
# why_new=counter diagnostics omit canonical payloads; seam=none
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["owned_window", "disabled_equality", "bounds", "failed_callback", "local_divergence"])


func run_case(name: String, context: RefCounted) -> void:
	var session: Session = Session.new()
	context.equal(session.has_method("diagnostic_trace"), true, "canonical diagnostic trace API exists")
	if not session.has_method("diagnostic_trace"):
		context.finish()
		return
	if name == "bounds":
		_bounds(context)
	else:
		_run(context, name)
	context.finish()


func _config(enabled: bool) -> Config:
	var config: Config = Config.new()
	config.max_snapshot_bytes = 8
	config.max_prediction_frames = 2
	config.check_distance = 2
	config.history_slots = 3
	config.storage_budget_bytes = 65536
	config.set("diagnostic_trace_frames", 3 if enabled else 0)
	config.set("diagnostic_seed", "1701")
	config.set("diagnostic_version", "fixture-v1")
	config.set("diagnostic_replay_command", "fixture --seed 1701")
	return config


func _run(context: RefCounted, name: String) -> void:
	var config: Config = _config(name != "disabled_equality")
	var session: Session = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "configure trace")
	var game: RefCounted = Fixture.Game.new()
	var driver: Driver = Driver.new(session, game)
	var other: Session = Session.new()
	context.equal(other.configure(_config(false)), Types.Code.OK, "configure disabled reference")
	var reference: RefCounted = Fixture.Game.new()
	var other_driver: Driver = Driver.new(other, reference)
	var fixture: RefCounted = Fixture.new()
	for frame: int in range(9):
		var expected_code: int = other_driver.step(frame, fixture._samples(frame)).code
		context.equal(driver.step(frame, fixture._samples(frame)).code, expected_code, "trace preserves callback outcome")
		context.equal(game.value, reference.value, "trace preserves canonical simulation")
		context.equal(game.trace, reference.trace, "trace never adds game callbacks")
	if name == "local_divergence":
		# Corrupt the source comparison baseline without changing the saved local game bytes.
		session._originals[7].bytes[0] ^= 1
		context.equal(driver.step(9, fixture._samples(9)).code, Types.Code.DESYNC, "canonical sync-test mismatch detected")
		var divergence: Dictionary = session.call("diagnostic_trace")
		context.equal(divergence.first_divergence.frame, 7, "local mismatch frame frozen")
		context.equal(divergence.first_divergence.source, "sync_test_snapshot", "canonical mismatch distinct from peer checksum")
		return
	var report: Dictionary = session.call("diagnostic_trace")
	if name == "disabled_equality":
		context.equal(report, {}, "disabled captures no evidence")
		return
	context.equal(report.schema, "fortress-canonical-trace-v1", "versioned canonical trace")
	context.equal(report.seed, "1701", "explicit application seed")
	context.equal(report.application_version, "fixture-v1", "explicit application version")
	context.equal(report.replay_command, "fixture --seed 1701", "application replay command")
	context.equal(report.frames.size(), 3, "strict retained frame bound after rolling and resimulation")
	context.equal(report.frames[0].frame, 6, "window starts at retained boundary")
	context.equal(report.frames[2].frame, 8, "window ends at last completed simulated input")
	for row: Dictionary in report.frames:
		context.equal(row.state.hex_decode().size(), 8, "complete canonical SAVE bytes")
		context.equal(row.inputs.size(), 2, "complete per-player applied input")
		context.equal(row.inputs[0].bytes.hex_decode(), fixture._samples(row.frame)[0].bytes, "original applied input bytes")
	for offset: int in range(report.frames.size() - 1):
		var row: Dictionary = report.frames[offset]
		var replayed: int = row.state.hex_decode().decode_s64(0)
		for input: Dictionary in row.inputs:
			replayed = replayed * 3 + input.bytes.hex_decode()[0] + row.frame
		context.equal(replayed, report.frames[offset + 1].state.hex_decode().decode_s64(0), "independent replay reproduces next canonical saved boundary")
	context.equal(report.retained_payload_bytes <= report.max_payload_bytes, true, "retained payload obeys exact bound")
	context.equal(JSON.stringify(report).to_utf8_buffer().size() <= report.max_export_bytes, true, "compact JSON obeys declared export bound")
	report.frames[0].inputs[0].bytes = "mutated"
	report.frames[0].state = "mutated"
	var fresh: Dictionary = session.call("diagnostic_trace")
	context.equal(fresh.frames[0].state != "mutated" and fresh.frames[0].inputs[0].bytes != "mutated", true, "deep caller ownership")
	if name == "failed_callback":
		game.fail_kind = Types.Kind.ADVANCE
		context.equal(driver.step(9, fixture._samples(9)).code, Types.Code.CALLBACK_FAILED, "failed callback terminates")
		var failed: Dictionary = session.call("diagnostic_trace")
		context.equal(failed.frames[-1].inputs.is_empty(), true, "failed ADVANCE never claims applied input")


func _bounds(context: RefCounted) -> void:
	var config: Config = _config(true)
	config.set("diagnostic_trace_frames", 129)
	context.equal(config.validate(), Types.Code.INVALID_CONFIGURATION, "hard history limit")
	config = _config(true)
	var required: int = config.required_storage_bytes()
	config.storage_budget_bytes = required - 1
	context.equal(config.validate(), Types.Code.INVALID_CONFIGURATION, "trace reservation included in explicit storage budget")
	config.storage_budget_bytes = required
	context.equal(config.validate(), Types.Code.OK, "exact budget accepted")
	config.set("diagnostic_replay_command", "x".repeat(513))
	context.equal(config.validate(), Types.Code.INVALID_CONFIGURATION, "metadata bounded before capture")
