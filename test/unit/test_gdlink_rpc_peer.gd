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

const FAKE_PORT := "7000"
const FAKE_IP := "127.0.0.1"
const FAKE_ADDRESS := "%s:%s"%[FAKE_IP, FAKE_PORT]

var transport: FakeTransport
var session: Session
var rpc_peer: GdLinkRpcPeer
var hello: PackedByteArray
var payload: PackedByteArray

func before_each() -> void:
	transport = FakeTransport.new()
	session = add_child_autofree(Session.new())
	session.setup(transport, VersionAuthenticator.new())
	rpc_peer = GdLinkRpcPeer.new(session)
	hello = session.authenticator.build_hello()
	payload = PackedByteArray([7, 7, 7])

func _host_authenticated(peer_identifier: int) -> void:
	session.host(FAKE_PORT)
	transport.peer_connected.emit(peer_identifier)
	transport.control_received.emit(peer_identifier, hello)

func _join_as_client(assigned_identifier: int) -> void:
	session.join(FAKE_ADDRESS)
	transport.join_succeeded.emit(assigned_identifier)
	var accept := PackedByteArray()
	accept.resize(5)
	accept[0] = Session.ACCEPT_BYTE
	accept.encode_u32(1, assigned_identifier)
	transport.control_received.emit(assigned_identifier, accept)

func test_client_join_sets_unique_id_and_connects() -> void:
	watch_signals(rpc_peer)
	_join_as_client(7)
	assert_eq(rpc_peer.get_unique_id(), 7)
	assert_eq(rpc_peer.get_connection_status(), MultiplayerPeer.CONNECTION_CONNECTED)
	assert_signal_emitted_with_parameters(rpc_peer, "peer_connected", [1])

func test_host_emits_peer_connected_only_after_auth() -> void:
	watch_signals(rpc_peer)
	session.host(FAKE_PORT)
	transport.peer_connected.emit(4)
	assert_signal_not_emitted(rpc_peer, "peer_connected")
	transport.control_received.emit(4, hello)
	assert_signal_emitted_with_parameters(rpc_peer, "peer_connected", [4])

func test_host_emits_peer_disconnected() -> void:
	watch_signals(rpc_peer)
	_host_authenticated(4)
	transport.peer_disconnected.emit(4, GdLinkCore.DisconnectReason.VOLUNTARY)
	assert_signal_emitted_with_parameters(rpc_peer, "peer_disconnected", [4])

func test_client_session_loss_emits_server_disconnect() -> void:
	_join_as_client(7)
	watch_signals(rpc_peer)
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.KICKED)
	assert_eq(rpc_peer.get_connection_status(), MultiplayerPeer.CONNECTION_DISCONNECTED)
	assert_signal_emitted_with_parameters(rpc_peer, "peer_disconnected", [1])

func test_inbound_packet_queued_with_metadata() -> void:
	_host_authenticated(4)
	transport.data_received.emit(4, 1, payload)
	assert_eq(rpc_peer.get_available_packet_count(), 1)
	assert_eq(rpc_peer.get_packet(), payload)
	assert_eq(rpc_peer.get_packet_peer(), 4)
	assert_eq(rpc_peer.get_packet_channel(), 1)

func test_unauthenticated_inbound_never_queued() -> void:
	session.host(FAKE_PORT)
	transport.peer_connected.emit(9)
	transport.data_received.emit(9, 0, payload)
	assert_eq(rpc_peer.get_available_packet_count(), 0)

func test_inbound_queue_is_capped() -> void:
	_host_authenticated(4)
	for index in range(GdLinkRpcPeer.MAX_QUEUED_PACKETS + 10):
		transport.data_received.emit(4, 0, payload)
	assert_eq(rpc_peer.get_available_packet_count(), GdLinkRpcPeer.MAX_QUEUED_PACKETS)

func test_broadcast_reaches_only_authenticated_peers() -> void:
	_host_authenticated(4)
	_host_authenticated(5)
	session.host(FAKE_PORT)
	transport.peer_connected.emit(6)
	rpc_peer.set_target_peer(0)
	rpc_peer.put_packet(payload)
	var recipients: Array = transport.sent_data.map(func(entry: Dictionary) -> int: return entry["peer"])
	assert_eq(recipients, [4, 5])

func test_targeted_send_reaches_single_peer() -> void:
	_host_authenticated(4)
	_host_authenticated(5)
	rpc_peer.set_target_peer(5)
	rpc_peer.put_packet(payload)
	assert_eq(transport.sent_data.size(), 1)
	assert_eq(transport.sent_data[0]["peer"], 5)

func test_negated_target_excludes_peer() -> void:
	_host_authenticated(4)
	_host_authenticated(5)
	rpc_peer.set_target_peer(-5)
	rpc_peer.put_packet(payload)
	assert_eq(transport.sent_data.size(), 1)
	assert_eq(transport.sent_data[0]["peer"], 4)

func test_client_sends_to_server() -> void:
	_join_as_client(7)
	rpc_peer.put_packet(payload)
	assert_eq(transport.sent_data[0]["peer"], 1)

func test_unreliable_mode_sends_unreliable() -> void:
	_host_authenticated(4)
	rpc_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	rpc_peer.set_target_peer(4)
	rpc_peer.put_packet(payload)
	assert_false(transport.sent_data[0]["reliable"])

func test_transfer_channel_is_applied() -> void:
	_host_authenticated(4)
	rpc_peer.set_transfer_channel(2)
	rpc_peer.set_target_peer(4)
	rpc_peer.put_packet(payload)
	assert_eq(transport.sent_data[0]["channel"], 2)

func test_max_packet_size_matches_core() -> void:
	assert_eq(rpc_peer._get_max_packet_size(), GdLinkCore.MAX_PAYLOAD_BYTES)

func test_disconnect_peer_kicks_with_reason() -> void:
	_host_authenticated(4)
	rpc_peer.disconnect_peer(4, false)
	assert_eq(transport.disconnected_calls, [[4, GdLinkCore.DisconnectReason.KICKED]])

func test_refuse_new_connections_flag() -> void:
	rpc_peer.set_refuse_new_connections(true)
	assert_true(rpc_peer.is_refusing_new_connections())
