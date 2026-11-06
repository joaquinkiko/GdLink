## Stateless codec for scene control messages
class_name SceneCodec
extends RefCounted

const MAX_SCENE_BYTES := 128
const SET_HEADER_BYTES := 6
const CONFIRM_BYTES := 5
const MAX_ARGS_BYTES := GdLinkCore.MAX_PAYLOAD_BYTES - SET_HEADER_BYTES - MAX_SCENE_BYTES

static func is_valid_scene(scene: String) -> bool:
	var scene_bytes := scene.to_utf8_buffer()
	return !scene_bytes.is_empty() && scene_bytes.size() <= MAX_SCENE_BYTES

static func is_valid_args(args: Dictionary) -> bool:
	return MetaCodec.is_valid_value(args) && var_to_bytes(args).size() <= MAX_ARGS_BYTES

static func encode_set(epoch: int, scene: String, args: Dictionary) -> PackedByteArray:
	if not (is_valid_scene(scene) && is_valid_args(args)):
		return PackedByteArray()
	var scene_bytes := scene.to_utf8_buffer()
	var message := PackedByteArray()
	message.resize(SET_HEADER_BYTES)
	message[0] = GdLinkCore.ControlMessage.SCENE_SET
	message.encode_u32(1, epoch)
	message[5] = scene_bytes.size()
	message.append_array(scene_bytes)
	message.append_array(var_to_bytes(args))
	return message

static func encode_confirm(message_type: int, epoch: int) -> PackedByteArray:
	if not _is_confirm_type(message_type):
		return PackedByteArray()
	var message := PackedByteArray()
	message.resize(CONFIRM_BYTES)
	message[0] = message_type
	message.encode_u32(1, epoch)
	return message

## Returns {type, epoch} for confirms, {type, epoch, scene, args} for set. Empty if malformed.
static func decode(payload: PackedByteArray) -> Dictionary:
	if payload.is_empty():
		return {}
	var message_type := payload[0]
	if _is_confirm_type(message_type):
		if payload.size() != CONFIRM_BYTES:
			return {}
		return {
			"type": message_type,
			"epoch": payload.decode_u32(1)
			}
	if message_type != GdLinkCore.ControlMessage.SCENE_SET:
		return {}
	if payload.size() < SET_HEADER_BYTES:
		return {}
	var scene_length := payload[5]
	var scene_end := SET_HEADER_BYTES + scene_length
	if scene_length == 0 || scene_length > MAX_SCENE_BYTES || payload.size() < scene_end:
		return {}
	var scene := payload.slice(SET_HEADER_BYTES, scene_end).get_string_from_utf8()
	var args_bytes := payload.slice(scene_end)
	if scene.is_empty() || args_bytes.is_empty() || args_bytes.size() > MAX_ARGS_BYTES:
		return {}
	var args: Variant = bytes_to_var(args_bytes)
	if not (typeof(args) == TYPE_DICTIONARY && MetaCodec.is_valid_value(args)):
		return {}
	return {
		"type": message_type,
		"epoch": payload.decode_u32(1),
		"scene": scene,
		"args": args
		}

static func _is_confirm_type(message_type: int) -> bool:
	return message_type == GdLinkCore.ControlMessage.SCENE_LOADED \
		|| message_type == GdLinkCore.ControlMessage.SCENE_READY
