## Stateless codec for META control messages.
## Layout: type u8, peer u32, key length u8, key UTF-8, value (var_to_bytes).
## Erase omits the value. Snapshot end is the type byte only.
class_name MetaCodec
extends RefCounted

const MAX_KEY_BYTES := 32
const HEADER_BYTES := 6
const MAX_VALUE_BYTES := GdLinkCore.MAX_PAYLOAD_BYTES - HEADER_BYTES - MAX_KEY_BYTES

static func is_valid_key(key: Variant) -> bool:
	return not _key_bytes(key).is_empty()

static func is_valid_value(value: Variant) -> bool:
	return _is_encodable_type(value) and var_to_bytes(value).size() <= MAX_VALUE_BYTES

static func encode_set(message_type: int, peer_identifier: int, key: Variant, value: Variant) -> PackedByteArray:
	if not _is_set_type(message_type) or not is_valid_value(value): return PackedByteArray()
	var message := _encode_header(message_type, peer_identifier, key)
	if not message.is_empty(): message.append_array(var_to_bytes(value))
	return message

static func encode_erase(message_type: int, peer_identifier: int, key: Variant) -> PackedByteArray:
	if not _is_erase_type(message_type): return PackedByteArray()
	return _encode_header(message_type, peer_identifier, key)

static func encode_snapshot_end() -> PackedByteArray:
	return PackedByteArray([GdLinkCore.ControlMessage.META_SNAPSHOT_END])

## Returns {type, peer, key} plus value for set messages. Empty dictionary if malformed.
static func decode(payload: PackedByteArray) -> Dictionary:
	if payload.is_empty(): return {}
	var message_type := payload[0]
	if message_type == GdLinkCore.ControlMessage.META_SNAPSHOT_END:
		return {"type": message_type} if payload.size() == 1 else {}
	if not (_is_set_type(message_type) or _is_erase_type(message_type)): return {}
	if payload.size() < HEADER_BYTES: return {}
	var key_length := payload[5]
	var key_end := HEADER_BYTES + key_length
	if key_length == 0 or key_length > MAX_KEY_BYTES or payload.size() < key_end: return {}
	var result := {
		"type": message_type,
		"peer": payload.decode_u32(1),
		"key": StringName(payload.slice(HEADER_BYTES, key_end).get_string_from_utf8()),
	}
	if _is_erase_type(message_type):
		return result if payload.size() == key_end else {}
	var value_bytes := payload.slice(key_end)
	if value_bytes.is_empty() or value_bytes.size() > MAX_VALUE_BYTES: return {}
	var value: Variant = bytes_to_var(value_bytes)
	if not _is_encodable_type(value): return {}
	result["value"] = value
	return result

static func _encode_header(message_type: int, peer_identifier: int, key: Variant) -> PackedByteArray:
	var key_bytes := _key_bytes(key)
	if key_bytes.is_empty(): return PackedByteArray()
	var message := PackedByteArray()
	message.resize(HEADER_BYTES)
	message[0] = message_type
	message.encode_u32(1, peer_identifier)
	message[5] = key_bytes.size()
	message.append_array(key_bytes)
	return message

static func _key_bytes(key: Variant) -> PackedByteArray:
	if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME: return PackedByteArray()
	var key_bytes := String(key).to_utf8_buffer()
	if key_bytes.is_empty() or key_bytes.size() > MAX_KEY_BYTES: return PackedByteArray()
	return key_bytes

## Rejects objects, callables, signals, RIDs, including nested inside containers.
static func _is_encodable_type(value: Variant) -> bool:
	match typeof(value):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return false
		TYPE_ARRAY:
			for item: Variant in value:
				if not _is_encodable_type(item): return false
		TYPE_DICTIONARY:
			for item_key: Variant in value:
				if not _is_encodable_type(item_key) or not _is_encodable_type(value[item_key]): return false
	return true

static func _is_set_type(message_type: int) -> bool:
	return message_type == GdLinkCore.ControlMessage.META_SERVER_SET \
		or message_type == GdLinkCore.ControlMessage.META_PEER_SET

static func _is_erase_type(message_type: int) -> bool:
	return message_type == GdLinkCore.ControlMessage.META_SERVER_ERASE \
		or message_type == GdLinkCore.ControlMessage.META_PEER_ERASE
