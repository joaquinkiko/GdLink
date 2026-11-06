extends GutTest

class FakeTransport extends Transport:
	var sent_data: Array = []
	var sent_controls: Array = []
	var disconnected_calls: Array = []
	var hosted_address := ""
	var joined_address := ""
	var identities: Dictionary = {}

	func poll() -> void:
		pass

	func host(bind_address: String) -> Error:
		hosted_address = bind_address
		return OK

	func join(join_address: String) -> Error:
		joined_address = join_address
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

var payload := PackedByteArray([1, 2, 3])

var inner: FakeTransport
var now_msec := 0
var wrapper: SimulatedNetworkTransport

func before_each() -> void:
	now_msec = 0
	inner = FakeTransport.new()

func _make(profile: SimulatedNetworkTransport.Profile) -> SimulatedNetworkTransport:
	wrapper = SimulatedNetworkTransport.new(inner, profile, Callable(self, "_clock_now"))
	watch_signals(wrapper)
	return wrapper

func _clock_now() -> int:
	return now_msec

func _profile() -> SimulatedNetworkTransport.Profile:
	return SimulatedNetworkTransport.Profile.new()

## Advances the fake clock to msec and polls the wrapper.
func _advance_to(msec: int) -> void:
	now_msec = msec
	wrapper.poll()

func _delivered_count() -> int:
	return get_signal_emit_count(wrapper, "data_received")

# Passthrough

func test_host_and_join_forward_to_inner() -> void:
	_make(_profile())
	wrapper.host("7790")
	wrapper.join("127.0.0.1:7790")
	assert_eq(inner.hosted_address, "7790")
	assert_eq(inner.joined_address, "127.0.0.1:7790")

func test_identity_forwards_to_inner() -> void:
	_make(_profile())
	inner.identities[2] = "10.0.0.2"
	assert_eq(wrapper.get_identity(2), "10.0.0.2")

func test_inner_signals_forward_through_wrapper() -> void:
	_make(_profile())
	inner.peer_connected.emit(2)
	inner.join_succeeded.emit(1)
	assert_signal_emitted_with_parameters(wrapper, "peer_connected", [2])
	assert_signal_emitted_with_parameters(wrapper, "join_succeeded", [1])

# Latency and jitter

func test_message_is_held_until_base_latency_elapses() -> void:
	var profile := _profile()
	profile.base_latency_msec = 50
	_make(profile)
	wrapper.send_data(2, 0, payload, true)
	_advance_to(49)
	assert_eq(inner.sent_data.size(), 0)
	_advance_to(50)
	assert_eq(inner.sent_data.size(), 1)

func test_jitter_keeps_delivery_within_bounds() -> void:
	var profile := _profile()
	profile.base_latency_msec = 50
	profile.jitter_msec = 10
	_make(profile)
	for index in 20:
		wrapper.send_data(2, 0, payload, false)
	_advance_to(39)
	assert_eq(inner.sent_data.size(), 0, "delivered before minimum jitter bound")
	_advance_to(60)
	assert_eq(inner.sent_data.size(), 20, "not all delivered by maximum jitter bound")

func test_spike_adds_spike_msec_to_delay() -> void:
	var profile := _profile()
	profile.base_latency_msec = 10
	profile.spike_chance = 1.0
	profile.spike_msec = 300
	_make(profile)
	wrapper.send_data(2, 0, payload, false)
	_advance_to(309)
	assert_eq(inner.sent_data.size(), 0)
	_advance_to(310)
	assert_eq(inner.sent_data.size(), 1)

func test_zero_delay_sends_on_next_poll() -> void:
	_make(_profile())
	wrapper.send_data(2, 0, payload, true)
	assert_eq(inner.sent_data.size(), 0, "send bypassed the queue")
	_advance_to(0)
	assert_eq(inner.sent_data.size(), 1)

# Drop

func test_unreliable_drop_never_delivers() -> void:
	var profile := _profile()
	profile.drop_chance = 1.0
	_make(profile)
	for index in 10:
		wrapper.send_data(2, 0, payload, false)
	_advance_to(1000)
	assert_eq(inner.sent_data.size(), 0)

func test_reliable_is_never_dropped() -> void:
	var profile := _profile()
	profile.drop_chance = 1.0
	_make(profile)
	for index in 5:
		wrapper.send_data(2, 0, payload, true)
	_advance_to(SimulatedNetworkTransport.RETRANSMIT_PENALTY_MSEC)
	assert_eq(inner.sent_data.size(), 5)

