extends RefCounted


## Preserve number spelling and object key identity before Godot JSON discards them.
static func validate(text: String, unsigned_numbers: bool = false) -> String:
	var objects: Array[Dictionary] = []
	var index: int = 0
	while index < text.length():
		var character: String = text[index]
		if character == '"':
			var start: int = index
			var escaped: bool = false
			index += 1
			while index < text.length():
				character = text[index]
				if escaped:
					escaped = false
				elif character == "\\":
					escaped = true
				elif character == '"':
					break
				index += 1
			if index == text.length():
				return "invalid bundle"
			var following: int = index + 1
			while following < text.length() and text[following] in [" ", "\t", "\r", "\n"]:
				following += 1
			if following < text.length() and text[following] == ":":
				var parser: JSON = JSON.new()
				if objects.is_empty() or parser.parse(text.substr(start, index - start + 1)) != OK or not parser.data is String:
					return "invalid bundle"
				var keys: Dictionary = objects.back()
				if keys.has(parser.data):
					return "duplicate object key"
				keys[parser.data] = true
		elif character == "{":
			objects.append({})
		elif character == "}":
			if objects.is_empty():
				return "invalid bundle"
			objects.pop_back()
		elif character in ["-", "+", "."] or "0123456789".contains(character):
			var start: int = index
			while index < text.length() and text[index] not in [" ", "\t", "\r", "\n", ",", "]", "}"]:
				index += 1
			var token: String = text.substr(start, index - start)
			if not _integer_spelling(token):
				return "invalid integer token"
			if unsigned_numbers and token.begins_with("-"):
				return "invalid unsigned token"
			continue
		index += 1
	return ""


## JSON integer grammar permits a minus; unsigned consumers reject it separately.
static func _integer_spelling(token: String) -> bool:
	var start: int = 1 if token.begins_with("-") else 0
	if start == token.length():
		return false
	if token[start] == "0" and token.length() - start > 1:
		return false
	for index: int in range(start, token.length()):
		if not "0123456789".contains(token[index]):
			return false
	return true
