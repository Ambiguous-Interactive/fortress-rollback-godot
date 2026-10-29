extends RefCounted

# Value: protects=reusable fixed-width input reads and lifetime; fails_when=copy aliases or ignores expiry; why_new=read allocates owned result wrappers; seam=none
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


class ReusingGame:
	extends Fixture.Game
	var sample: PackedByteArray = PackedByteArray([0])

	func simulate_frame(frame: int, inputs: RefCounted) -> bool:
		trace.append("advance:%d" % frame)
		retained_inputs = inputs
		for player: int in range(inputs.player_count()):
			if inputs.read_into(player, sample) != Types.Code.OK:
				return false
			value = value * 3 + sample[0] + frame
		return true


class StatusGame:
	extends Fixture.Game
	var sample: PackedByteArray = PackedByteArray([0])
	var reusable: bool = false
	var observed: PackedInt32Array = PackedInt32Array()

	func simulate_frame(frame: int, inputs: RefCounted) -> bool:
		trace.append("advance:%d" % frame)
		retained_inputs = inputs
		for player: int in range(inputs.player_count()):
			var status: int
			if reusable:
				status = inputs.input_status(player)
				if status < 0 or inputs.read_into(player, sample) != Types.Code.OK:
					return false
			else:
				var owned: Types.InputResult = inputs.read(player)
				if owned.code != Types.Code.OK:
					return false
				status = owned.status
				sample = owned.bytes
			observed.append(status)
			value = value * 3 + sample[0] + frame + (101 if status == Queue.Status.DISCONNECTED else 0)
		return true


func cases() -> PackedStringArray:
	return PackedStringArray(["copy", "validation", "driver_parity", "status", "status_driver", "malformed_statuses"])


func run_case(name: String, context: RefCounted) -> void:
	var view: RefCounted = Types.FrameInputs.new()
	var available: bool = view.has_method("player_count") and view.has_method("read_into")
	if name in ["status", "status_driver"]:
		available = available and view.has_method("input_status")
	context.equal(available, true, "reusable input access exists")
	if available:
		call("_" + name, context)
	context.finish()


func _view(width: int = 2) -> RefCounted:
	var first: PackedByteArray = PackedByteArray()
	first.resize(width)
	first.fill(3)
	var second: PackedByteArray = first.duplicate()
	second.fill(7)
	return Types.FrameInputs.new([first, second], PackedInt32Array([0, 1]))


func _copy(context: RefCounted) -> void:
	for width: int in [1, 2, 65536]:
		var view: RefCounted = _view(width)
		var destination: PackedByteArray = PackedByteArray()
		destination.resize(width)
		context.equal(view.player_count(), 2, "live view exposes player count")
		for player: int in range(2):
			context.equal(view.read_into(player, destination), Types.Code.OK, "copy into existing destination")
			context.bytes_equal(destination, view.read(player).bytes, player, "reusable copy equals owned read")
			destination.fill(99)
			context.equal(view.read(player).bytes[0], 3 if player == 0 else 7, "destination never edits authoritative inputs")
		context.equal(view.read(1).status, 1, "owned read retains input status")


func _validation(context: RefCounted) -> void:
	var view: RefCounted = _view()
	for player: int in [-1, 2, 2147483647]:
		var destination: PackedByteArray = PackedByteArray([8, 9])
		context.equal(view.read_into(player, destination), Types.Code.INVALID_PLAYER, "invalid player rejected")
		context.bytes_equal(destination, PackedByteArray([8, 9]), 0, "invalid player preserves destination")
	for width: int in [0, 1, 3]:
		var destination: PackedByteArray = PackedByteArray()
		destination.resize(width)
		destination.fill(8)
		var before: PackedByteArray = destination.duplicate()
		context.equal(view.read_into(0, destination), Types.Code.INPUT_WIDTH, "exact destination width required")
		context.bytes_equal(destination, before, 0, "wrong width preserves destination")
	view._expire()
	context.equal(view.player_count(), -1, "expired player count cannot resemble a live view")
	var destination: PackedByteArray = PackedByteArray([8, 9])
	context.equal(view.read_into(0, destination), Types.Code.EXPIRED_VIEW, "expired read fails")
	context.equal(view.read_into(-1, PackedByteArray()), Types.Code.EXPIRED_VIEW, "expiry precedes other validation")
	context.bytes_equal(destination, PackedByteArray([8, 9]), 0, "expired read preserves destination")


