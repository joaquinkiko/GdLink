## Password based authenticator
class_name PasswordAuthenticator
extends VersionAuthenticator

const PASSWORD_HELLO_BYTES := HELLO_BYTES + HASH_BYTES

var _password_hash: PackedByteArray

func _init(password: String) -> void:
	_password_hash = password.sha1_buffer()

func build_hello() -> PackedByteArray:
	return super.build_hello() + _password_hash

func verify_hello(identity: String, payload: PackedByteArray) -> GdLinkCore.DisconnectReason:
	if payload.size() < PASSWORD_HELLO_BYTES:
		return GdLinkCore.DisconnectReason.AUTH_REJECT_MALFORMED
	var version_result := super.verify_hello(identity, payload)
	if version_result != GdLinkCore.DisconnectReason.NONE:
		return version_result
	if payload.slice(HELLO_BYTES, PASSWORD_HELLO_BYTES) != _password_hash:
		return GdLinkCore.DisconnectReason.AUTH_REJECT_PASSWORD
	return GdLinkCore.DisconnectReason.NONE

func get_max_hello_bytes() -> int:
	return PASSWORD_HELLO_BYTES
