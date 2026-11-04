extends GutTest

class FakeLinkTransport extends Transport:
	var link_stats: Dictionary = {}
	var identities: Dictionary = {}

	func poll() -> void:
		pass

	func host(_bind_address: String) -> Error:
		return OK

	func join(_join_address: String) -> Error:
		return OK

	func disconnect_peer(_peer_identifier: int, _reason: GdLinkCore.DisconnectReason) -> void:
		pass

	func close(_reason: GdLinkCore.DisconnectReason) -> void:
		pass

	func send_control(_peer_identifier: int, _payload: PackedByteArray) -> void:
		pass

	func send_data(_peer_identifier: int, _channel: int, _payload: PackedByteArray, _reliable: bool) -> void:
		pass

	func get_identity(peer_identifier: int) -> String:
		return identities.get(peer_identifier, "")

	func get_link_stats(peer_identifier: int) -> Dictionary:
		return link_stats.get(peer_identifier, {})

	func set_link(peer_identifier: int, rtt_msec: float, loss: float) -> void:
		link_stats[peer_identifier] = {"rtt_msec": rtt_msec, "loss": loss}

	func record_in(peer_identifier: int, byte_count: int) -> void:
		_record_received(peer_identifier, byte_count)

	func record_out(peer_identifier: int, byte_count: int) -> void:
		_record_sent(peer_identifier, byte_count)

const FAKE_PORT := "7800"
const FAKE_IP := "10.0.0.2"
const FAKE_ADDRESS := "%s:%s"%[FAKE_IP, FAKE_PORT]

var transport: FakeLinkTransport
var metrics: GdLinkMetrics
var session_transport: FakeLinkTransport
var session: Session

func before_each() -> void:
	transport = FakeLinkTransport.new()
	metrics = GdLinkMetrics.new()
	session_transport = FakeLinkTransport.new()
	session = add_child_autofree(Session.new())
	session.setup(session_transport, VersionAuthenticator.new())

## Consumes the baseline tick, then returns the first real sample.
func _sample_after_baseline(peer_identifier: int) -> Dictionary:
	metrics.sample_peer(transport, peer_identifier)
	return metrics.sample_peer(transport, peer_identifier)

func _accept_payload(assigned_identifier: int) -> PackedByteArray:
	var accept := PackedByteArray()
	accept.resize(Session.ACCEPT_SIZE)
	accept[0] = Session.ACCEPT_BYTE
	accept.encode_u32(1, assigned_identifier)
	return accept

func _authenticate_peer(peer_identifier: int) -> void:
	session_transport.identities[peer_identifier] = FAKE_IP
	session_transport.peer_connected.emit(peer_identifier)
	session_transport.control_received.emit(peer_identifier, session._build_hello_message())

func _tick(seconds: float) -> void:
	session._process(seconds)

func test_off_mode_samples_nothing() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.OFF)
	transport.record_in(2, 10)
	assert_false(metrics.is_enabled())
	assert_true(metrics.sample_peer(transport, 2).is_empty())
	assert_true(metrics.get_snapshot(2).is_empty())

func test_first_tick_is_baseline_only() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.ALL)
	transport.set_link(2, 40.0, 0.1)
	transport.record_in(2, 100)
	assert_true(metrics.sample_peer(transport, 2).is_empty())
	assert_true(metrics.get_snapshot(2)["latest"].is_empty())

func test_traffic_before_baseline_is_not_a_spike() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	transport.record_in(2, 100)
	metrics.sample_peer(transport, 2)
	var sample := metrics.sample_peer(transport, 2)
	assert_almost_eq(sample["bytes_in"], 0.0, 0.001)

func test_rtt_only_reports_rtt_alone() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.RTT_ONLY)
	transport.set_link(2, 40.0, 0.1)
	transport.record_in(2, 100)
	var sample := _sample_after_baseline(2)
	assert_eq(sample.keys(), ["rtt_msec"])

func test_quality_only_reports_rtt_and_loss() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.QUALITY_ONLY)
	transport.set_link(2, 40.0, 0.1)
	var sample := _sample_after_baseline(2)
	assert_eq(sample.keys().size(), 2)
	assert_true(sample.has("rtt_msec"))
	assert_true(sample.has("loss"))

func test_data_io_only_reports_rates_without_link_quality() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	transport.set_link(2, 40.0, 0.1)
	var sample := _sample_after_baseline(2)
	assert_eq(sample.keys().size(), GdLinkMetrics.TRAFFIC_KEYS.size())
	for key: String in GdLinkMetrics.TRAFFIC_KEYS:
		assert_true(sample.has(key))
	assert_false(sample.has("rtt_msec"))

func test_all_reports_every_metric() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.ALL)
	transport.set_link(2, 40.0, 0.1)
	var sample := _sample_after_baseline(2)
	assert_eq(sample.keys().size(), GdLinkMetrics.TRAFFIC_KEYS.size() + 2)

func test_missing_link_stats_yield_no_quality_keys() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.QUALITY_ONLY)
	assert_true(_sample_after_baseline(2).is_empty())

func test_traffic_rates_are_per_interval_deltas() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	metrics.sample_peer(transport, 2)
	transport.record_in(2, 10)
	transport.record_in(2, 10)
	transport.record_in(2, 10)
	transport.record_out(2, 4)
	var first := metrics.sample_peer(transport, 2)
	assert_almost_eq(first["packets_in"], 3.0, 0.001)
	assert_almost_eq(first["bytes_in"], 30.0, 0.001)
	assert_almost_eq(first["packets_out"], 1.0, 0.001)
	assert_almost_eq(first["bytes_out"], 4.0, 0.001)
	transport.record_in(2, 5)
	var second := metrics.sample_peer(transport, 2)
	assert_almost_eq(second["packets_in"], 1.0, 0.001)
	assert_almost_eq(second["bytes_in"], 5.0, 0.001)

