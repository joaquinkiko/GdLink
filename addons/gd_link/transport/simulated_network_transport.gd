## Wraps a Transport and impairs outbound traffic for local testing.
class_name SimulatedNetworkTransport
extends Transport

## Impairment settings
class Profile extends RefCounted:
	var base_latency_msec := 0
	var jitter_msec := 0
	var drop_chance := 0.0 # of 1.0
	var reorder_chance := 0.0 # of 1.0
	var reorder_extra_msec := 0
	var spike_chance := 0.0 # of 1.0
	var spike_msec := 0
	var random_seed := 1

## Added to a reliable frame when a simulated loss would have occurred.
const RETRANSMIT_PENALTY_MSEC := 100

var _inner: Transport
var _profile: Profile
var _random := RandomNumberGenerator.new()
var _clock: Callable
var _pending: Array[Dictionary] = []
var _last_reliable_due_msec := 0

func _init(inner_transport: Transport, profile: Profile = null, clock: Callable = Callable()) -> void:
	_inner = inner_transport
	if profile != null:
		_profile = profile
	else:
		_profile = Profile.new()
	if clock.is_valid():
		_clock = clock
	else:
		_clock = Callable(Time, "get_ticks_msec")
	_random.seed = _profile.random_seed
	_inner.peer_connected.connect(peer_connected.emit)
	_inner.peer_disconnected.connect(peer_disconnected.emit)
	_inner.control_received.connect(control_received.emit)
	_inner.data_received.connect(data_received.emit)
	_inner.join_succeeded.connect(join_succeeded.emit)
	_inner.join_failed.connect(join_failed.emit)

func poll() -> void:
	_inner.poll()
	var now: int = _clock.call()
	var index := 0
	while index < _pending.size():
		if _pending[index]["due_msec"] > now:
			index += 1
			continue
		var action: Callable = _pending.pop_at(index)["action"]
		action.call()

func host(bind_address: String) -> Error:
	return _inner.host(bind_address)

func join(join_address: String) -> Error:
	return _inner.join(join_address)

## Drops queued sends to the peer, then disconnects immediately.
func disconnect_peer(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
	var kept: Array[Dictionary] = []
	for item: Dictionary in _pending:
		if item["peer"] != peer_identifier:
			kept.append(item)
	_pending = kept
	_inner.disconnect_peer(peer_identifier, reason)

## Discards queued sends, then closes immediately.
func close(reason: GdLinkCore.DisconnectReason) -> void:
	_pending.clear()
	_inner.close(reason)

func send_control(peer_identifier: int, payload: PackedByteArray) -> void:
	_queue_send(peer_identifier, true, func() -> void:
		_inner.send_control(peer_identifier, payload)
		)

func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
	_queue_send(peer_identifier, reliable, func() -> void:
		_inner.send_data(peer_identifier, channel, payload, reliable)
		)

func get_identity(peer_identifier: int) -> String:
	return _inner.get_identity(peer_identifier)

func _queue_send(peer_identifier: int, reliable: bool, action: Callable) -> void:
	var delay := _compute_delay()
	if _random.randf() < _profile.drop_chance:
		if not reliable:
			return
		delay += RETRANSMIT_PENALTY_MSEC
	elif not reliable && _random.randf() < _profile.reorder_chance:
		delay += _profile.reorder_extra_msec
	var due: int = _clock.call() + delay
	if reliable:
		due = max(due, _last_reliable_due_msec)
		_last_reliable_due_msec = due
	_pending.append({"peer": peer_identifier, "due_msec": due, "action": action})

func _compute_delay() -> int:
	var delay := _profile.base_latency_msec + _random.randi_range(-_profile.jitter_msec, _profile.jitter_msec)
	if _random.randf() < _profile.spike_chance:
		delay += _profile.spike_msec
	return max(delay, 0)

static func preset_lan() -> Profile:
	var profile := Profile.new()
	profile.base_latency_msec = 5
	profile.jitter_msec = 2
	return profile

static func preset_wan() -> Profile:
	var profile := Profile.new()
	profile.base_latency_msec = 60
	profile.jitter_msec = 15
	profile.drop_chance = 0.01
	profile.reorder_chance = 0.02
	profile.reorder_extra_msec = 40
	profile.spike_chance = 0.005
	profile.spike_msec = 300
	return profile

static func preset_hostile() -> Profile:
	var profile := Profile.new()
	profile.base_latency_msec = 150
	profile.jitter_msec = 60
	profile.drop_chance = 0.05
	profile.reorder_chance = 0.1
	profile.reorder_extra_msec = 120
	profile.spike_chance = 0.03
	profile.spike_msec = 800
	return profile
