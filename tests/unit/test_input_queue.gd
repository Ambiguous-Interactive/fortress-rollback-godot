extends RefCounted

# Value: protects=delay/prediction/ring ownership; fails_when=gap, episode or bounds drift;
# why_new=first production queue; seam=none
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["delay", "prediction", "ring", "validation", "ownership", "reclaim", "reclaim_delay"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"delay":
			_delay(context)
		"prediction":
			_prediction(context)
		"ring":
			_ring(context)
		"validation":
			_validation(context)
		"ownership":
			_ownership(context)
		"reclaim":
			_reclaim(context)
		"reclaim_delay":
			_reclaim_delay(context)
	context.finish()


func _delay(context: RefCounted) -> void:
	for delay: int in [0, 1, 3]:
		var queue: RefCounted = Queue.new()
		context.equal(queue.configure(8, PackedByteArray([0])), Queue.Code.OK, "configure")
		context.equal(queue.set_frame_delay(delay), Queue.Code.OK, "initial delay")
		context.equal(queue.add_input(0, PackedByteArray([9])).frame, delay, "scheduled")
		for frame: int in range(delay):
			context.bytes_equal(queue.confirmed_input(frame).bytes, PackedByteArray([0]), frame, "neutral gap")
		context.equal(queue.set_frame_delay(delay + 2), Queue.Code.OK, "increase")
		for frame: int in range(delay + 1, delay + 3):
			context.bytes_equal(queue.confirmed_input(frame).bytes, PackedByteArray([9]), frame, "repeat gap")
		context.equal(queue.set_frame_delay(delay), Queue.Code.DELAY_DECREASE_UNSUPPORTED, "decrease")
		context.equal(queue.add_input(1, PackedByteArray([7])).frame, delay + 3, "sample after increase")


func _prediction(context: RefCounted) -> void:
	var queue: RefCounted = Queue.new()
	queue.configure(8, PackedByteArray([0]))
	context.equal(queue.input(4).status, Queue.Status.PREDICTED, "virgin predicts future")
	queue.add_input(0, PackedByteArray([9]))
	context.equal(queue.first_incorrect_frame(), 0, "episode starts earliest missing")
	context.equal(queue.input(0).code, Queue.Code.PREDICTION_MISMATCH, "refuse even confirmed reads")
	context.equal(queue.confirmed_input(0).code, Queue.Code.OK, "confirmed bypasses mismatch")
	queue.reset_prediction()
	context.equal(queue.first_incorrect_frame(), -1, "reset mismatch")
	context.equal(queue.input(0).status, Queue.Status.CONFIRMED, "reset reads actual")
	context.bytes_equal(queue.input(3).bytes, PackedByteArray([9]), 3, "repeat latest")
	queue.add_input(1, PackedByteArray([9]))
	context.equal(queue.input(1).status, Queue.Status.PREDICTED, "episode stays frozen for confirmed query")
	queue.add_input(2, PackedByteArray([8]))
	queue.add_input(3, PackedByteArray([7]))
	context.equal(queue.first_incorrect_frame(), 2, "earliest mismatch preserved")
	queue.reset_prediction()
	context.bytes_equal(queue.input(4).bytes, PackedByteArray([7]), 4, "reset refreshes base")
	queue.add_input(4, PackedByteArray([7]))
	context.equal(queue.input(4).status, Queue.Status.CONFIRMED, "matching last requested ends episode")


func _ring(context: RefCounted) -> void:
	var queue: RefCounted = Queue.new()
	queue.configure(3, PackedByteArray([0]))
	for frame: int in range(3):
		context.equal(queue.add_input(frame, PackedByteArray([frame])).code, Queue.Code.OK, "fill")
	context.equal(queue.add_input(3, PackedByteArray([3])).code, Queue.Code.CAPACITY, "full rejects")
	queue.input(1)
	queue.discard_confirmed_frames(3)
	context.equal(queue.input(0).code, Queue.Code.BEFORE_RETAINED, "discard clamps last request")
	context.equal(queue.confirmed_input(0).code, Queue.Code.OK, "physical tag until overwritten")
	context.equal(queue.add_input(3, PackedByteArray([3])).code, Queue.Code.OK, "retry after discard")
	context.equal(queue.confirmed_input(0).code, Queue.Code.NO_CONFIRMED_INPUT, "overwritten tag")
	queue.reset_prediction()
	queue.discard_confirmed_frames(100)
	for frame: int in range(4, 7):
		context.equal(queue.add_input(frame, PackedByteArray([frame])).code, Queue.Code.OK, "wrap")
		queue.reset_prediction()
		queue.discard_confirmed_frames(frame)
		context.bytes_equal(queue.input(frame).bytes, PackedByteArray([frame]), frame, "wrapped tag")


func _validation(context: RefCounted) -> void:
	var queue: RefCounted = Queue.new()
	context.equal(queue.input(0).code, Queue.Code.NOT_CONFIGURED, "unconfigured")
	for capacity: int in [-1, 0, 1, 2147483647]:
		context.equal(queue.configure(capacity, PackedByteArray([0])), Queue.Code.INVALID_CONFIGURATION, "capacity bounds")
	context.equal(queue.configure(4, PackedByteArray()), Queue.Code.INVALID_CONFIGURATION, "zero width")
	var wide: PackedByteArray = PackedByteArray()
	wide.resize(Queue.MAX_INPUT_BYTES + 1)
	context.equal(queue.configure(2, wide), Queue.Code.INVALID_CONFIGURATION, "width allocation limit")
	wide.resize(Queue.MAX_INPUT_BYTES)
	context.equal(queue.configure(Queue.MAX_CAPACITY, wide), Queue.Code.INVALID_CONFIGURATION, "total allocation limit")
	queue.configure(4, PackedByteArray([0]))
	context.equal(queue.input(Queue.FRAME_MAX).status, Queue.Status.PREDICTED, "last public frame")
	context.equal(queue.add_input(Queue.FRAME_MAX, PackedByteArray([0])).code, Queue.Code.CAPACITY, "huge initial gap bounded")
	context.equal(queue.first_incorrect_frame(), -1, "rejected gap preserves prediction")
	queue.reset_prediction()
	for frame: int in [-2, -1, 2147483648, 9223372036854775807]:
		context.equal(queue.add_input(frame, PackedByteArray([1])).code, Queue.Code.FRAME_RANGE, "add range")
		context.equal(queue.input(frame).code, Queue.Code.FRAME_RANGE, "read range")
		context.equal(queue.confirmed_input(frame).code, Queue.Code.FRAME_RANGE, "confirmed range")
	context.equal(queue.discard_confirmed_frames(-1), Queue.Code.OK, "null discard")
	context.equal(queue.add_input(0, PackedByteArray()).code, Queue.Code.INPUT_WIDTH, "width")
	context.equal(queue.add_input(4, PackedByteArray([1])).code, Queue.Code.CAPACITY, "initial gap atomic")
	context.equal(queue.add_input(0, PackedByteArray([1])).frame, 0, "retry after initial rejection")
	for frame: int in [0, 2]:
		context.equal(queue.add_input(frame, PackedByteArray([1])).code, Queue.Code.OUT_OF_ORDER, "duplicate/skipped")
	for delay: int in [-1, 4, 9223372036854775807]:
		context.equal(queue.set_frame_delay(delay), Queue.Code.INVALID_CONFIGURATION, "delay bounds")
	queue.add_input(1, PackedByteArray([2]))
	queue.add_input(2, PackedByteArray([3]))
	context.equal(queue.set_frame_delay(2), Queue.Code.CAPACITY, "setter atomic")
	context.equal(queue.frame_delay(), 0, "setter preserves delay")
	context.equal(queue.confirmed_input(3).code, Queue.Code.NO_CONFIRMED_INPUT, "no partial fill")
	context.equal(queue.add_input(3, PackedByteArray([4])).frame, 3, "delay unchanged on rejection")
	context.equal(queue.configure(1, PackedByteArray([0])), Queue.Code.INVALID_CONFIGURATION, "invalid reconfigure")
	context.bytes_equal(queue.confirmed_input(3).bytes, PackedByteArray([4]), 3, "state survives invalid reconfigure")


func _ownership(context: RefCounted) -> void:
	var queue: RefCounted = Queue.new()
	var neutral: PackedByteArray = PackedByteArray([0, 1])
	queue.configure(4, neutral)
	neutral[0] = 99
	context.bytes_equal(queue.input(0).bytes, PackedByteArray([0, 1]), 0, "neutral ownership")
	queue.reset_prediction()
	var submitted: PackedByteArray = PackedByteArray([2, 3])
	queue.add_input(0, submitted)
	submitted[0] = 99
	var returned: RefCounted = queue.input(0)
	returned.bytes[0] = 99
	context.bytes_equal(queue.confirmed_input(0).bytes, PackedByteArray([2, 3]), 0, "submit/read ownership")
	var prediction: RefCounted = queue.input(1)
	prediction.bytes[0] = 99
	context.bytes_equal(queue.input(2).bytes, PackedByteArray([2, 3]), 2, "prediction ownership")

	# Native slot replacement must preserve ownership across wide samples, wrap and the rollback floor.
	for width: int in [1, 8, 32, 256]:
		var source: PackedByteArray = PackedByteArray()
		source.resize(width)
		source.fill(7)
		var expected: PackedByteArray = source.duplicate()
		queue.configure(3, source)
		for frame: int in range(3):
			context.equal(queue.add_input(frame, source).code, Queue.Code.OK, "wide owned append")
		var retained: RefCounted = queue.confirmed_input(0)
		source.fill(99)
		context.bytes_equal(queue.input(3).bytes, expected, 3, "latest actual owns submitted bytes")
		context.equal(queue.add_input_with_reclaim_floor(3, expected, 0).code, Queue.Code.OK, "wide ring wraps")
		retained.bytes.fill(88)
		expected.fill(77)
		var seven: PackedByteArray = PackedByteArray()
		seven.resize(width)
		seven.fill(7)
		context.bytes_equal(queue.retained_confirmed_input(0).bytes, seven, 0, "reclaimed floor owns old slot")
		context.bytes_equal(queue.confirmed_input(3).bytes, seven, 3, "wrapped slot owns new submission")
		queue.reset_prediction()
		context.bytes_equal(queue.input(4).bytes, seven, 4, "wrapped latest prediction owns bytes")


# Value: protects=global floor history and frozen episode; fails_when=local progress evicts floor; why_new=ordinary full ring rejects; seam=none
func _reclaim(context: RefCounted) -> void:
	for capacity: int in [3, 4]:
		var queue: RefCounted = Queue.new()
		queue.configure(capacity, PackedByteArray([0]))
		queue.add_input(0, PackedByteArray([1]))
		queue.add_input(1, PackedByteArray([1]))
		queue.input(capacity)
		for frame: int in range(2, capacity + 2):
			context.equal(queue.add_input_with_reclaim_floor(frame, PackedByteArray([frame]), 1).code, Queue.Code.OK, "global floor append")
		context.equal(queue.first_incorrect_frame(), 2, "local mismatch later than global floor")
		context.equal(queue.input(1).code, Queue.Code.PREDICTION_MISMATCH, "floor does not bypass mismatch")
		context.bytes_equal(queue.retained_confirmed_input(1).bytes, PackedByteArray([1]), 1, "global floor retained")
		context.equal(queue.add_input_with_reclaim_floor(capacity + 2, PackedByteArray([9]), 1).code, Queue.Code.CAPACITY, "newer tail protected")
		context.equal(queue.first_incorrect_frame(), 2, "rejection preserves mismatch")
		queue.reset_prediction()
		context.equal(queue.input(capacity + 2).status, Queue.Status.PREDICTED, "fresh episode")
		context.equal(queue.input(1).status, Queue.Status.CONFIRMED, "side slot bypasses active prediction")
		queue.discard_confirmed_frames(100)
		context.equal(queue.retained_confirmed_input(1).code, Queue.Code.OK, "discard clamps to floor request")
		queue.reset_prediction()
		queue.discard_confirmed_frames(100)
		context.equal(queue.retained_confirmed_input(1).code, Queue.Code.BEFORE_RETAINED, "discard drops side slot")
		context.equal(queue.confirmed_input(capacity).code, Queue.Code.OK, "physical stale ring tag")
		context.equal(queue.retained_confirmed_input(capacity).code, Queue.Code.BEFORE_RETAINED, "stale tag is not recoverable")
		for frame: int in range(capacity + 2, capacity * 4):
			context.equal(queue.add_input_with_reclaim_floor(frame, PackedByteArray([frame]), frame - capacity).code, Queue.Code.OK, "repeated nonpower wrap")
			context.bytes_equal(queue.retained_confirmed_input(frame).bytes, PackedByteArray([frame]), frame, "wrapped actual")
		queue.configure(capacity, PackedByteArray([0]))
		context.equal(queue.confirmed_input(1).code, Queue.Code.NO_CONFIRMED_INPUT, "configure clears side slot")


# Value: protects=atomic reclaim delay and floor validation; fails_when=partial gap evicts before failure; why_new=reclaim setters; seam=none
func _reclaim_delay(context: RefCounted) -> void:
	var queue: RefCounted = Queue.new()
	queue.configure(3, PackedByteArray([0]))
	for frame: int in range(3):
		queue.add_input(frame, PackedByteArray([7]))
	queue.input(4)
	context.equal(queue.set_frame_delay_with_reclaim_floor(2, 0), Queue.Code.CAPACITY, "failed gap is atomic")
	context.equal(queue.frame_delay(), 0, "failed gap preserves delay")
	context.equal(queue.first_incorrect_frame(), -1, "failed gap preserves prediction")
	context.equal(queue.input(0).status, Queue.Status.PREDICTED, "failed gap did not create side slot")
	context.equal(queue.retained_confirmed_input(0).code, Queue.Code.OK, "failed gap retains ring")
	context.equal(queue.set_frame_delay_with_reclaim_floor(2, 1), Queue.Code.OK, "safe gap reclaims")
	context.equal(queue.input(1).status, Queue.Status.CONFIRMED, "floor is actual during episode")
	context.equal(queue.frame_delay(), 2, "successful gap sets delay")
	context.equal(queue.add_input_with_reclaim_floor(3, PackedByteArray([7]), 1).code, Queue.Code.CAPACITY, "protected tail after delay")
	context.equal(queue.add_input_with_reclaim_floor(3, PackedByteArray([7]), 2).frame, 5, "retry newer global floor")
	context.equal(queue.retained_confirmed_input(1).code, Queue.Code.BEFORE_RETAINED, "replaced old floor")
	for floor_frame: int in [-1, -2, 2147483648, 9223372036854775807]:
		context.equal(queue.add_input_with_reclaim_floor(4, PackedByteArray([7]), floor_frame).code, Queue.Code.FRAME_RANGE, "invalid add floor")
		context.equal(queue.set_frame_delay_with_reclaim_floor(2, floor_frame), Queue.Code.FRAME_RANGE, "invalid unchanged delay floor")
	context.bytes_equal(queue.retained_confirmed_input(2).bytes, PackedByteArray([7]), 2, "invalid floor preserves side")
	context.equal(queue.add_input_with_reclaim_floor(6, PackedByteArray([7]), 5).code, Queue.Code.OUT_OF_ORDER, "skip cannot reclaim")
	context.equal(queue.add_input_with_reclaim_floor(4, PackedByteArray(), 5).code, Queue.Code.INPUT_WIDTH, "bad width cannot reclaim")
	context.equal(queue.set_frame_delay_with_reclaim_floor(1, 5), Queue.Code.DELAY_DECREASE_UNSUPPORTED, "decrease cannot reclaim")
	var owned: RefCounted = queue.retained_confirmed_input(2)
	owned.bytes[0] = 99
	context.bytes_equal(queue.confirmed_input(2).bytes, PackedByteArray([7]), 2, "returned side owns bytes")
	context.equal(queue.add_input_with_reclaim_floor(4, PackedByteArray([8]), 5).code, Queue.Code.OK, "advance floor beyond oldest")
	context.equal(queue.confirmed_input(2).code, Queue.Code.OK, "noncontiguous side is physically present")
	context.equal(queue.retained_confirmed_input(2).code, Queue.Code.BEFORE_RETAINED, "noncontiguous side is not recovery")
	queue.reset_prediction()
	context.equal(queue.input(2).status, Queue.Status.CONFIRMED, "raw Rust input can inspect noncontiguous side")
	var wide: PackedByteArray = PackedByteArray()
	wide.resize(Queue.MAX_INPUT_BYTES)
	context.equal(queue.configure(256, wide), Queue.Code.INVALID_CONFIGURATION, "budget includes side slot")
	context.equal(queue.retained_confirmed_input(4).code, Queue.Code.OK, "invalid budget preserves queue")
	queue.configure(3, PackedByteArray([0]))
	context.equal(queue.add_input_with_reclaim_floor(Queue.FRAME_MAX, PackedByteArray([7]), Queue.FRAME_MAX).code, Queue.Code.CAPACITY, "reclaim startup stays bounded")
	context.equal(queue.confirmed_input(0).code, Queue.Code.NO_CONFIRMED_INPUT, "failed startup preserves empty queue")
	context.equal(queue.add_input_with_reclaim_floor(0, PackedByteArray([7]), 0).frame, 0, "retry atomic startup")
