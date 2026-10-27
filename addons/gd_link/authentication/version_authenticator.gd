## Accepts peers whose game name and version match the local build.
## Hello payload: "game_name\nversion" as UTF-8, capped at MAX_HELLO_BYTES.
class_name VersionAuthenticator
extends Authenticator

## Separates fields. Must not appear in any field.
const FIELD_SEPARATOR := "\n"

func build_hello() -> PackedByteArray:
	return (_get_project_name() + FIELD_SEPARATOR + _get_project_version()).to_utf8_buffer()

func verify_hello(_identity: String, payload: PackedByteArray) -> GdLinkCore.DisconnectReason:
	var fields := payload.get_string_from_utf8().split(FIELD_SEPARATOR, true, 1)
	if fields.size() != 2:
		return GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH
	if fields[0] != _get_project_name():
		return GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH
	if fields[1] != _get_project_version():
		return GdLinkCore.DisconnectReason.AUTH_REJECT_VERSION_MISMATCH
	# Passed all tests
	return GdLinkCore.DisconnectReason.NONE

func _get_project_name() -> String:
	return ProjectSettings.get_setting("application/config/name", "")

func _get_project_version() -> String:
	return ProjectSettings.get_setting("application/config/version", "")
