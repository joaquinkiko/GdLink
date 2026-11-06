extends GutTest

const PASSWORD := "scary larry"

class WrongVersionAuthenticator extends PasswordAuthenticator:
	func _get_project_version_hash() -> PackedByteArray:
		return "0.0.0-mismatch".sha1_buffer()

class WrongNameAuthenticator extends PasswordAuthenticator:
	func _get_project_name_hash() -> PackedByteArray:
		return "OtherGame".sha1_buffer()

var host: PasswordAuthenticator
var client: PasswordAuthenticator

func before_each() -> void:
	host = PasswordAuthenticator.new(PASSWORD)
	client = PasswordAuthenticator.new(PASSWORD)

func test_hello_size() -> void:
	assert_eq(client.build_hello().size(), PasswordAuthenticator.PASSWORD_HELLO_BYTES)

func test_accepts_matching_password() -> void:
	assert_eq(host.verify_hello("", client.build_hello()), GdLinkCore.DisconnectReason.NONE)

func test_rejects_wrong_password() -> void:
	var other := PasswordAuthenticator.new("wrong")
	assert_eq(host.verify_hello("", other.build_hello()), GdLinkCore.DisconnectReason.AUTH_REJECT_PASSWORD)

func test_rejects_empty_password_against_set_password() -> void:
	var other := PasswordAuthenticator.new("")
	assert_eq(host.verify_hello("", other.build_hello()), GdLinkCore.DisconnectReason.AUTH_REJECT_PASSWORD)

func test_rejects_version_mismatch() -> void:
	var other := WrongVersionAuthenticator.new(PASSWORD)
	assert_eq(host.verify_hello("", other.build_hello()), GdLinkCore.DisconnectReason.AUTH_REJECT_VERSION_MISMATCH)

func test_rejects_game_name_mismatch() -> void:
	var other := WrongNameAuthenticator.new(PASSWORD)
	assert_eq(host.verify_hello("", other.build_hello()), GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH)

func test_rejects_empty_payload() -> void:
	assert_eq(host.verify_hello("", PackedByteArray()), GdLinkCore.DisconnectReason.AUTH_REJECT_MALFORMED)

func test_rejects_truncated_hello() -> void:
	var hello := client.build_hello()
	assert_eq(host.verify_hello("", hello.slice(0, hello.size() - 1)), GdLinkCore.DisconnectReason.AUTH_REJECT_MALFORMED)
