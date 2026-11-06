extends GutTest

const TEST_PORT := "7796"
const TEST_ADDRESS := "%s:%s"%[LOCAL_IDENTITY, TEST_PORT]
const LOCAL_IDENTITY := "127.0.0.1"
const FIRST_CLIENT_IDENTIFIER := 2
const HOST_IDENTIFIER := GdLinkCore.HOST_PEER_IDENTIFIER

var host_transport: OfflineTransport
var client_transport: OfflineTransport

func before_each() -> void:
	host_transport = OfflineTransport.new()
	client_transport = OfflineTransport.new()

func after_each() -> void:
	client_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	host_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)

## Polls both sides so events queued in either direction are delivered.
func _pump() -> void:
	for index in 2:
		host_transport.poll()
		client_transport.poll()

func _connect_pair() -> void:
	host_transport.host(TEST_PORT)
	watch_signals(host_transport)
	watch_signals(client_transport)
	client_transport.join(TEST_ADDRESS)
	_pump()

func test_host_binds_successfully() -> void:
	assert_eq(host_transport.host(TEST_PORT), OK)

func test_second_host_on_same_port_fails() -> void:
	host_transport.host(TEST_PORT)
	assert_eq(client_transport.host(TEST_PORT), ERR_ALREADY_IN_USE)

func test_join_rejects_address_without_port() -> void:
	assert_eq(client_transport.join("127.0.0.1"), ERR_INVALID_PARAMETER)

func test_join_without_host_fails() -> void:
	assert_eq(client_transport.join("127.0.0.1:7797"), ERR_CANT_CONNECT)

func test_events_are_deferred_until_poll() -> void:
	host_transport.host(TEST_PORT)
	watch_signals(host_transport)
	client_transport.join(TEST_ADDRESS)
	assert_signal_not_emitted(host_transport, "peer_connected")
	host_transport.poll()
	assert_signal_emitted(host_transport, "peer_connected")

func test_client_and_host_signal_on_join() -> void:
	_connect_pair()
	assert_signal_emitted_with_parameters(host_transport, "peer_connected", [FIRST_CLIENT_IDENTIFIER])
	assert_signal_emitted_with_parameters(client_transport, "join_succeeded", [HOST_IDENTIFIER])

func test_host_identity_is_local_address() -> void:
	_connect_pair()
	assert_eq(host_transport.get_identity(FIRST_CLIENT_IDENTIFIER), LOCAL_IDENTITY)

func test_unknown_identity_is_empty() -> void:
	assert_eq(host_transport.get_identity(99), "")

func test_control_payload_arrives_on_gdlink_channel() -> void:
	_connect_pair()
	var payload := PackedByteArray([7, 8, 9])
	client_transport.send_control(HOST_IDENTIFIER, payload)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "control_received", [FIRST_CLIENT_IDENTIFIER, payload])
	assert_signal_not_emitted(host_transport, "data_received")

func test_data_payload_arrives_with_channel() -> void:
	_connect_pair()
	var payload := PackedByteArray([4, 2])
	client_transport.send_data(HOST_IDENTIFIER, 1, payload, true)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "data_received", [FIRST_CLIENT_IDENTIFIER, 1, payload])

func test_host_to_client_data_round_trip() -> void:
	_connect_pair()
	var payload := PackedByteArray([9])
	host_transport.send_data(FIRST_CLIENT_IDENTIFIER, 0, payload, false)
	_pump()
	assert_signal_emitted_with_parameters(client_transport, "data_received", [HOST_IDENTIFIER, 0, payload])

func test_inbound_events_preserve_order() -> void:
	_connect_pair()
	for index in 3:
		client_transport.send_data(HOST_IDENTIFIER, 0, PackedByteArray([index]), true)
	host_transport.poll()
	assert_eq(get_signal_emit_count(host_transport, "data_received"), 3)
	assert_eq(get_signal_parameters(host_transport, "data_received", 2)[2], PackedByteArray([2]))

func test_send_to_unknown_peer_is_dropped() -> void:
	_connect_pair()
	host_transport.send_data(99, 0, PackedByteArray([1]), true)
	_pump()
	assert_signal_not_emitted(client_transport, "data_received")

func test_kick_reaches_client_with_reason() -> void:
	_connect_pair()
	host_transport.disconnect_peer(FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "peer_disconnected",
		[FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED])
	assert_signal_emitted_with_parameters(client_transport, "peer_disconnected",
		[HOST_IDENTIFIER, GdLinkCore.DisconnectReason.KICKED])

func test_client_close_disconnects_host_side_peer() -> void:
	_connect_pair()
	client_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	_pump()
	assert_signal_emitted_with_parameters(host_transport, "peer_disconnected",
		[FIRST_CLIENT_IDENTIFIER, GdLinkCore.DisconnectReason.VOLUNTARY])

func test_host_close_disconnects_all_clients_and_frees_port() -> void:
	_connect_pair()
	host_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	_pump()
	assert_signal_emitted_with_parameters(client_transport, "peer_disconnected",
		[HOST_IDENTIFIER, GdLinkCore.DisconnectReason.VOLUNTARY])
	var replacement := OfflineTransport.new()
	assert_eq(replacement.host(TEST_PORT), OK)
	replacement.close(GdLinkCore.DisconnectReason.VOLUNTARY)

func test_join_after_host_close_fails() -> void:
	_connect_pair()
	host_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	var late_client := OfflineTransport.new()
	assert_eq(late_client.join(TEST_ADDRESS), ERR_CANT_CONNECT)
