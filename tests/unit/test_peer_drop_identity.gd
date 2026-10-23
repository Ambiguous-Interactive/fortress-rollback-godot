extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: foreign barrier identities cannot freeze a slot; fails_when=one sequence field authorizes a report; why_new=all-phase identity; seam=none


func cases() -> PackedStringArray:
	return PackedStringArray(["report_identity", "abort_identity", "future_prepare", "backfill_identity"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"report_identity":
			_report_identity(context)
		"abort_identity":
			_abort_identity(context)
		"future_prepare":
			_future_prepare(context)
		"backfill_identity":
			_backfill_identity(context)
	context.finish()


func _wrong_fields(mesh: Dictionary) -> Array[Dictionary]:
	var identity: Dictionary = _identity_fields(mesh)
	var result: Array[Dictionary] = []
	for field: String in ["coordinator", "coordinator_generation", "target_set_digest", "operation"]:
		result.append({field: int(identity[field]) + 1})
	var targets: PackedByteArray = identity.data.duplicate()
	targets[1] += 1
	result.append({"data": targets})
	return result


func _report_identity(context: RefCounted) -> void:
	for stage: int in [1, 2]:
		for variant: int in range(5):
			var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
			_play(context, mesh, 6, true)
			_leave(context, mesh, 2)
			# Obtain the local operation before any report can finish the agreement.
			_detect(context, mesh, [0, 1], 402000, false)
			var fields: Dictionary = _wrong_fields(mesh)[variant]
			_detect(context, mesh, [0, 1], 60000, true, [{"phase": 2, "stage": stage, "fields": fields, "replace": true}])
			context.equal(mesh.cuts.is_empty(), true, "a report from another identity cannot complete stage %d variant %d" % [stage, variant])
			_detect(context, mesh, [0, 1], 120000)
			context.equal(mesh.cuts.size(), 2, "valid retries finish the same operation")
			context.equal(mesh.unconfirmed, 0, "identity refusal preserves agreement")
			context.equal(mesh.cuts.get(0, -1), mesh.cuts.get(1, -2), "survivors freeze one frame")


func _invalid_abort(mesh: Dictionary, variant: int) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	fields.merge(_wrong_fields(mesh)[variant], true)
	fields.phase = 5
	fields.reason = 5
	return fields


func _abort_identity(context: RefCounted) -> void:
	for variant: int in range(5):
		var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
		_play(context, mesh, 6, true)
		_leave(context, mesh, 2)
		_detect(context, mesh, [0, 1], 550000, true, [], [{"to": 1, "from": 0, "fields": _invalid_abort.bind(mesh, variant)}])
		context.equal(mesh.unconfirmed, 0, "a foreign abort cannot cancel the operation variant %d" % variant)
		context.equal(mesh.cuts.size(), 2, "the real operation completes")
		context.equal(mesh.cuts.get(0, -1), mesh.cuts.get(1, -2), "foreign abort preserves one cut")


func _future_prepare_fields(mesh: Dictionary) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	fields.operation = int(fields.operation) + 1
	return fields


func _future_prepare(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	_detect(context, mesh, [0, 1], 600000, true, [], [{"to": 1, "from": 0, "fields": _future_prepare_fields.bind(mesh)}])
	context.equal(mesh.unconfirmed, 0, "an invented future operation cannot replace the derived operation")
	context.equal(mesh.cuts.size(), 2, "the actual operation still commits")


func _invalid_backfill(mesh: Dictionary, variant: int) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	if variant < 5:
		fields.merge(_wrong_fields(mesh)[variant], true)
	fields.phase = 3
	fields.chunk_count = 1
	fields.bytes = PackedByteArray([99, 0, 0, 0])
	return fields


func _backfill_identity(context: RefCounted) -> void:
	for variant: int in range(6):
		var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 4)
		_play(context, mesh, 6, true)
		_leave(context, mesh, 2)
		var sender: int = 1 if variant == 5 else 0
		_detect(context, mesh, [0, 1, 3], 600000, true, [], [{"to": 3, "from": sender, "fields": _invalid_backfill.bind(mesh, variant)}], true)
		context.equal(mesh.unconfirmed, 0, "a foreign backfill cannot replace the frozen value variant %d" % variant)
		context.equal(mesh.cuts.size(), 3, "all survivors finish the valid operation")
		for survivor: int in [0, 1, 3]:
			context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "foreign backfill leaves the game running")
