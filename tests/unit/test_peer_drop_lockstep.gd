extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=lockstep departure freezes the departed slot at its confirmed frontier and keeps playing;
# fails_when=rollback_floor above the confirmed frontier rejects the last-survivor freeze; why_new=existing lockstep coverage freezes the core directly; seam=none

const SURVIVOR: int = 1
const DEPARTED: int = 0


func cases() -> PackedStringArray:
	return PackedStringArray(["lockstep_departure"])


func run_case(_name: String, context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 0, 2)
	_play_lockstep(context, mesh, 6)
	var before: int = mesh.peers[SURVIVOR].status().current_frame
	var confirmed: int = mesh.peers[SURVIVOR].status().confirmed_frame
	context.equal(confirmed, before - 1, "lockstep confirms exactly one frame behind the frontier")
	var floor: int = mesh.peers[SURVIVOR]._core.rollback_floor()
	context.equal(floor, before, "lockstep retains nothing below its current frame")
	_wait_for_silence(context, mesh, 500000)
	context.equal(mesh.peers[SURVIVOR].status().lifecycle, Types.Lifecycle.RUNNING, "a lockstep survivor keeps running after its peer departs")
	context.equal(mesh.peers[SURVIVOR]._core.frozen_frame(DEPARTED), confirmed, "the departed slot freezes at the confirmed frontier")
	context.equal(mesh.reasons.has("missing_history"), false, "the freezable confirmed row is not reported missing")
	for frame: int in range(before, before + 4):
		var stepped: Driver.StepResult = mesh.peers[SURVIVOR].step(mesh.now + 1000 * (frame - before + 1), _inputs(mesh, SURVIVOR))
		context.equal(stepped.code, Types.Code.OK, "the lockstep survivor keeps advancing on the frozen row")
		context.equal(mesh.peers[SURVIVOR].status().current_frame, frame + 1, "each lockstep frame advances once")
	context.finish()


func _inputs(mesh: Dictionary, peer: int) -> Array[Driver.LocalInput]:
	var result: Array[Driver.LocalInput] = []
	var frame: int = mesh.peers[peer].status().current_frame
	result.append(Driver.LocalInput.new(peer, frame, _sample(peer, frame)))
	return result


func _play_lockstep(context: RefCounted, mesh: Dictionary, frames: int) -> void:
	for frame: int in range(frames):
		var advanced: bool = false
		for _attempt: int in range(100):
			mesh.now += 1000
			for peer: int in range(2):
				var code: int = mesh.peers[peer].step(mesh.now, _inputs(mesh, peer)).code
				context.equal(code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "lockstep step advances or waits for the peer row")
			for _exchange: int in range(2):
				_deliver(context, mesh, _drain(mesh))
			if mesh.peers[0].status().current_frame > frame and mesh.peers[1].status().current_frame > frame:
				advanced = true
				break
		context.equal(advanced, true, "both peers complete lockstep frame %d" % frame)


func _wait_for_silence(context: RefCounted, mesh: Dictionary, elapsed: int) -> void:
	var waited: int = 0
	while waited < elapsed:
		mesh.now += 1000
		waited += 1000
		var polled: int = mesh.peers[SURVIVOR].poll(mesh.now)
		if polled == I.Code.TERMINATED:
			return
		context.equal(polled, I.Code.OK, "poll the lockstep survivor")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if packet.to == SURVIVOR and packet.from == SURVIVOR:
				packets.append(packet)
		_deliver(context, mesh, packets)
