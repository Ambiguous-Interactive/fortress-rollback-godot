extends "res://tests/unit/test_webrtc_mesh_backlog.gd"

func cases() -> PackedStringArray:
	return PackedStringArray(["default_single", "default_batched", "readiness_boundary", "aborted_wait"])

func run_case(name: String, context: RefCounted) -> void:
	if name == "aborted_wait":
		var witness: AbortedFixture = AbortedFixture.new()
		var result: Dictionary = witness._run(context, 8, 1, 8)
		context.equal(result.frames, 0, "failed gameplay wait submits no input")
		context.equal(witness.wait_checks > 0, true, "failure control reaches actual gameplay readiness checks")
		context.equal(witness.services_after_check, 0, "failed gameplay wait skips final-confirmation service")
		context.finish()
		return
	if name == "readiness_boundary":
		var witness: BoundaryFixture = BoundaryFixture.new()
		var result: Dictionary = witness._run(context, 8, 2, 8)
		context.equal(result.frames, 2, "boundary control advances its real peer input")
		context.equal(witness.ready_staged_waits > 0, true, "ready wait observes actual undelivered packets")
		context.equal(witness.ready_wait_flushes, 0, "ready gameplay wait returns before host delivery yield")
		context.equal(witness.ready_final_flushes, 0, "ready confirmation returns before host delivery yield")
		context.finish()
		return
	# Value: protects=default eight-peer starvation control; fails_when=slow yields hide retry ACK backlog; why_new=slow_mesh raises sends; seam=render delivery queue
	if name == "default_single":
		var single: Dictionary = _run(context, 8, 16, 1)
		print("SINGLE_BACKLOG_CONTROL ", JSON.stringify(single))
		context.equal(single.backlog > 128, true, "single service accumulates stale physical packets")
		context.equal(single.confirmed.min() < 15, true, "single service misses the original input log deadline")
		context.finish()
		return
	# Value: protects=default eight-peer scheduling; fails_when=wait yields before draining retry ACK work; why_new=slow_mesh raises sends; seam=render delivery queue
	var batched: Dictionary = _run(context, 8, 16, 8)
	print("BATCHED_BACKLOG_CONTROL ", JSON.stringify(batched))
	context.equal(batched.frames, 16, "default composed budgets finish with bounded batching")
	context.equal(batched.backlog < 128, true, "batched receive work bounds physical backlog")
	for received: int in batched.received:
		context.equal(received, 15, "every peer receives original sixteen-frame log")
	for confirmed: int in batched.confirmed:
		context.equal(confirmed, 15, "every peer confirms original sixteen-frame log")
	context.finish()

# Value: protects=host yield ordering; fails_when=ready waits flush deferred packets; why_new=backlog counts alone omit chronology; seam=fixture delivery observer
class BoundaryFixture:
	extends "res://tests/unit/test_webrtc_mesh_backlog.gd"
	var observed_ready: bool = false
	var ready_wait_flushes: int = 0
	var ready_frame: int = -1
	var ready_staged_waits: int = 0
	var ready_final_flushes: int = 0

	func _received(links: Array[Dictionary], frame: int) -> bool:
		observed_ready = super._received(links, frame)
		ready_frame = links[0].peer.status().current_frame
		if observed_ready:
			for link: Dictionary in links:
				if not link.mesh.transport.staged.is_empty():
					ready_staged_waits += 1
					break
		return observed_ready

	func _flush(links: Array[Dictionary]) -> int:
		if observed_ready and links[0].peer.status().current_frame == ready_frame:
			ready_wait_flushes += 1
		var confirmed: bool = true
		for link: Dictionary in links:
			if link.peer.status().confirmed_frame < 1: confirmed = false
		if confirmed: ready_final_flushes += 1
		return super._flush(links)

# Value: protects=failed gameplay return; fails_when=confirmation services an aborted game; why_new=ready control never aborts; seam=fixture readiness refusal
class AbortedFixture:
	extends "res://tests/unit/test_webrtc_mesh_backlog.gd"
	var wait_checks: int = 0
	var services_after_check: int = 0

	func _received(_links: Array[Dictionary], _frame: int) -> bool:
		wait_checks += 1
		services_after_check = 0
		return false

	func _service(context: RefCounted, links: Array[Dictionary], now: int) -> void:
		if wait_checks > 0: services_after_check += 1
		super._service(context, links, now)
