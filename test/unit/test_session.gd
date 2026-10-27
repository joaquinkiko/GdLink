extends GutTest

class FakeTransport extends Transport:
	var disconnected_calls: Array = []
	var sent_controls: Array = []
	var sent_data: Array = []
	var identities: Dictionary = {}

	func poll() -> void:
		pass

	func host(_bind_address: String) -> Error:
		return OK

	func join(_join_address: String) -> Error:
		return OK

	func disconnect_peer(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
		disconnected_calls.append([peer_identifier, reason])

	func close(_reason: GdLinkCore.DisconnectReason) -> void:
		pass

	func send_control(peer_identifier: int, payload: PackedByteArray) -> void:
		sent_controls.append([peer_identifier, payload])

	func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
		sent_data.append({"peer": peer_identifier, "channel": channel, "payload": payload, "reliable": reliable})

	func get_identity(peer_identifier: int) -> String:
		return identities.get(peer_identifier, "")

const FAKE_PORT := "7800"
const FAKE_IP := "10.0.0.2"
const FAKE_ADDRESS := "%s:%s"%[FAKE_IP, FAKE_PORT]

var transport: FakeTransport
var authenticator: VersionAuthenticator
var session: Session

func before_each() -> void:
	transport = FakeTransport.new()
	authenticator = VersionAuthenticator.new()
	session = Session.new()
	add_child_autofree(session)
	session.setup(transport, authenticator)

func _connect_peer(peer_identifier: int, identity: String) -> void:
	transport.identities[peer_identifier] = identity
	transport.peer_connected.emit(peer_identifier)

func test_connected_peer_awaits_hello() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	assert_eq(session.get_peer(1).state, Peer.State.AWAITING_HELLO)

func test_valid_hello_authenticates_and_sends_accept() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	watch_signals(session)
	transport.control_received.emit(1, authenticator.build_hello())
	assert_true(session.get_peer(1).is_authenticated())
	assert_signal_emitted(session, "peer_authenticated")
	assert_eq(transport.sent_controls[0][1], session._build_accept(1))

func test_replayed_hello_after_auth_is_ignored() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	watch_signals(session)
	transport.control_received.emit(1, authenticator.build_hello())
	transport.control_received.emit(1, authenticator.build_hello())
	assert_signal_emit_count(session, "peer_authenticated", 1)
	assert_eq(transport.sent_controls.size(), 1)

func test_timeout_disconnects_unauthenticated_peer() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	session._on_authentication_timeout(1)
	assert_eq(transport.disconnected_calls[0][1], GdLinkCore.DisconnectReason.AUTH_REJECT_TIMEOUT)

func test_timeout_ignores_authenticated_peer() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	transport.control_received.emit(1, authenticator.build_hello())
	session._on_authentication_timeout(1)
	assert_eq(transport.disconnected_calls.size(), 0)

func test_kick_forwards_reason_on_host() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	session.kick(1, GdLinkCore.DisconnectReason.KICKED)
	assert_eq(transport.disconnected_calls[0][1], GdLinkCore.DisconnectReason.KICKED)

func test_disconnect_removes_peer_and_emits() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	watch_signals(session)
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.KICKED)
	assert_null(session.get_peer(1))
	assert_signal_emitted(session, "peer_removed")

func test_client_sends_hello_on_join_succeeded() -> void:
	session.join(FAKE_ADDRESS)
	transport.join_succeeded.emit(1)
	assert_eq(transport.sent_controls[0][1], authenticator.build_hello())

func test_client_marks_authenticated_on_accept() -> void:
	session.join(FAKE_ADDRESS)
	watch_signals(session)
	var accept := PackedByteArray()
	accept.resize(5)
	accept[0] = Session.ACCEPT_BYTE
	accept.encode_u32(1, 7)
	transport.control_received.emit(1, accept)
	assert_true(session.is_client_authenticated)
	assert_signal_emitted_with_parameters(session, "join_succeeded", [7])

func test_accept_with_wrong_length_is_ignored() -> void:
	session.join(FAKE_ADDRESS)
	watch_signals(session)
	transport.control_received.emit(1, PackedByteArray([Session.ACCEPT_BYTE]))
	assert_false(session.is_client_authenticated)
	assert_signal_not_emitted(session, "join_succeeded")

func test_kick_is_noop_on_client() -> void:
	session.join(FAKE_ADDRESS)
	session.kick(1, GdLinkCore.DisconnectReason.KICKED)
	assert_true(transport.disconnected_calls.is_empty())

func test_client_disconnect_before_accept_emits_join_failed() -> void:
	session.join(FAKE_ADDRESS)
	watch_signals(session)
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.AUTH_REJECT_TIMEOUT)
	assert_signal_emitted_with_parameters(session, "join_failed", [GdLinkCore.DisconnectReason.AUTH_REJECT_TIMEOUT])

func test_client_disconnect_after_accept_emits_session_closed() -> void:
	session.join(FAKE_ADDRESS)
	var accept := PackedByteArray()
	accept.resize(5)
	accept[0] = Session.ACCEPT_BYTE
	accept.encode_u32(1, 7)
	transport.control_received.emit(1, accept)
	watch_signals(session)
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.KICKED)
	assert_signal_emitted_with_parameters(session, "session_closed", [GdLinkCore.DisconnectReason.KICKED])

func test_disconnect_of_unknown_peer_emits_nothing() -> void:
	session.host(FAKE_PORT)
	watch_signals(session)
	transport.peer_disconnected.emit(99, GdLinkCore.DisconnectReason.VOLUNTARY)
	assert_signal_not_emitted(session, "peer_removed")
