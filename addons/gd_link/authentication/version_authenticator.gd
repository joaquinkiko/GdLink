## Accepts peers whose game name and version match the local build.
class_name VersionAuthenticator
extends Authenticator

const HASH_BYTES := 20
const HELLO_BYTES := HASH_BYTES * 2

func build_hello() -> PackedByteArray:
	return _get_project_name_hash() + _get_project_version_hash()

func verify_hello(_identity: String, payload: PackedByteArray) -> GdLinkCore.DisconnectReason:
	if payload.size() < HELLO_BYTES:
		return GdLinkCore.DisconnectReason.AUTH_REJECT_MALFORMED
	if payload.slice(0, HASH_BYTES) != _get_project_name_hash():
		return GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH
	if payload.slice(HASH_BYTES, HELLO_BYTES) != _get_project_version_hash():
		return GdLinkCore.DisconnectReason.AUTH_REJECT_VERSION_MISMATCH
	# Passed all tests
	return GdLinkCore.DisconnectReason.NONE

func _get_project_name_hash() -> PackedByteArray:
	return ProjectSettings.get_setting("application/config/name", "").sha1_buffer()

func _get_project_version_hash() -> PackedByteArray:
	return ProjectSettings.get_setting("application/config/version", "").sha1_buffer()

func get_max_hello_bytes() -> int:
	return HELLO_BYTES
