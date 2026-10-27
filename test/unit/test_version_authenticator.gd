extends GutTest

class SpoofVersionAuthenticator extends VersionAuthenticator:
	
	var _game_name: String
	var _game_version: String
	
	func _init(game_name: String, game_version: String) -> void:
		_game_name = game_name
		_game_version = game_version
	
	func _get_project_name() -> String:
		return _game_name
	
	func _get_project_version() -> String:
		return _game_version

var authenticator: VersionAuthenticator

func before_each() -> void:
	authenticator = SpoofVersionAuthenticator.new("GdLinkDemo", "1.0.0")

func test_own_hello_is_accepted() -> void:
	var reason := authenticator.verify_hello("127.0.0.1", authenticator.build_hello())
	assert_eq(reason, GdLinkCore.DisconnectReason.NONE)

func test_wrong_version_rejected_with_version_mismatch() -> void:
	var other := SpoofVersionAuthenticator.new("GdLinkDemo", "1.0.1")
	var reason := authenticator.verify_hello("", other.build_hello())
	assert_eq(reason, GdLinkCore.DisconnectReason.AUTH_REJECT_VERSION_MISMATCH)

func test_wrong_game_name_rejected_with_game_mismatch() -> void:
	var other := SpoofVersionAuthenticator.new("OtherGame", "1.0.0")
	var reason := authenticator.verify_hello("", other.build_hello())
	assert_eq(reason, GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH)

func test_missing_separator_rejected() -> void:
	var reason := authenticator.verify_hello("", "GdLinkDemo".to_utf8_buffer())
	assert_eq(reason, GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH)

func test_empty_payload_rejected() -> void:
	var reason := authenticator.verify_hello("", PackedByteArray())
	assert_eq(reason, GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH)

func test_extra_separator_is_treated_as_version_mismatch() -> void:
	var payload := "GdLinkDemo\n1.0.0\nextra".to_utf8_buffer()
	var reason := authenticator.verify_hello("", payload)
	assert_eq(reason, GdLinkCore.DisconnectReason.AUTH_REJECT_VERSION_MISMATCH)

func test_invalid_utf8_is_rejected() -> void:
	var reason := authenticator.verify_hello("", PackedByteArray([0xC3, 0x28, 0xFF]))
	assert_ne(reason, GdLinkCore.DisconnectReason.NONE)
