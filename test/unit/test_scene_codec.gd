extends GutTest

const EPOCH := 3
const SCENE := "arena"
const ARGS := {&"mode": 2}

func test_set_round_trip() -> void:
	var decoded := SceneCodec.decode(SceneCodec.encode_set(EPOCH, SCENE, ARGS))
	assert_eq(decoded["type"], GdLinkCore.ControlMessage.SCENE_SET)
	assert_eq(decoded["epoch"], EPOCH)
	assert_eq(decoded["scene"], SCENE)
	assert_eq(decoded["args"], ARGS)

func test_confirm_round_trip() -> void:
	for message_type in [GdLinkCore.ControlMessage.SCENE_LOADED, GdLinkCore.ControlMessage.SCENE_READY]:
		var decoded := SceneCodec.decode(SceneCodec.encode_confirm(message_type, EPOCH))
		assert_eq(decoded, {"type": message_type, "epoch": EPOCH})

func test_empty_scene_rejected() -> void:
	assert_true(SceneCodec.encode_set(EPOCH, "", ARGS).is_empty())

func test_oversize_scene_rejected() -> void:
	assert_true(SceneCodec.encode_set(EPOCH, "x".repeat(SceneCodec.MAX_SCENE_BYTES + 1), ARGS).is_empty())

func test_oversize_args_rejected() -> void:
	var args := {&"blob": "x".repeat(SceneCodec.MAX_ARGS_BYTES)}
	assert_true(SceneCodec.encode_set(EPOCH, SCENE, args).is_empty())

func test_encode_confirm_rejects_set_type() -> void:
	assert_true(SceneCodec.encode_confirm(GdLinkCore.ControlMessage.SCENE_SET, EPOCH).is_empty())

func test_decode_rejects_empty_and_truncated() -> void:
	assert_true(SceneCodec.decode(PackedByteArray()).is_empty())
	assert_true(SceneCodec.decode(PackedByteArray([GdLinkCore.ControlMessage.SCENE_SET, 0, 0])).is_empty())

func test_decode_rejects_confirm_with_trailing_byte() -> void:
	var payload := SceneCodec.encode_confirm(GdLinkCore.ControlMessage.SCENE_READY, EPOCH)
	payload.append(0)
	assert_true(SceneCodec.decode(payload).is_empty())

func test_decode_rejects_non_dictionary_args() -> void:
	var payload := SceneCodec.encode_set(EPOCH, SCENE, ARGS)
	payload = payload.slice(0, SceneCodec.SET_HEADER_BYTES + SCENE.length())
	payload.append_array(var_to_bytes([1, 2]))
	assert_true(SceneCodec.decode(payload).is_empty())
