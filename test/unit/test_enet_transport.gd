extends GutTest

const TEST_PORT := "7790"
const TEST_ADDRESS := "127.0.0.1:" + TEST_PORT
const TIMEOUT_MSEC := 3000

var host_transport: ENetTransport
var client_transport: ENetTransport

func before_each() -> void:
	host_transport = ENetTransport.new()
	client_transport = ENetTransport.new()

func after_each() -> void:
	client_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	host_transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	_pump_until(func() -> bool:
		return host_transport.connection == null and client_transport.connection == null, TIMEOUT_MSEC)

## Polls both transports until condition is true or timeout elapses.
func _pump_until(condition: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		host_transport.poll()
		client_transport.poll()
		if condition.call(): return true
		OS.delay_msec(5)
	return condition.call()

## Returns true if the watched object emitted signal_name at least once.
func _emitted(object: Object, signal_name: String) -> bool:
	return get_signal_emit_count(object, signal_name) > 0

func _connect_pair() -> int:
	host_transport.host(TEST_PORT)
	watch_signals(host_transport)
	watch_signals(client_transport)
	client_transport.join(TEST_ADDRESS)
	_pump_until(func() -> bool:
		return _emitted(host_transport, "peer_connected") \
			and _emitted(client_transport, "join_succeeded"), TIMEOUT_MSEC)
	return get_signal_parameters(host_transport, "peer_connected", 0)[0]

func test_host_binds_successfully() -> void:
	assert_eq(host_transport.host(TEST_PORT), OK)

func test_join_rejects_address_without_port() -> void:
	assert_eq(client_transport.join("127.0.0.1"), ERR_INVALID_PARAMETER)

func test_client_connects_and_both_sides_signal() -> void:
	_connect_pair()
	assert_signal_emitted(host_transport, "peer_connected")
	assert_signal_emitted(client_transport, "join_succeeded")

func test_host_identity_is_client_address() -> void:
	var peer_identifier := _connect_pair()
	assert_eq(host_transport.get_identity(peer_identifier), "127.0.0.1")

func test_host_kick_reaches_client_with_reason() -> void:
	var peer_identifier := _connect_pair()
	host_transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.KICKED)
	_pump_until(func() -> bool:
		return _emitted(client_transport, "peer_disconnected"), TIMEOUT_MSEC)
	assert_eq(get_signal_parameters(client_transport, "peer_disconnected", 0)[1],
		GdLinkCore.DisconnectReason.KICKED)

func test_host_disconnect_signal_carries_local_reason() -> void:
	var peer_identifier := _connect_pair()
	host_transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.KICKED)
	_pump_until(func() -> bool:
		return _emitted(host_transport, "peer_disconnected"), TIMEOUT_MSEC)
	assert_eq(get_signal_parameters(host_transport, "peer_disconnected", 0)[1],
		GdLinkCore.DisconnectReason.KICKED)

func test_control_payload_arrives_on_gdlink_channel() -> void:
	var peer_identifier := _connect_pair()
	var payload := PackedByteArray([7, 8, 9])
	client_transport.send_control(1, payload)
	var received := _pump_until(func() -> bool:
		return _emitted(host_transport, "control_received"), TIMEOUT_MSEC)
	assert_true(received, "control_received never fired on host")
	if not received: return
	assert_eq(get_signal_parameters(host_transport, "control_received", 0)[0], peer_identifier)
	assert_eq(get_signal_parameters(host_transport, "control_received", 0)[1], payload)

func test_user_channel_payload_arrives_as_data() -> void:
	var peer_identifier := _connect_pair()
	var payload := PackedByteArray([4, 2])
	client_transport.send_data(1, 0, payload, true)
	var received := _pump_until(func() -> bool:
		return _emitted(host_transport, "data_received"), TIMEOUT_MSEC)
	assert_true(received, "data_received never fired on host")
	if not received: return
	assert_eq(get_signal_parameters(host_transport, "data_received", 0), [peer_identifier, 0, payload])

func test_gdlink_channel_is_not_forwarded_as_data() -> void:
	_connect_pair()
	client_transport.send_control(1, PackedByteArray([1]))
	_pump_until(func() -> bool:
		return _emitted(host_transport, "control_received"), TIMEOUT_MSEC)
	assert_signal_not_emitted(host_transport, "data_received")
