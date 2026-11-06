extends GutTest

## Fake GodotSteam networking. Routes messages between fake users with session gating.
class FakeSteam extends Object:
	signal network_messages_session_request(remote_steam_id: int)

	var local_steam_id := 0
	var routes: Dictionary = {}
	var running := true
	var accepted_steam_ids: Array = []
	var closed_steam_ids: Array = []
	var session_info: Dictionary = {}
	var inbox: Array = []
	var sent: Array = []

	func _init(local_steam_id_value: int, routes_value: Dictionary) -> void:
		local_steam_id = local_steam_id_value
		routes = routes_value

	func isSteamRunning() -> bool:
		return running

	func acceptSessionWithUser(remote_steam_id: int) -> void:
		accepted_steam_ids.append(remote_steam_id)

	func closeSessionWithUser(remote_steam_id: int) -> void:
		closed_steam_ids.append(remote_steam_id)

	func getSessionInformation(remote_steam_id: int) -> Dictionary:
		return session_info.get(remote_steam_id, {})

	func sendMessageToUser(remote_steam_id: int, frame: PackedByteArray, flags: int, channel: int) -> void:
		sent.append({"remote_steam_id": remote_steam_id, "frame": frame, "flags": flags, "channel": channel})
		var target: FakeSteam = routes.get(remote_steam_id)
		if target == null: return
		if not target.accepted_steam_ids.has(local_steam_id):
			target.network_messages_session_request.emit(local_steam_id)
		if target.accepted_steam_ids.has(local_steam_id):
			target.inbox.append({"remote_steam_id": local_steam_id, "channel": channel, "payload": frame})

	func readMessagesOnChannel(channel: int, batch: int) -> Array:
		var result: Array = []
		var remaining: Array = []
		for message: Dictionary in inbox:
			if message["channel"] == channel and result.size() < batch:
				result.append(message)
			else:
				remaining.append(message)
		inbox = remaining
		return result

const HOST_STEAM_ID := 76561198000000001
const CLIENT_STEAM_ID := 76561198000000002
const STRANGER_STEAM_ID := 76561198000000003
const VIRTUAL_PORT := 7
const JOIN_ADDRESS := "76561198000000001:7"
const HOST_IDENTIFIER := GdLinkCore.HOST_PEER_IDENTIFIER
const FIRST_CLIENT_IDENTIFIER := 2

var routes: Dictionary = {}
var host_steam: FakeSteam
var client_steam: FakeSteam
var host_transport: SteamRelayTransport
var client_transport: SteamRelayTransport

func before_each() -> void:
	routes = {}
	host_steam = FakeSteam.new(HOST_STEAM_ID, routes)
	client_steam = FakeSteam.new(CLIENT_STEAM_ID, routes)
	routes[HOST_STEAM_ID] = host_steam
	routes[CLIENT_STEAM_ID] = client_steam
	host_transport = SteamRelayTransport.new(host_steam)
	client_transport = SteamRelayTransport.new(client_steam)

func after_each() -> void:
	client_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	host_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)

## Polls both sides so queued frames in either direction are processed.
func _pump() -> void:
	for index in 3:
		host_transport.poll()
		client_transport.poll()

func _connect_pair() -> void:
	assert_eq(host_transport.host(str(VIRTUAL_PORT)), OK)
	watch_signals(host_transport)
	watch_signals(client_transport)
	assert_eq(client_transport.join(JOIN_ADDRESS), OK)
	_pump()

func _last_sent_frame(fake: FakeSteam) -> PackedByteArray:
	return fake.sent.back()["frame"]

# Host and client setup

func test_host_succeeds_when_steam_running() -> void:
	assert_eq(host_transport.host(str(VIRTUAL_PORT)), OK)

func test_host_fails_when_steam_not_running() -> void:
	host_steam.running = false
	assert_eq(host_transport.host(str(VIRTUAL_PORT)), ERR_UNAVAILABLE)

func test_host_rejects_non_integer_port() -> void:
	assert_eq(host_transport.host("abc"), ERR_INVALID_PARAMETER)

func test_second_host_call_while_active_fails() -> void:
	host_transport.host(str(VIRTUAL_PORT))
	assert_eq(host_transport.host(str(VIRTUAL_PORT)), ERR_ALREADY_IN_USE)

func test_join_rejects_address_without_separator() -> void:
	assert_eq(client_transport.join(str(HOST_STEAM_ID)), ERR_INVALID_PARAMETER)

func test_join_rejects_non_integer_host_id() -> void:
	assert_eq(client_transport.join("not_an_id:7"), ERR_INVALID_PARAMETER)

func test_join_fails_when_steam_not_running() -> void:
	client_steam.running = false
	assert_eq(client_transport.join(JOIN_ADDRESS), ERR_UNAVAILABLE)

func test_second_join_call_while_active_fails() -> void:
	client_transport.join(JOIN_ADDRESS)
	assert_eq(client_transport.join(JOIN_ADDRESS), ERR_ALREADY_IN_USE)

# Handshake and identity

func test_probe_handshake_signals_both_sides() -> void:
	_connect_pair()
	assert_signal_emitted_with_parameters(host_transport, "peer_connected", [FIRST_CLIENT_IDENTIFIER])
	assert_signal_emitted_with_parameters(client_transport, "join_succeeded", [HOST_IDENTIFIER])

func test_host_identity_is_steam_id_string() -> void:
	_connect_pair()
	assert_eq(host_transport.get_identity(FIRST_CLIENT_IDENTIFIER), str(CLIENT_STEAM_ID))

func test_unknown_identity_is_empty() -> void:
	assert_eq(host_transport.get_identity(99), "")

