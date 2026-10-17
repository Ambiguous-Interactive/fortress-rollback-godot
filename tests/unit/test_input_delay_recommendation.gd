extends RefCounted

# Value: protects=measured input-delay suggestions; fails_when=suggestions flap, exceed the limit, repeat or break agreement; why_new=no suggestion emitter; seam=none
const Advisor = preload("res://addons/fortress_rollback/core/delay_advisor.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const PeerMatch = preload("res://examples/peer/match.gd")
const SUSTAIN: int = Advisor.SUSTAIN_STEPS


func cases() -> PackedStringArray:
	return PackedStringArray(["converts_round_trip", "suggests_from_scripted_round_trip", "peers_apply_suggestions"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"converts_round_trip":
			_converts_round_trip(context)
		"suggests_from_scripted_round_trip":
			_suggests_from_scripted_round_trip(context)
		"peers_apply_suggestions":
			_peers_apply_suggestions(context)
	context.finish()


func _converts_round_trip(context: RefCounted) -> void:
	var rows: Array[Dictionary] = [
		{"label": "zero round trip", "rtt": 0, "fps": 60, "frames": 0},
		{"label": "negative round trip", "rtt": -5, "fps": 60, "frames": 0},
		{"label": "zero fps", "rtt": 100, "fps": 0, "frames": 0},
		{"label": "exactly one frame", "rtt": 33, "fps": 60, "frames": 1},
		{"label": "rounds up past one frame", "rtt": 34, "fps": 60, "frames": 2},
		{"label": "200 ms at 60 fps", "rtt": 200, "fps": 60, "frames": 6},
		{"label": "100 ms at 120 fps", "rtt": 100, "fps": 120, "frames": 6},
		{"label": "largest round trip and fps stay positive", "rtt": 9223372036854775807, "fps": 4294967295, "frames": (Advisor.MAX_ROUND_TRIP_MS * 4294967295 + 1999) / 2000},
	]
	for row: Dictionary in rows:
		context.equal(Advisor.one_way_frames(row.rtt, row.fps), row.frames, row.label)


## "rtt" lists [round_trip_ms, observations] runs. "delays" maps an observation index to the delay
## the game applied before it. "expect" lists [observation index, suggested delay] pairs.
func _suggests_from_scripted_round_trip(context: RefCounted) -> void:
	var rows: Array[Dictionary] = [
		{"label": "no measurement", "rtt": [[0, 200]], "expect": []},
		{"label": "latency the delay already covers", "rtt": [[66, 200]], "expect": []},
		{"label": "steady latency suggests once", "rtt": [[200, 200]], "expect": [[SUSTAIN - 1, 6]]},
		{"label": "spike shorter than the sustain window", "rtt": [[400, SUSTAIN - 1], [50, 200]], "expect": []},
		{"label": "dip restarts the sustain window", "rtt": [[200, SUSTAIN - 1], [0, 1], [200, SUSTAIN]], "expect": [[2 * SUSTAIN - 1, 6]]},
		{"label": "fluctuating latency suggests the window minimum", "rtt": [[400, 20], [200, 1], [400, SUSTAIN]], "expect": [[SUSTAIN - 1, 6]]},
		{"label": "worse latency raises the suggestion", "rtt": [[200, SUSTAIN], [400, SUSTAIN]], "expect": [[SUSTAIN - 1, 6], [2 * SUSTAIN - 1, 12]]},
		{"label": "better latency after a suggestion", "rtt": [[400, SUSTAIN], [200, 200]], "expect": [[SUSTAIN - 1, 12]]},
		{"label": "applied suggestion raises the floor", "rtt": [[200, SUSTAIN], [234, SUSTAIN]], "delays": {SUSTAIN: 6}, "expect": [[SUSTAIN - 1, 6], [2 * SUSTAIN - 1, 8]]},
		{"label": "manual raise above the suggestion", "rtt": [[300, 3 * SUSTAIN]], "delays": {10: 12}, "expect": []},
		{"label": "clamps to the limit", "rtt": [[10000, 3 * SUSTAIN]], "expect": [[SUSTAIN - 1, 63]]},
		{"label": "nothing at the limit", "rtt": [[10000, 200]], "current": 63, "expect": []},
		{"label": "small limit", "rtt": [[400, 200]], "limit": 4, "expect": [[SUSTAIN - 1, 4]]},
		{"label": "largest round trip", "rtt": [[9223372036854775807, 200]], "expect": [[SUSTAIN - 1, 63]]},
		{"label": "several local players", "rtt": [[400, 200]], "locals": 2, "expect": []},
		{"label": "no local sample yet", "rtt": [[400, 200]], "locals": 0, "expect": []},
	]
	for row: Dictionary in rows:
		var advisor: Advisor = Advisor.new()
		var delay: int = row.get("current", 2)
		var delays: Dictionary = row.get("delays", {})
		var observed: Array = []
		var index: int = 0
		for run: Array in row.rtt:
			for _repeat: int in range(run[1]):
				delay = delays.get(index, delay)
				var suggested: int = advisor.observe(row.get("locals", 1), delay, row.get("limit", 63), run[0], 60)
				if suggested != -1:
					observed.append([index, suggested])
				index += 1
		context.equal(observed, row.expect, row.label)


## Two peer sessions over the example's lossy, reordering link. Each peer applies every suggestion it receives.
func _peers_apply_suggestions(context: RefCounted) -> void:
	var largest: int = PeerMatch.Peer.max_input_delay(Config.new())
	var rows: Array[Dictionary] = [
		{"label": "low latency", "latency": 0, "suggests": false},
		{"label": "high latency", "latency": 12, "suggests": true},
	]
	for row: Dictionary in rows:
		var label: String = row.label
		var peers: PeerMatch = PeerMatch.new()
		peers.replay_frames = 600
		peers.latency_ticks = row.latency
		context.equal(peers.reset(), PeerMatch.I.Code.OK, label + " starts")
		var invalid: int = 0
		var applied: Array[int] = [0, 0]
		var last: PackedInt32Array = PackedInt32Array([-1, -1])
		for tick: int in range(600):
			peers.tick(PackedInt32Array([tick % 13 % 16, (tick * 7) % 11 % 16]))
			for player: int in range(2):
				for event: Dictionary in peers.recommendations[player]:
					var current: int = peers.sessions[player].input_delay(player)
					var valid: bool = event.player == player and event.current_delay == current and event.suggested_delay > current
					valid = valid and event.suggested_delay <= largest and event.suggested_delay > last[player] and event.round_trip_time_ms > 0
					invalid += int(not valid)
					last[player] = event.suggested_delay
					applied[player] += int(peers.sessions[player].set_input_delay(player, event.suggested_delay) == Types.Code.OK)
				peers.recommendations[player].clear()
		context.equal(invalid, 0, label + " publishes only bounded, rising suggestions above the current delay")
		context.equal(applied[0] > 0 and applied[1] > 0, row.suggests, label + " suggests a raise to each peer only on a slow link")
		context.equal(peers.failure, PeerMatch.I.Code.OK, label + " has no failure")
		for player: int in range(2):
			context.equal(peers.sessions[player].status().lifecycle, Types.Lifecycle.RUNNING, label + " peer %d keeps running" % player)
			context.equal(peers.event_counts[player].get("desync_detected", 0), 0, label + " peer %d sees no desync" % player)
			var final: int = last[player] if row.suggests else 2
			context.equal(peers.sessions[player].input_delay(player), final, label + " peer %d ends at its last suggestion" % player)
		var first: Replay = peers.sessions[0].replay()
		var second: Replay = peers.sessions[1].replay()
		var common: int = mini(first.frame_count(), second.frame_count())
		var differing: int = 0
		for frame: int in range(common):
			for slot: int in range(2):
				differing += int(first.inputs(frame).read(slot).bytes != second.inputs(frame).read(slot).bytes)
		context.equal(common > 200 and differing == 0, true, label + " records the same inputs on both peers")
		peers.sessions[0].close(peers.now_us + 1)
		peers.sessions[0].drain_events()
		peers.sessions[0].step(peers.now_us + 2, [])
		context.equal(peers.sessions[0].drain_events().size(), 0, label + " publishes nothing after closing")
