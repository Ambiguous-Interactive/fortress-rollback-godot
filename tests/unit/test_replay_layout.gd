extends RefCounted

# Value: protects=short and narrow windows retain replay controls and visible failed gameplay; fails_when=the controls push the game below the viewport;
# why_new=viewer scene tests inspect actions but never their viewport bounds; seam=none
const Scene = preload("res://examples/online/replay.tscn")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["responsive_controls"])


func run_case(_name: String, context: RefCounted) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var original_size: Vector2i = tree.root.size
	for dimensions: Vector2i in [Vector2i(960, 540), Vector2i(640, 360), Vector2i(1280, 720)]:
		tree.root.size = dimensions
		var node: Node2D = Scene.instantiate()
		tree.root.add_child(node)
		if not node.is_node_ready():
			node._ready()
		for failed: bool in [false, true]:
			var recording: RefCounted = Fixture.recording(24)
			if failed:
				recording._inputs[14] ^= 1
			context.equal(node.viewer.open_bytes(recording.to_bytes()), true, "layout fixture imports")
			if failed:
				node.viewer.seek(24)
				node.viewer.tick()
				context.equal(node.viewer.has_failure(), true, "long diagnostic text belongs to actual playback failure")
			node._refresh()
			var controls: ScrollContainer = node.get_node_or_null("ReplayControls") as ScrollContainer
			context.equal(controls != null, true, "replay actions have a bounded scrolling viewport")
			if controls == null:
				continue
			context.equal(controls.follow_focus, true, "keyboard focus reveals offscreen actions")
			context.equal(controls.get_child(0), node._panel, "all existing controls remain in scrollable content")
			var bounds: Rect2 = controls.get_global_rect()
			context.equal(bounds.end.x <= dimensions.x, true, "narrow windows keep horizontal scrolling within the viewport")
			context.equal(bounds.end.y + 100.0 < dimensions.y, true, "diagnostic controls leave at least 100px for game inspection")
			context.equal(node._panel.get_combined_minimum_size().y > controls.size.y, true, "full controls remain available beyond the visible region")
			context.equal(Fixture._button(node, "Restart").disabled, false, "restart remains available after a visible failure")
			context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
		node.free()
	tree.root.size = original_size
	context.finish()
