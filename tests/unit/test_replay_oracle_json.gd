extends RefCounted

# Value: protects=raw JSON key identity and integer spelling; fails_when=parse erases duplicates/types; why_new=recording schema is flat; seam=none
const Tokens = preload("res://tests/oracle/replay_json_tokens.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["preserves_object_scopes_and_strings", "rejects_raw_token_aliases", "records_load_callbacks"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "records_load_callbacks":
		_records_load(context)
		context.finish()
		return
	if name == "preserves_object_scopes_and_strings":
		for text: String in [
			'{ "key": {"key": 1}, "other": [{"key": 2}, {"key": 3}] }',
			'{"key": "\\\"key\\\": 1.0 \\\\ 2e0 { }", "other": 1}',
			'{"\\u006bey": 1, "other": 2}',
			'[{"key": 1}, {"key": 2}]', '{"key": -2}', '{"key": -0}'
		]:
			context.equal(Tokens.validate(text), "", "valid raw token scopes: " + text)
	else:
		for text: String in [
			'{"key": 1, "key": 2}',
			'{"key": 1, "\\u006bey": 2}',
			'{"outer": [{"key": 1, "\\u006bey": 2}]}',
			'{"outer": {"key": 1, "key": 2}}'
		]:
			context.equal(Tokens.validate(text), "duplicate object key", "duplicate raw token: " + text)
		for text: String in ['{"key": 1.0}', '{"key": 1e0}', '{"key": 1E+0}', '{"key": 02}', '{"key": +2}',
                           '{"key": -}', '{"key": --1}', '{"key": .1}', '{"key": 1.}', '{"key": 1e+}']:
			context.equal(Tokens.validate(text), "invalid integer token", "noninteger spelling: " + text)
		for text: String in ['{"key": -2}', '{"key": -0}']:
			context.equal(Tokens.validate(text, true), "invalid unsigned token", "unsigned policy: " + text)
	context.finish()


# Value: protects=the original observer retains LOAD requests; fails_when=restoration is invisible in service order;
# why_new=all-local positive workloads never request LOAD; seam=none
func _records_load(context: RefCounted) -> void:
	var trace: Script = preload("res://tests/oracle/replay_session_trace.gd")
	var game: RefCounted = trace.Game.new()
	game.state[1] = 1701
	var original: PackedByteArray = game.bytes()
	var reader: RefCounted = preload("res://addons/fortress_rollback/core/snapshot_reader.gd").new(original, true)
	context.equal(game.load_state(0, reader), true, "a redundant original-boundary load succeeds")
	context.equal(reader.is_complete(), true, "the LOAD consumes the complete original snapshot")
	context.equal(game.bytes(), original, "the extra LOAD preserves canonical state")
	context.equal(game.records, [{"kind": "load", "frame": 0, "bytes": original.hex_encode(), "inputs": []}], "the actual LOAD remains visible to exact request comparison")
