extends RefCounted

const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")

static func options(scenario: Dictionary) -> L.Options:
	var result: L.Options = L.Options.new()
	result.enabled = scenario.has("lifecycle")
	if result.enabled:
		result.quality_report_interval_us = scenario.lifecycle.quality_us
		result.keepalive_interval_us = scenario.lifecycle.keepalive_us
		result.disconnect_notify_us = scenario.lifecycle.notify_us
		result.disconnect_timeout_us = scenario.lifecycle.timeout_us
	return result

static func wide(bytes: PackedByteArray) -> String:
	var reversed: PackedByteArray = bytes.duplicate()
	reversed.reverse()
	return reversed.hex_encode()

static func semantic(message: T.Message) -> Dictionary:
	match message.kind:
		T.Kind.QUALITY_REPORT:
			return {"kind": "quality_report", "frame_advantage": message.frame_advantage, "ping": wide(message.token)}
		T.Kind.QUALITY_REPLY:
			return {"kind": "quality_reply", "pong": wide(message.token)}
		T.Kind.KEEP_ALIVE:
			return {"kind": "keep_alive"}
		T.Kind.GOODBYE:
			return {"kind": "goodbye", "reason": message.reason}
		T.Kind.CHECKSUM_REPORT:
			return {"kind": "checksum_report", "frame": message.frame, "checksum": message.checksum.hex_encode()}
	return {}

static func metrics(peer: RefCounted, player: int, players: int, now_us: int) -> Dictionary:
	var network: Dictionary = peer.network_status()
	var result: Array[Dictionary] = []
	for remote: int in range(players):
		if remote == player:
			continue
		var item: Dictionary = {"peer": remote, "error": "NotSynchronized"}
		# Source public stats rejects subsecond elapsed time; preserve its API availability.
		if now_us >= 1000000:
			var id: PackedByteArray = PackedByteArray()
			id.resize(8)
			id.encode_u64(0, remote + 1)
			var status: Dictionary = network.peers[id.hex_encode()]
			item = {"peer": remote, "error": null, "ping": status.round_trip_time_ms,
				"local_frames_behind": status.local_frame_advantage, "remote_frames_behind": status.remote_frame_advantage}
		result.append(item)
	return {"frames_ahead": network.frames_ahead, "peers": result}
