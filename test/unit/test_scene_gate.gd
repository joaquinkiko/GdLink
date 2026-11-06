extends GutTest

var gate: SceneGate

func before_each() -> void:
	gate = SceneGate.new()

func _begin(members: Array[int]) -> void:
	gate.begin_swap("arena", {&"mode": 1}, members)

func test_begin_increments_epoch() -> void:
	_begin([1] as Array[int])
	gate.close()
	_begin([1] as Array[int])
	assert_eq(gate.epoch, 2)

func test_empty_member_set_is_complete_immediately() -> void:
	_begin([] as Array[int])
	assert_true(gate.is_complete())

func test_confirm_clears_pending_and_completes() -> void:
	_begin([1, 4] as Array[int])
	assert_true(gate.confirm(1, 1))
	assert_false(gate.is_complete())
	assert_true(gate.confirm(4, 1))
	assert_true(gate.is_complete())

func test_duplicate_confirm_ignored() -> void:
	_begin([1, 4] as Array[int])
	assert_true(gate.confirm(4, 1))
	assert_false(gate.confirm(4, 1))

func test_wrong_epoch_confirm_ignored() -> void:
	_begin([4] as Array[int])
	assert_false(gate.confirm(4, 9))
	assert_true(gate.is_pending(4))

func test_confirm_before_begin_ignored() -> void:
	assert_false(gate.confirm(4, 1))

func test_remove_last_pending_peer_completes() -> void:
	_begin([1, 4] as Array[int])
	gate.confirm(1, 1)
	assert_true(gate.remove_peer(4))
	assert_true(gate.is_complete())

func test_args_are_copied() -> void:
	var args := {&"mode": 1}
	gate.begin_swap("arena", args, [1] as Array[int])
	args[&"mode"] = 99
	assert_eq(gate.current_args[&"mode"], 1)

func test_close_clears_barrier() -> void:
	_begin([1, 4] as Array[int])
	gate.close()
	assert_false(gate.is_open)
	assert_false(gate.is_pending(4))
