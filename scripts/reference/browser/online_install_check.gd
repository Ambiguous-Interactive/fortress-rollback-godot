extends SceneTree

# Value: protects=clean install without SDK; fails_when=missing runtime files or hard SDK dependency; why_new=root tests have repository files; seam=none
const Online = preload("res://examples/online/online.tscn")
const Offline = preload("res://examples/offline/offline.tscn")


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	if ResourceLoader.exists("res://addons/signal_fish/signal_fish_client.gd"):
		_fail("SDK unexpectedly present")
		return
	var online: Node2D = Online.instantiate()
	root.add_child(online)
	online.set_physics_process(false)
	online.create_button.pressed.emit()
	var message: String = online._status.text
	if not "SignalFish SDK is missing" in message or not "docs/online-example.md" in message or online.controller.client != null:
		online.free()
		_fail("Missing SDK guidance was not displayed")
		return
	online.free()
	var offline: Node2D = Offline.instantiate()
	root.add_child(offline)
	offline.set_physics_process(false)
	for frame: int in 24:
		offline._physics_process(1.0 / 60.0)
		if offline._code != 0 or offline._simulation.frame != frame + 1:
			offline.free()
			_fail("Local rollback game could not advance without SDK")
			return
	var canonical: String = offline._simulation.canonical_bytes().hex_encode()
	offline.free()
	var info: Dictionary = Engine.get_version_info()
	var identity: String = "%d.%d.%d.%s %s" % [info.major, info.minor, info.patch, info.status, info.hash]
	print("FORTRESS_CLEAN_INSTALL:" + JSON.stringify({"missing_sdk_message": message, "offline_frame": 24, "offline_state": canonical, "engine_identity": identity}))
	quit()


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
