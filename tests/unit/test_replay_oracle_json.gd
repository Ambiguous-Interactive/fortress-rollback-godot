extends RefCounted

# Value: protects=raw JSON key identity and integer spelling; fails_when=parse erases duplicates/types; why_new=recording schema is flat; seam=none
const Tokens = preload("res://tests/oracle/replay_json_tokens.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["preserves_object_scopes_and_strings", "rejects_raw_token_aliases"])


func run_case(name: String, context: RefCounted) -> void:
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
