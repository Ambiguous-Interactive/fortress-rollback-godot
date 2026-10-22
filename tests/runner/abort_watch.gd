extends RefCounted

# Godot 4.7.2 hands a script error to a custom logger, so the runner can report
# an aborted case as failed. Godot 4.3 has neither the Logger class nor
# OS.add_logger, so the logger source is compiled at runtime: the repository
# never holds a script that the older pinned engine cannot parse, and the
# exported browser build never compiles a logger it does not need.
const LOGGER_SOURCE: String = """extends Logger
var records: Array = []
func _log_error(_function: String, file: String, line: int, code: String, _rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array) -> void:
	if error_type != ERROR_TYPE_SCRIPT:
		return
	records.append({"file": file, "line": line, "message": code})
"""

var _logger: Object = null


func _init() -> void:
	# The class and the method are looked up by name: naming the Logger class in
	# this file would make it unparseable on an engine that has no Logger.
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return
	var script: GDScript = GDScript.new()
	script.source_code = LOGGER_SOURCE
	if script.reload() != OK:
		return
	var instance: Variant = script.new()
	if not instance is Object:
		return
	OS.call("add_logger", instance)
	_logger = instance


## True when this engine hands a script error to a custom logger.
func available() -> bool:
	return _logger != null


## The script errors this engine reported so far, in the order it reported them.
func errors() -> Array:
	if _logger == null:
		return []
	var records: Variant = _logger.get("records")
	return records if records is Array else []
