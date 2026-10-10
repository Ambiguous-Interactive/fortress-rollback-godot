extends RefCounted

# Assertions stay active in release exports. JSON records deliberately use strings
# for seeds and bytes so browser consumers cannot truncate wide integers.
var seed: int
var is_complete: bool = false
var assertions: int = 0
var failures: Array[Dictionary] = []
var states: Array[Dictionary] = []


func _init(fixed_seed: int) -> void:
	seed = fixed_seed


# Variant is intentional: equality assertions accept any test value.
func equal(actual: Variant, expected: Variant, label: String) -> void:
	assertions += 1
	if actual != expected:
		failures.append(
			{"kind": "equality", "label": label, "expected": str(expected), "actual": str(actual)}
		)


func table(rows: Array[Dictionary]) -> void:
	for row: Dictionary in rows:
		if not row.has_all(["actual", "expected", "label"]):
			failures.append({"kind": "invalid_assertion_row"})
		else:
			equal(row["actual"], row["expected"], str(row["label"]))


func bytes_equal(
	actual: PackedByteArray, expected: PackedByteArray, frame: int, label: String
) -> void:
	assertions += 1
	var difference: int = -1
	for index: int in range(mini(actual.size(), expected.size())):
		if actual[index] != expected[index]:
			difference = index
			break
	if difference < 0 and actual.size() != expected.size():
		difference = mini(actual.size(), expected.size())
	if difference >= 0:
		failures.append(
			{
				"kind": "bytes",
				"label": label,
				"frame": frame,
				"byte": difference,
				"expected": expected.hex_encode(),
				"actual": actual.hex_encode()
			}
		)


func state(frame: int, canonical_bytes: PackedByteArray) -> void:
	states.append({"frame": frame, "bytes": canonical_bytes.hex_encode()})


func finish() -> void:
	if is_complete:
		failures.append({"kind": "duplicate_completion"})
	is_complete = true