func test_idle_peer_reports_zero_rates() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	metrics.sample_peer(transport, 2)
	var sample := metrics.sample_peer(transport, 2)
	assert_almost_eq(sample["bytes_out"], 0.0, 0.001)

func test_peers_are_sampled_independently() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	metrics.sample_peer(transport, 2)
	metrics.sample_peer(transport, 3)
	transport.record_in(2, 8)
	transport.record_in(3, 80)
	assert_almost_eq(metrics.sample_peer(transport, 2)["bytes_in"], 8.0, 0.001)
	assert_almost_eq(metrics.sample_peer(transport, 3)["bytes_in"], 80.0, 0.001)

func test_ring_keeps_only_last_ten_samples() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.RTT_ONLY)
	metrics.sample_peer(transport, 2)
	for rtt in range(1, 13):
		transport.set_link(2, float(rtt), 0.0)
		metrics.sample_peer(transport, 2)
	var snapshot := metrics.get_snapshot(2)
	assert_almost_eq(snapshot["latest"]["rtt_msec"], 12.0, 0.001)
	assert_almost_eq(snapshot["min"]["rtt_msec"], 3.0, 0.001)
	assert_almost_eq(snapshot["max"]["rtt_msec"], 12.0, 0.001)
	assert_almost_eq(snapshot["average"]["rtt_msec"], 7.5, 0.001)

func test_partial_window_averages_only_filled_slots() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.RTT_ONLY)
	metrics.sample_peer(transport, 2)
	for rtt: float in [10.0, 20.0, 30.0]:
		transport.set_link(2, rtt, 0.0)
		metrics.sample_peer(transport, 2)
	var snapshot := metrics.get_snapshot(2)
	assert_almost_eq(snapshot["latest"]["rtt_msec"], 30.0, 0.001)
	assert_almost_eq(snapshot["average"]["rtt_msec"], 20.0, 0.001)

func test_unknown_peer_snapshot_is_empty() -> void:
	assert_true(metrics.get_snapshot(99).is_empty())

func test_forget_peer_drops_window_and_restarts_baseline() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.RTT_ONLY)
	transport.set_link(2, 40.0, 0.0)
	_sample_after_baseline(2)
	metrics.forget_peer(2)
	assert_true(metrics.get_snapshot(2).is_empty())
	assert_true(metrics.sample_peer(transport, 2).is_empty())

func test_set_mode_clears_all_windows() -> void:
	metrics.set_mode(GdLinkMetrics.Mode.RTT_ONLY)
	transport.set_link(2, 40.0, 0.0)
	_sample_after_baseline(2)
	metrics.set_mode(GdLinkMetrics.Mode.ALL)
	assert_true(metrics.get_snapshot(2).is_empty())

func test_default_mode_is_off() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	_tick(5.0)
	assert_true(session.metrics.windows.is_empty())

func test_tick_waits_for_one_full_interval() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(0.9)
	assert_true(session.metrics.windows.is_empty())
	_tick(0.2)
	assert_true(session.metrics.windows.has(4))

func test_sampled_metrics_emitted_per_authenticated_peer() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(1.0)
	session_transport.record_in(4, 12)
	watch_signals(session)
	_tick(1.0)
	assert_signal_emit_count(session, "metrics_sampled", 1)
	assert_eq(get_signal_parameters(session, "metrics_sampled", 0)[0], 4)
	assert_almost_eq(get_signal_parameters(session, "metrics_sampled", 0)[1]["bytes_in"], 12.0, 0.001)

func test_unauthenticated_peer_is_not_sampled() -> void:
	session.host(FAKE_PORT)
	session_transport.peer_connected.emit(9)
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(1.0)
	_tick(1.0)
	assert_false(session.metrics.windows.has(9))

func test_client_samples_host_link() -> void:
	session.join(FAKE_ADDRESS)
	session_transport.control_received.emit(1, _accept_payload(7))
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(1.0)
	session_transport.record_in(1, 6)
	watch_signals(session)
	_tick(1.0)
	assert_eq(get_signal_parameters(session, "metrics_sampled", 0)[0], GdLinkCore.HOST_PEER_IDENTIFIER)

func test_get_metrics_returns_latest_for_peer() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(1.0)
	session_transport.record_out(4, 20)
	_tick(1.0)
	assert_almost_eq(session.get_metrics(4)["latest"]["bytes_out"], 20.0, 0.001)

func test_peer_removal_clears_metrics() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(1.0)
	_tick(1.0)
	session_transport.peer_disconnected.emit(4, GdLinkCore.DisconnectReason.VOLUNTARY)
	assert_true(session.get_metrics(4).is_empty())

func test_host_restart_clears_metrics_state() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(1.0)
	_tick(1.0)
	session.host(FAKE_PORT)
	assert_true(session.metrics.windows.is_empty())

func test_off_mode_stops_sampling_and_clears_windows() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_metrics_mode(GdLinkMetrics.Mode.DATA_IO_ONLY)
	_tick(1.0)
	_tick(1.0)
	session.set_metrics_mode(GdLinkMetrics.Mode.OFF)
	assert_true(session.get_metrics(4).is_empty())
	_tick(5.0)
	assert_true(session.metrics.windows.is_empty())