func test_reliable_drop_adds_retransmit_penalty() -> void:
	var profile := _profile()
	profile.drop_chance = 1.0
	_make(profile)
	wrapper.send_data(2, 0, payload, true)
	var penalty := SimulatedNetworkTransport.RETRANSMIT_PENALTY_MSEC
	_advance_to(penalty - 1)
	assert_eq(inner.sent_data.size(), 0)
	_advance_to(penalty)
	assert_eq(inner.sent_data.size(), 1)

func test_same_seed_produces_same_drop_pattern() -> void:
	var first_count := _count_deliveries_with_seed(42)
	var second_count := _count_deliveries_with_seed(42)
	assert_eq(first_count, second_count)
	assert_gt(first_count, 0)
	assert_lt(first_count, 100)

func _count_deliveries_with_seed(seed_value: int) -> int:
	var profile := _profile()
	profile.drop_chance = 0.5
	profile.random_seed = seed_value
	inner = FakeTransport.new()
	_make(profile)
	for index in 100:
		wrapper.send_data(2, 0, payload, false)
	_advance_to(0)
	return inner.sent_data.size()

# Reorder and ordering

func test_reorder_lets_later_unreliable_arrive_first() -> void:
	var profile := _profile()
	profile.base_latency_msec = 10
	profile.reorder_chance = 1.0
	profile.reorder_extra_msec = 100
	_make(profile)
	wrapper.send_data(2, 0, PackedByteArray([1]), false)
	profile.reorder_chance = 0.0
	wrapper.send_data(2, 0, PackedByteArray([2]), false)
	_advance_to(10)
	assert_eq(inner.sent_data.size(), 1)
	assert_eq(inner.sent_data[0]["payload"], PackedByteArray([2]))

func test_reliable_order_holds_under_spike() -> void:
	var profile := _profile()
	profile.spike_chance = 1.0
	profile.spike_msec = 200
	_make(profile)
	wrapper.send_data(2, 0, PackedByteArray([1]), true)
	profile.spike_chance = 0.0
	wrapper.send_data(2, 0, PackedByteArray([2]), true)
	_advance_to(199)
	assert_eq(inner.sent_data.size(), 0)
	_advance_to(200)
	assert_eq(inner.sent_data.size(), 2)
	assert_eq(inner.sent_data[0]["payload"], PackedByteArray([1]))
	assert_eq(inner.sent_data[1]["payload"], PackedByteArray([2]))

func test_control_is_sent_on_reliable_path_with_latency() -> void:
	var profile := _profile()
	profile.base_latency_msec = 20
	_make(profile)
	wrapper.send_control(2, payload)
	_advance_to(19)
	assert_eq(inner.sent_controls.size(), 0)
	_advance_to(20)
	assert_eq(inner.sent_controls, [[2, payload]])

# Teardown

func test_close_discards_pending_sends() -> void:
	var profile := _profile()
	profile.base_latency_msec = 100
	_make(profile)
	wrapper.send_data(2, 0, payload, true)
	wrapper.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	_advance_to(1000)
	assert_eq(inner.sent_data.size(), 0)

func test_disconnect_peer_discards_only_that_peers_pending() -> void:
	var profile := _profile()
	profile.base_latency_msec = 100
	_make(profile)
	wrapper.send_data(2, 0, payload, true)
	wrapper.send_data(3, 0, payload, true)
	wrapper.disconnect_peer(2, GdLinkCore.DisconnectReason.KICKED)
	_advance_to(100)
	assert_eq(inner.sent_data.size(), 1)
	assert_eq(inner.sent_data[0]["peer"], 3)

func test_disconnect_peer_reaches_inner_immediately() -> void:
	var profile := _profile()
	profile.base_latency_msec = 100
	_make(profile)
	wrapper.disconnect_peer(2, GdLinkCore.DisconnectReason.KICKED)
	assert_eq(inner.disconnected_calls, [[2, GdLinkCore.DisconnectReason.KICKED]])

# Presets

func test_lan_preset_is_low_latency_without_loss() -> void:
	var profile := SimulatedNetworkTransport.preset_lan()
	assert_lt(profile.base_latency_msec, 20)
	assert_eq(profile.drop_chance, 0.0)

func test_wan_preset_has_loss_and_reorder() -> void:
	var profile := SimulatedNetworkTransport.preset_wan()
	assert_gt(profile.drop_chance, 0.0)
	assert_gt(profile.reorder_chance, 0.0)

func test_hostile_preset_is_worse_than_wan() -> void:
	var wan := SimulatedNetworkTransport.preset_wan()
	var hostile := SimulatedNetworkTransport.preset_hostile()
	assert_gt(hostile.base_latency_msec, wan.base_latency_msec)
	assert_gt(hostile.drop_chance, wan.drop_chance)
