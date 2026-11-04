extends GutTest

const KEY := "hp"

func test_control_message_values_are_stable() -> void:
	assert_eq(GdLinkCore.ControlMessage.META_SERVER_SET, 3)
	assert_eq(GdLinkCore.ControlMessage.META_SNAPSHOT_END, 7)
	assert_eq(GdLinkCore.HOST_PEER_IDENTIFIER, 1)

func test_key_accepts_string_and_stringname() -> void:
	assert_true(MetaCodec.is_valid_key("hp"))
	assert_true(MetaCodec.is_valid_key(&"hp"))

func test_key_rejects_empty_long_and_wrong_type() -> void:
	assert_false(MetaCodec.is_valid_key(""))
	assert_false(MetaCodec.is_valid_key("x".repeat(MetaCodec.MAX_KEY_BYTES + 1)))
	assert_false(MetaCodec.is_valid_key(42))

func test_key_at_cap_is_accepted() -> void:
	assert_true(MetaCodec.is_valid_key("x".repeat(MetaCodec.MAX_KEY_BYTES)))

func test_set_round_trip_preserves_fields() -> void:
	var values: Array = [42, 1.5, &"name", Vector2(1, 2), [1, "a"], {"gold": 10}]
	for value: Variant in values:
		var decoded := MetaCodec.decode(MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, 5, KEY, value))
		assert_eq(decoded["type"], GdLinkCore.ControlMessage.META_PEER_SET)
		assert_eq(decoded["peer"], 5)
		assert_eq(decoded["key"], &"hp")
		assert_eq(decoded["value"], value)

func test_erase_round_trip_has_no_value() -> void:
	var decoded := MetaCodec.decode(MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_SERVER_ERASE, 0, KEY))
	assert_eq(decoded["key"], &"hp")
	assert_false(decoded.has("value"))

func test_snapshot_end_round_trip() -> void:
	assert_eq(MetaCodec.decode(MetaCodec.encode_snapshot_end())["type"], GdLinkCore.ControlMessage.META_SNAPSHOT_END)

func test_encode_set_rejects_erase_type() -> void:
	assert_true(MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_ERASE, 0, KEY, 1).is_empty())

func test_encode_erase_rejects_set_type() -> void:
	assert_true(MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_PEER_SET, 0, KEY).is_empty())

func test_encode_rejects_bad_key() -> void:
	assert_true(MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, "", 1).is_empty())
	assert_true(MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, "x".repeat(33), 1).is_empty())

func test_value_rejects_objects_including_nested() -> void:
	assert_false(MetaCodec.is_valid_value(RefCounted.new()))
	assert_false(MetaCodec.is_valid_value([RefCounted.new()]))
	assert_false(MetaCodec.is_valid_value({"a": RefCounted.new()}))

func test_value_rejects_oversize() -> void:
	assert_false(MetaCodec.is_valid_value("x".repeat(4100)))
	assert_true(MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, KEY, "x".repeat(4100)).is_empty())

func test_decode_rejects_empty_and_unknown_type() -> void:
	assert_true(MetaCodec.decode(PackedByteArray()).is_empty())
	assert_true(MetaCodec.decode(PackedByteArray([99])).is_empty())

func test_decode_rejects_truncated_header() -> void:
	assert_true(MetaCodec.decode(PackedByteArray([GdLinkCore.ControlMessage.META_PEER_SET, 0, 0, 0, 0])).is_empty())

func test_decode_rejects_zero_length_key() -> void:
	var payload := PackedByteArray([GdLinkCore.ControlMessage.META_PEER_SET, 0, 0, 0, 0, 0])
	payload.append_array(var_to_bytes(1))
	assert_true(MetaCodec.decode(payload).is_empty())

func test_decode_rejects_key_over_cap() -> void:
	var payload := PackedByteArray([GdLinkCore.ControlMessage.META_PEER_SET, 0, 0, 0, 0, 33])
	payload.append_array("x".repeat(33).to_utf8_buffer())
	payload.append_array(var_to_bytes(1))
	assert_true(MetaCodec.decode(payload).is_empty())

func test_decode_rejects_set_without_value() -> void:
	var payload := MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_PEER_ERASE, 0, KEY)
	payload[0] = GdLinkCore.ControlMessage.META_PEER_SET
	assert_true(MetaCodec.decode(payload).is_empty())

func test_decode_rejects_erase_with_trailing_bytes() -> void:
	var payload := MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_PEER_ERASE, 0, KEY)
	payload.append(0)
	assert_true(MetaCodec.decode(payload).is_empty())

func test_decode_rejects_snapshot_with_trailing_bytes() -> void:
	assert_true(MetaCodec.decode(PackedByteArray([GdLinkCore.ControlMessage.META_SNAPSHOT_END, 0])).is_empty())
