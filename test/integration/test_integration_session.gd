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

const FAKE_PORT := "7791"
const FAKE_IP := "127.0.0.1"
const FAKE_ADDRESS := "%s:%s"%[FAKE_IP, FAKE_PORT]
const GAME_NAME := "GdLinkTest"
const TIMEOUT_SECONDS := 3.0

var host_session: Session
var client_session: Session

func before_each() -> void:
	host_session = _make_session("1.0.0")

func after_each() -> void:
	if client_session != null: client_session.leave()
	host_session.transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)

## Creates a session with its own ENet transport and version authenticator.
func _make_session(version: String) -> Session:
	var session := Session.new()
	add_child_autofree(session)
	session.setup(ENetTransport.new(), SpoofVersionAuthenticator.new(GAME_NAME, version))
	return session

## Hosts, then joins with a matching version and waits for client authentication.
func _connect_matching() -> void:
	client_session = _make_session("1.0.0")
	watch_signals(host_session)
	watch_signals(client_session)
	host_session.host(FAKE_PORT)
	client_session.join(FAKE_ADDRESS)
	await wait_until(func() -> bool: return client_session.is_client_authenticated, TIMEOUT_SECONDS)

func test_matching_version_authenticates_both_sides() -> void:
	await _connect_matching()
	assert_true(client_session.is_client_authenticated)
	assert_signal_emitted(client_session, "join_succeeded")
	assert_signal_emitted(host_session, "peer_authenticated")
	assert_eq(host_session.get_authenticated_peers().size(), 1)

func test_wrong_version_is_rejected_with_version_mismatch() -> void:
	client_session = _make_session("9.9.9")
	watch_signals(host_session)
	watch_signals(client_session)
	host_session.host(FAKE_PORT)
	client_session.join(FAKE_ADDRESS)
	await wait_until(func() -> bool: return get_signal_emit_count(client_session, "join_failed") > 0, TIMEOUT_SECONDS)
	assert_signal_emitted_with_parameters(client_session, "join_failed",
		[GdLinkCore.DisconnectReason.AUTH_REJECT_VERSION_MISMATCH])
	assert_false(client_session.is_client_authenticated)
	assert_eq(host_session.get_authenticated_peers().size(), 0)

func test_host_kick_closes_client_session_with_reason() -> void:
	await _connect_matching()
	var peer_identifier := host_session.get_authenticated_peers()[0].peer_identifier
	host_session.kick(peer_identifier, GdLinkCore.DisconnectReason.KICKED)
	await wait_until(func() -> bool: return get_signal_emit_count(client_session, "session_closed") > 0, TIMEOUT_SECONDS)
	assert_signal_emitted_with_parameters(client_session, "session_closed",
		[GdLinkCore.DisconnectReason.KICKED])

func test_voluntary_leave_removes_peer_on_host() -> void:
	await _connect_matching()
	client_session.leave()
	await wait_until(func() -> bool: return get_signal_emit_count(host_session, "peer_removed") > 0, TIMEOUT_SECONDS)
	assert_eq(get_signal_parameters(host_session, "peer_removed", 0)[1],
		GdLinkCore.DisconnectReason.VOLUNTARY)
	assert_eq(host_session.get_authenticated_peers().size(), 0)

func test_data_round_trip_after_auth() -> void:
	await _connect_matching()
	watch_signals(host_session)
	var peer_identifier := host_session.get_authenticated_peers()[0].peer_identifier
	var payload := PackedByteArray([4, 2])
	client_session.send_data(1, 0, payload, true)
	await wait_until(func() -> bool: return get_signal_emit_count(host_session, "data_received") > 0, TIMEOUT_SECONDS)
	assert_signal_emitted_with_parameters(host_session, "data_received", [peer_identifier, 0, payload])
