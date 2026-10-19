extends SceneTree

const After = preload("res://addons/fortress_rollback/core/input_queue.gd")
const FRAMES: int = 4000
const REPEATS: int = 7



# Control reproduces the pre-optimization production append, with the same surrounding queue.
class Before:
	extends "res://addons/fortress_rollback/core/input_queue.gd"

	func _append(frame: int, bytes: PackedByteArray, reclaim_floor: int) -> void:
		if _length == _capacity:
			if _tail_frame == reclaim_floor:
				_reclaimed_frame = _tail_frame
				_reclaimed_bytes = _slots[_tail_frame % _capacity].duplicate()
			_tail_frame += 1
			_length -= 1
		var index: int = frame % _capacity
		_frames[index] = frame
		for offset: int in range(bytes.size()):
			_slots[index][offset] = bytes[offset]
		_length += 1
		_last_added = frame
		_last_actual = bytes.duplicate()
		if _prediction_frame != -1:
			if _first_incorrect == -1 and _prediction_bytes != bytes:
				_first_incorrect = frame
			if _prediction_frame == _last_requested and _first_incorrect == -1:
				_prediction_frame = -1
			else:
				# FRAME_MAX + 1 is private episode bookkeeping, never a public frame.
				_prediction_frame = frame + 1


func _initialize() -> void:
	var reports: Array[Dictionary] = []
	for players: int in [2, 4, 8]:
		for width: int in [1, 8, 32, 256]:
			var before_times: Array[int] = []
			var after_times: Array[int] = []
			var expected: int = -1
			for repeat: int in range(REPEATS):
				# Reverse execution order on alternate samples to reduce order bias.
				for candidate: int in ([0, 1] if repeat % 2 == 0 else [1, 0]):
					var report: Dictionary = workload(Before if candidate == 0 else After, players, width)
					if report.is_empty():
						quit(3)
						return
					if expected == -1:
						expected = report.checksum
					if report.checksum != expected:
						push_error("checksum mismatch")
						quit(1)
						return
					if candidate == 0:
						before_times.append(report.usec)
					else:
						after_times.append(report.usec)
			var cold_before: int = before_times[0]
			var cold_after: int = after_times[0]
			before_times.sort()
			after_times.sort()
			reports.append({"players": players, "width": width, "frames": FRAMES, "checksum": expected,
				"before_us": before_times, "after_us": after_times, "cold_before_us": cold_before, "cold_after_us": cold_after})
	print(JSON.stringify({"engine": Engine.get_version_info().string, "reports": reports}))
	quit()

func workload(implementation: GDScript, players: int, width: int) -> Dictionary:
	var queues: Array[RefCounted] = []
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(width)
	bytes.fill(7)
	for player: int in range(players):
		var queue: RefCounted = implementation.new()
		if queue.configure(64, bytes) != 0:
			push_error("queue configuration failed")
			return {}
		queues.append(queue)
	var checksum: int = 0
	var start: int = Time.get_ticks_usec()
	for frame: int in range(FRAMES):
		for player: int in range(players):
			bytes[0] = (frame + player) & 255
			var queue: RefCounted = queues[player]
			if queue.add_input_with_reclaim_floor(frame, bytes, maxi(0, frame - 64)).code != 0:
				push_error("queue append failed")
				return {}
			var result: RefCounted = queue.input(frame)
			checksum += result.bytes[0] + result.bytes[width - 1] + result.status + result.frame
	return {"usec": Time.get_ticks_usec() - start, "checksum": checksum}