func _driver_parity(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var original: RefCounted = Fixture.Game.new()
	var reused: ReusingGame = ReusingGame.new()
	var original_driver: Driver = Driver.new(fixture._session(), original)
	var reused_driver: Driver = Driver.new(fixture._session(), reused)
	for frame: int in range(14):
		context.equal(original_driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "owned-read control advances")
		context.equal(reused_driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "reusable-read driver advances")
		context.equal(reused.value, original.value, "same state through rollback bursts")
		context.equal(reused.trace, original.trace, "same ordered callbacks")
		context.equal(reused.retained_inputs.player_count(), -1, "driver expires reusable view")
		context.equal(reused.retained_inputs.read_into(0, reused.sample), Types.Code.EXPIRED_VIEW, "retained reusable view fails after callback")


# Value: protects=status-sensitive reusable input access; fails_when=status is lost or stale; why_new=copy parity ignores disconnected status; seam=none
func _status(context: RefCounted) -> void:
	var source: PackedInt32Array = PackedInt32Array([Queue.Status.NONE, Queue.Status.CONFIRMED, Queue.Status.PREDICTED, Queue.Status.DISCONNECTED])
	var view: RefCounted = Types.FrameInputs.new([PackedByteArray([1]), PackedByteArray([2]), PackedByteArray([3]), PackedByteArray([4])], source)
	source.fill(99)
	for player: int in range(4):
		context.equal(view.input_status(player), player, "scalar applied status preserves owned source")
		context.equal(view.input_status(player), view.read(player).status, "scalar status matches owned read")
	for player: int in [-1, 4, 2147483647]:
		context.equal(view.input_status(player), -1, "invalid slot has no applied status")
	view._expire()
	for player: int in [-1, 0, 4]:
		context.equal(view.input_status(player), -1, "expired view has no applied status")


func _status_driver(context: RefCounted) -> void:
	var games: Array[StatusGame] = [StatusGame.new(), StatusGame.new()]
	var sessions: Array[Session] = []
	var drivers: Array[Driver] = []
	for index: int in range(2):
		var config: Config = Config.new()
		config.sync_test = false
		config.local_players = PackedInt32Array([0])
		config.check_distance = 0
		config.max_prediction_frames = 4
		config.history_slots = 5
		config.max_snapshot_bytes = 8
		config.storage_budget_bytes = config.required_storage_bytes()
		var session: Session = Session.new()
		context.equal(session.configure(config), Types.Code.OK, "status-sensitive session configured")
		sessions.append(session)
		games[index].reusable = index == 1
		drivers.append(Driver.new(session, games[index]))
	for frame: int in range(3):
		for driver: Driver in drivers:
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([frame + 1]))]
			context.equal(driver.step(frame, samples).code, Types.Code.OK, "predict remote neutral bytes")
	for session: Session in sessions:
		context.equal(session.receive_input(1, 0, PackedByteArray([0])).code, Types.Code.OK, "matching initial remote input")
		context.equal(session.freeze_player(1, 0), Types.Code.OK, "drop changes status while preserving bytes")
		context.equal(session.status().pending_rollback_frame, 1, "status change schedules actual correction")
	for driver: Driver in drivers:
		context.equal(driver.recover(3).code, Types.Code.OK, "repair status-sensitive prediction")
	for frame: int in range(3, 8):
		for driver: Driver in drivers:
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([frame + 1]))]
			context.equal(driver.step(frame + 1, samples).code, Types.Code.OK, "continue disconnected slot through queue wrap")
		context.equal(games[1].value, games[0].value, "scalar status and owned reads simulate identical states")
		context.equal(games[1].observed, games[0].observed, "all callback statuses agree")
		context.equal(games[1].retained_inputs.input_status(1), -1, "driver expires scalar status with callback")
	var expected: int = 0
	for frame: int in range(8):
		expected = (expected * 3 + frame + 1 + frame) * 3 + frame + (101 if frame > 0 else 0)
	context.equal(games[1].value, expected, "independent status-sensitive original history")
	context.equal(Queue.Status.PREDICTED in games[1].observed, true, "prediction status actually observed")
	context.equal(Queue.Status.DISCONNECTED in games[1].observed, true, "disconnected status actually observed")
	context.equal("load:1" in games[1].trace, true, "repair invokes real load callback")


# Value: protects=constructed views reject incomplete statuses; fails_when=read indexes past metadata;
# why_new=session views always have complete statuses; seam=none
func _malformed_statuses(context: RefCounted) -> void:
	for statuses: PackedInt32Array in [PackedInt32Array(), PackedInt32Array([1, 2, 3])]:
		var view: RefCounted = Types.FrameInputs.new([PackedByteArray([1]), PackedByteArray([2])], statuses)
		for player: int in range(2):
			var read: Types.InputResult = view.read(player)
			context.equal(read.code, Types.Code.INVALID_CONFIGURATION, "inconsistent status storage is rejected")
			context.equal(read.bytes.is_empty(), true, "rejected owned read publishes no bytes")
			var destination: PackedByteArray = PackedByteArray([99])
			context.equal(view.read_into(player, destination), Types.Code.INVALID_CONFIGURATION, "reusable reads share shape validation")
			context.equal(destination, PackedByteArray([99]), "malformed view preserves destination")