func test_session_request_accepted_for_client_probe() -> void:
	_connect_pair()
	assert_true(host_steam.accepted_steam_ids.has(CLIENT_STEAM_ID))

func test_session_request_rejected_when_host_full() -> void:
	host_transport.host(str(VIRTUAL_PORT))
	for index in SteamRelayTransport.MAX_PEERS:
		host_transport._identifiers_by_steam_id[1000 + index] = index + FIRST_CLIENT_IDENTIFIER
	host_steam.network_messages_session_request.emit(STRANGER_STEAM_ID)
	assert_false(host_steam.accepted_steam_ids.has(STRANGER_STEAM_ID))

func test_session_request_from_stranger_rejected_while_joining() -> void:
	host_transport.host(str(VIRTUAL_PORT))
	client_transport.join(JOIN_ADDRESS)
	client_steam.network_messages_session_request.emit(STRANGER_STEAM_ID)
	assert_false(client_steam.accepted_steam_ids.has(STRANGER_STEAM_ID))

# Framing

func test_send_data_frames_type_channel_payload_and_flags() -> void:
	_connect_pair()
	var payload := PackedByteArray([4, 2])
	client_transport.send_data(HOST_IDENTIFIER, 1, payload, false)
	var frame := _last_sent_frame(client_steam)
	assert_eq(frame[0], SteamRelayTransport.FrameType.DATA)
	assert_eq(frame[1], 1)
	assert_eq(frame.slice(2), payload)
	assert_eq(client_steam.sent.back()["flags"], SteamRelayTransport.SEND_UNRELIABLE)

func test_reliable_send_uses_reliable_flag() -> void:
	_connect_pair()
	client_transport.send_data(HOST_IDENTIFIER, 0, PackedByteArray([1]), true)
	assert_eq(client_steam.sent.back()["flags"], SteamRelayTransport.SEND_RELIABLE)

func test_data_frame_delivers_data_received() -> void:
	_connect_pair()
	var payload := PackedByteArray([4, 2])
	client_transport.send_data(HOST_IDENTIFIER, 0, payload, true)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "data_received", [FIRST_CLIENT_IDENTIFIER, 0, payload])

func test_control_frame_delivers_control_received() -> void:
	_connect_pair()
	var payload := PackedByteArray([9])
	client_transport.send_control(HOST_IDENTIFIER, payload)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "control_received", [FIRST_CLIENT_IDENTIFIER, payload])
	assert_signal_not_emitted(host_transport, "data_received")

func test_frame_from_unknown_steam_id_is_ignored() -> void:
	_connect_pair()
	host_steam.inbox.append({
		"remote_steam_id": STRANGER_STEAM_ID,
		"channel": VIRTUAL_PORT,
		"payload": PackedByteArray([SteamRelayTransport.FrameType.DATA, 0, 1]),
	})
	_pump()
	assert_signal_not_emitted(host_transport, "data_received")

func test_short_frame_is_ignored() -> void:
	_connect_pair()
	host_steam.inbox.append({
		"remote_steam_id": CLIENT_STEAM_ID,
		"channel": VIRTUAL_PORT,
		"payload": PackedByteArray([SteamRelayTransport.FrameType.DATA]),
	})
	_pump()
	assert_signal_not_emitted(host_transport, "data_received")

# Lifecycle

func test_kick_sends_disconnect_and_signals_both_sides() -> void:
	_connect_pair()
	host_transport.disconnect_peer(FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "peer_disconnected",
		[FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED])
	assert_signal_emitted_with_parameters(client_transport, "peer_disconnected",
		[HOST_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED])

func test_disconnect_frame_carries_reason_byte() -> void:
	_connect_pair()
	host_transport.disconnect_peer(FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED)
	var frame := _last_sent_frame(host_steam)
	assert_eq(frame[0], SteamRelayTransport.FrameType.DISCONNECT)
	assert_eq(frame[2], GdLinkCore.DisconnectReason.KICKED)

func test_client_close_disconnects_host_side_peer() -> void:
	_connect_pair()
	client_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "peer_disconnected",
		[FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.VOLUNTARY])

func test_host_close_disconnects_clients() -> void:
	_connect_pair()
	host_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	_pump()
	assert_signal_emitted_with_parameters(client_transport, "peer_disconnected",
		[HOST_IDENTIFIER, GdLinkCore.DisconnectReason.VOLUNTARY])

func test_join_timeout_emits_join_failed() -> void:
	client_transport.join(JOIN_ADDRESS)
	watch_signals(client_transport)
	client_transport._join_started_msec = Time.get_ticks_msec() - SteamRelayTransport.JOIN_TIMEOUT_MSEC - 1
	client_transport.poll()
	assert_signal_emitted_with_parameters(client_transport, "join_failed",
		[GdLinkCore.DisconnectReason.TRANSPORT_FAILURE])

func test_session_error_drops_peer_on_heartbeat() -> void:
	_connect_pair()
	watch_signals(host_transport)
	host_steam.session_info[CLIENT_STEAM_ID] = {"session_error": 1}
	host_transport._last_heartbeat_msec = 0
	host_transport.poll()
	assert_signal_emitted_with_parameters(host_transport, "peer_disconnected",
		[FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.TRANSPORT_FAILURE])

func test_lingering_session_closes_after_deadline() -> void:
	_connect_pair()
	host_transport.disconnect_peer(FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED)
	host_transport.poll()
	assert_false(host_steam.closed_steam_ids.has(CLIENT_STEAM_ID), "closed before linger elapsed")
	host_transport._lingering_sessions[CLIENT_STEAM_ID] = 0
	host_transport.poll()
	assert_true(host_steam.closed_steam_ids.has(CLIENT_STEAM_ID))
