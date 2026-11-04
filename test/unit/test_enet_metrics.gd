extends GutTest

const TEST_PORT := "7797"
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

func _pump_until(condition: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		host_transport.poll()
		client_transport.poll()
		if condition.call(): return true
		OS.delay_msec(5)
	return condition.call()

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

func test_link_stats_empty_for_unknown_peer() -> void:
	assert_true(client_transport.get_link_stats(99).is_empty())

## Fails if the PACKET_LOSS_SCALE divisor in enet_transport.gd is wrong.
func test_link_stats_report_rtt_and_loss_once_connected() -> void:
	_connect_pair()
	var stats := client_transport.get_link_stats(GdLinkCore.HOST_PEER_IDENTIFIER)
	assert_true(stats.has("rtt_msec"))
	assert_true(stats.has("loss"))
	assert_gte(stats["loss"], 0.0)
	assert_lte(stats["loss"], 1.0)

func test_control_send_counts_outbound_on_client() -> void:
	_connect_pair()
	client_transport.send_control(GdLinkCore.HOST_PEER_IDENTIFIER, PackedByteArray([7, 8, 9]))
	var counters := client_transport.get_traffic_counters(GdLinkCore.HOST_PEER_IDENTIFIER)
	assert_not_null(counters)
	assert_eq(counters.packets_out, 1)
	assert_eq(counters.bytes_out, 3)

func test_data_round_trip_counted_on_both_sides() -> void:
	var peer_identifier := _connect_pair()
	client_transport.send_data(GdLinkCore.HOST_PEER_IDENTIFIER, 0, PackedByteArray([4, 2]), true)
	_pump_until(func() -> bool:
		return _emitted(host_transport, "data_received"), TIMEOUT_MSEC)
	var sent := client_transport.get_traffic_counters(GdLinkCore.HOST_PEER_IDENTIFIER)
	var received := host_transport.get_traffic_counters(peer_identifier)
	assert_not_null(sent)
	assert_not_null(received)
	assert_eq(sent.bytes_out, 2)
	assert_eq(received.packets_in, 1)
	assert_eq(received.bytes_in, 2)

func test_control_receive_counted_on_client() -> void:
	var peer_identifier := _connect_pair()
	host_transport.send_control(peer_identifier, PackedByteArray([1, 2]))
	_pump_until(func() -> bool:
		return _emitted(client_transport, "control_received"), TIMEOUT_MSEC)
	var received := client_transport.get_traffic_counters(GdLinkCore.HOST_PEER_IDENTIFIER)
	assert_not_null(received)
	assert_eq(received.packets_in, 1)
	assert_eq(received.bytes_in, 2)
	assert_eq(host_transport.get_traffic_counters(peer_identifier).bytes_out, 2)

func test_counters_cleared_when_peer_removed() -> void:
	var peer_identifier := _connect_pair()
	host_transport.send_control(peer_identifier, PackedByteArray([1]))
	host_transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.KICKED)
	_pump_until(func() -> bool:
		return _emitted(host_transport, "peer_disconnected"), TIMEOUT_MSEC)
	assert_null(host_transport.get_traffic_counters(peer_identifier))
