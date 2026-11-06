## Host/client session lifecycle: connection, authentication, and peer tracking.
class_name Session
extends Node

## Single-byte payload the host sends to accept a client's hello.
const ACCEPT_BYTE := GdLinkCore.ControlMessage.ACCEPT
## Total size of an accept message
const ACCEPT_SIZE := 5

## Client: emitted after the host accepts the hello.
signal join_succeeded(assigned_identifier: int)
## Client: emitted when the join fails before authentication.
signal join_failed(reason: GdLinkCore.DisconnectReason)
## Client: emitted when an authenticated session ends.
signal session_closed(reason: GdLinkCore.DisconnectReason)
## Host: emitted when a peer passes authentication.
signal peer_authenticated(peer: Peer)
## Host: emitted when a peer leaves or is removed.
signal peer_removed(peer: Peer, reason: GdLinkCore.DisconnectReason)
## Emitted when packet data is received.
signal data_received(peer_identifier: int, channel: int, payload: PackedByteArray)
## Client: server meta key set or changed.
signal server_meta_changed(key: StringName, value: Variant)
## Client: server meta key erased.
signal server_meta_removed(key: StringName)
## Client: peer meta key set or changed.
signal peer_meta_changed(peer_identifier: int, key: StringName, value: Variant)
## Client: peer meta key erased.
signal peer_meta_removed(peer_identifier: int, key: StringName)
## Client: host finished sending the meta snapshot.
signal meta_synchronized
## Emitted each sample tick for each peer that has a sample.
signal metrics_sampled(peer_identifier: int, sample: Dictionary)
## Host and client: scene barrier completed for epoch.
signal scene_ready(epoch: int)

## Active transport.
var transport: Transport
## Active authenticator.
var authenticator: Authenticator
## Scene barrier. Host owns the epoch and pending set.
var scene_gate := SceneGate.new()
## True if currently hosting.
var is_hosting := false
## Client only. True once the host accepts the hello.
var is_client_authenticated := false
## Host only. Peer objects keyed by peer identifier.
var peers: Dictionary = {}
## Host only. Queued meta messages: peer_identifier -> {key: encoded message}. Flushed each frame.
var pending_meta: Dictionary
## Client only. Host-owned peer meta mirror, keyed by peer identifier.
var remote_peer_meta: Dictionary
## Host only. Owns host-side peer meta under HOST_PEER_IDENTIFIER. Not in peers.
var host_peer: Peer
## Server specific meta
var server_meta: Dictionary
## Runtime metrics sampler. Mode is set with set_metrics_mode().
var metrics := GdLinkMetrics.new()
var metrics_accumulator := 0.0

func _process(delta: float) -> void:
	if transport != null: transport.poll()
	if is_hosting: _flush_meta()
	_tick_metrics(delta)

## Returns the peer for peer_identifier, or null if unknown.
func get_peer(peer_identifier: int) -> Peer:
	return peers.get(peer_identifier)

## Returns all peers that have passed authentication.
func get_authenticated_peers() -> Array[Peer]:
	var result: Array[Peer] = []
	for peer: Peer in peers.values():
		if peer.is_authenticated(): result.append(peer)
	return result

## Wires the transport and authenticator to this session. Call once before host() or join().
func setup(transport_instance: Transport, authenticator_instance: Authenticator) -> void:
	transport = transport_instance
	authenticator = authenticator_instance
	transport.peer_connected.connect(_on_peer_connected)
	transport.peer_disconnected.connect(_on_peer_disconnected)
	transport.control_received.connect(_on_control_received)
	transport.join_succeeded.connect(_on_join_succeeded)
	transport.join_failed.connect(join_failed.emit)
	transport.data_received.connect(_on_data_received)

## Starts hosting on bind_address. Returns the transport's error code.
func host(bind_address: String) -> Error:
	metrics.clear()
	is_hosting = true
	host_peer = Peer.new(GdLinkCore.HOST_PEER_IDENTIFIER, "")
	host_peer.mark_authenticated()
	return transport.host(bind_address)

## Joins the host at join_address. Returns the transport's error code.
func join(join_address: String) -> Error:
	metrics.clear()
	is_hosting = false
	host_peer = null
	_clear_client_meta()
	return transport.join(join_address)

## Client: closes the session with DisconnectReason.VOLUNTARY.
func leave() -> void:
	transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)

## Host: disconnects a peer with reason. No-op on clients.
func kick(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
	if is_hosting:
		transport.disconnect_peer(peer_identifier, reason)

func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
	if not _is_channel_allowed(channel) or payload.size() > GdLinkCore.MAX_PAYLOAD_BYTES: return
	if not _is_route_open(peer_identifier): return
	transport.send_data(peer_identifier, channel, payload, reliable)

func _on_data_received(peer_identifier: int, channel: int, payload: PackedByteArray) -> void:
	if not _is_channel_allowed(channel) or not _is_route_open(peer_identifier): return
	data_received.emit(peer_identifier, channel, payload)

func _is_channel_allowed(channel: int) -> bool:
	return channel >= 0 and channel < GdLinkCore.RESERVED_CHANNEL_LIMIT

func _is_route_open(peer_identifier: int) -> bool:
	if not is_hosting: return is_client_authenticated
	var peer := get_peer(peer_identifier)
	return peer != null and peer.is_authenticated()

func _on_peer_connected(peer_identifier: int) -> void:
	if not is_hosting: return
	var peer := Peer.new(peer_identifier, transport.get_identity(peer_identifier))
	if peer == null:
		transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH)
		return
	peer.state = Peer.State.AWAITING_HELLO
	peers[peer_identifier] = peer
	get_tree().create_timer(GdLinkCore.AUTHENTICATION_TIMEOUT_SECONDS).timeout.connect(
		_on_authentication_timeout.bind(peer_identifier))

func _on_join_succeeded(server_peer_identifier: int) -> void:
	transport.send_control(server_peer_identifier, _build_hello_message())

func _build_hello_message() -> PackedByteArray:
	var message := PackedByteArray([GdLinkCore.ControlMessage.HELLO])
	message.append_array(authenticator.build_hello())
	return message

func _on_control_received(peer_identifier: int, payload: PackedByteArray) -> void:
	if payload.is_empty(): return
	var message_type := payload[0]
	if is_hosting:
		_handle_client_control(peer_identifier, message_type, payload.slice(1))
	elif message_type == ACCEPT_BYTE and payload.size() == ACCEPT_SIZE:
		is_client_authenticated = true
		join_succeeded.emit(payload.decode_u32(1))
	elif is_client_authenticated and peer_identifier == GdLinkCore.HOST_PEER_IDENTIFIER:
		_handle_host_meta(payload)

## Host: dispatches client control. Only HELLO is accepted from clients.
func _handle_client_control(peer_identifier: int, message_type: int, body: PackedByteArray) -> void:
	var peer: Peer = peers.get(peer_identifier)
	if peer == null: return
	if message_type == GdLinkCore.ControlMessage.HELLO:
		_handle_hello(peer, body)
	elif peer.state == Peer.State.AWAITING_HELLO:
		transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH)

## Host: verifies the hello once. Replays from authenticated peers are ignored.
func _handle_hello(peer: Peer, body: PackedByteArray) -> void:
	if peer.state != Peer.State.AWAITING_HELLO: return
	var reason := authenticator.verify_hello(peer.identity, body)
	if reason != GdLinkCore.DisconnectReason.NONE:
		transport.disconnect_peer(peer.peer_identifier, reason)
		return
	peer.mark_authenticated()
	transport.send_control(peer.peer_identifier, _build_accept(peer.peer_identifier))
	_send_meta_snapshot(peer.peer_identifier)
	peer_authenticated.emit(peer)

## Host: drops the peer if it is still awaiting hello. Stale timers no-op.
func _on_authentication_timeout(peer_identifier: int) -> void:
	var peer: Peer = peers.get(peer_identifier)
	if peer != null and peer.state == Peer.State.AWAITING_HELLO:
		transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.AUTH_REJECT_TIMEOUT)

func _on_peer_disconnected(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
	if is_hosting:
		var peer: Peer = peers.get(peer_identifier)
		peers.erase(peer_identifier)
		metrics.forget_peer(peer_identifier)
		if peer != null:
			_clear_peer_meta(peer)
			peer_removed.emit(peer, reason)
	elif is_client_authenticated:
		is_client_authenticated = false
		metrics.forget_peer(GdLinkCore.HOST_PEER_IDENTIFIER)
		_clear_client_meta()
		session_closed.emit(reason)
	else:
		join_failed.emit(reason)

func _build_accept(assigned_identifier: int) -> PackedByteArray:
	var accept := PackedByteArray()
	accept.resize(5)
	accept[0] = ACCEPT_BYTE
	accept.encode_u32(1, assigned_identifier)
	return accept

## Returns the server meta dictionary. Host and client each hold their own copy.
func get_server_meta() -> Dictionary:
	return server_meta.duplicate(true)

## Returns peer meta for peer_identifier. Host reads authority, client reads its mirror.
func get_peer_meta(peer_identifier: int) -> Dictionary:
	if not is_hosting:
		var mirrored: Dictionary = remote_peer_meta.get(peer_identifier, {})
		return mirrored.duplicate(true)
	var owner := _get_meta_owner(peer_identifier)
	return owner.meta.duplicate(true) if owner != null else {}

## Host: sets a server meta value. Stores a deep copy so caller mutations cannot desync clients.
func set_server_meta(key: StringName, value: Variant) -> void:
	if not _can_write_meta() or not MetaCodec.is_valid_key(key) or not MetaCodec.is_valid_value(value): return
	server_meta[key] = bytes_to_var(var_to_bytes(value))
	_queue_meta(0, key, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, key, value))

## Host: erases a server meta key if present.
func erase_server_meta(key: StringName) -> void:
	if _can_write_meta() and server_meta.erase(key):
		_queue_meta(0, key, MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_SERVER_ERASE, 0, key))

## Host: sets a value on an authenticated peer's meta. Peer 1 is the host.
func set_peer_meta(peer_identifier: int, key: StringName, value: Variant) -> void:
	var owner := _get_meta_owner(peer_identifier)
	if not _can_write_meta() or owner == null or not owner.is_authenticated(): return
	if not MetaCodec.is_valid_key(key) or not MetaCodec.is_valid_value(value): return
	owner.meta[key] = bytes_to_var(var_to_bytes(value))
	_queue_meta(owner.peer_identifier, key, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, owner.peer_identifier, key, value))

## Host: erases a key from a peer's meta if present.
func erase_peer_meta(peer_identifier: int, key: StringName) -> void:
	var owner := _get_meta_owner(peer_identifier)
	if _can_write_meta() and owner != null and owner.meta.erase(key):
		_queue_meta(owner.peer_identifier, key, MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_PEER_ERASE, owner.peer_identifier, key))

func _can_write_meta() -> bool:
	if is_hosting:
		return true
	GdLinkCore.log_message(GdLinkCore.LogLevel.WARN, "Meta write ignored: only the host may write meta")
	return false

func _get_meta_owner(peer_identifier: int) -> Peer:
	if peer_identifier == GdLinkCore.HOST_PEER_IDENTIFIER:
		return host_peer
	return get_peer(peer_identifier)

## Host: stores the encoded message, overwriting any earlier pending change for the same key.
func _queue_meta(peer_identifier: int, key: StringName, message: PackedByteArray) -> void:
	if not pending_meta.has(peer_identifier): pending_meta[peer_identifier] = {}
	pending_meta[peer_identifier][key] = message

## Host: sends queued meta to authenticated peers in one pass, then clears the queue.
func _flush_meta() -> void:
	if pending_meta.is_empty(): return
	var recipients := get_authenticated_peers()
	for peer_identifier: int in pending_meta:
		for message: PackedByteArray in pending_meta[peer_identifier].values():
			for recipient: Peer in recipients:
				transport.send_control(recipient.peer_identifier, message)
	pending_meta.clear()

## Host: queues erasure of every key a client may hold for a removed peer, and drops its pending sets.
func _clear_peer_meta(peer: Peer) -> void:
	var keys: Array = peer.meta.keys()
	keys.append_array(pending_meta.get(peer.peer_identifier, {}).keys())
	pending_meta.erase(peer.peer_identifier)
	for key: StringName in keys:
		_queue_meta(peer.peer_identifier, key, MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_PEER_ERASE, peer.peer_identifier, key))

## Host: sends full meta state to one newly authenticated peer, then the end marker.
func _send_meta_snapshot(peer_identifier: int) -> void:
	for key: StringName in server_meta:
		transport.send_control(peer_identifier, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, key, server_meta[key]))
	var owners: Array[Peer] = [host_peer]
	owners.append_array(get_authenticated_peers())
	for owner: Peer in owners:
		for key: StringName in owner.meta:
			transport.send_control(peer_identifier, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, owner.peer_identifier, key, owner.meta[key]))
	transport.send_control(peer_identifier, MetaCodec.encode_snapshot_end())

## Client: applies one host meta message to the local mirror.
func _handle_host_meta(payload: PackedByteArray) -> void:
	var message := MetaCodec.decode(payload)
	if message.is_empty(): return
	var key: StringName = message.get("key", &"")
	match message["type"]:
		GdLinkCore.ControlMessage.META_SERVER_SET:
			server_meta[key] = message["value"]
			server_meta_changed.emit(key, message["value"])
		GdLinkCore.ControlMessage.META_SERVER_ERASE:
			server_meta.erase(key)
			server_meta_removed.emit(key)
		GdLinkCore.ControlMessage.META_PEER_SET:
			_remote_meta_for(message["peer"])[key] = message["value"]
			peer_meta_changed.emit(message["peer"], key, message["value"])
		GdLinkCore.ControlMessage.META_PEER_ERASE:
			_remote_meta_for(message["peer"]).erase(key)
			peer_meta_removed.emit(message["peer"], key)
		GdLinkCore.ControlMessage.META_SNAPSHOT_END:
			meta_synchronized.emit()

## Client: returns the mirror dictionary for peer_identifier, creating it if needed.
func _remote_meta_for(peer_identifier: int) -> Dictionary:
	if not remote_peer_meta.has(peer_identifier): remote_peer_meta[peer_identifier] = {}
	return remote_peer_meta[peer_identifier]

## Client: clears all mirrored meta.
func _clear_client_meta() -> void:
	server_meta.clear()
	remote_peer_meta.clear()

## Sets which metrics are collected. OFF disables sampling.
func set_metrics_mode(mode: GdLinkMetrics.Mode) -> void:
	metrics.set_mode(mode)
	metrics_accumulator = 0.0

## Returns {latest, average, min, max} for peer_identifier. Empty if unknown.
func get_metrics(peer_identifier: int) -> Dictionary:
	return metrics.get_snapshot(peer_identifier)

func _tick_metrics(delta: float) -> void:
	if not metrics.is_enabled():
		return
	metrics_accumulator += delta
	if metrics_accumulator < GdLinkMetrics.SAMPLE_INTERVAL_SECONDS:
		return
	metrics_accumulator -= GdLinkMetrics.SAMPLE_INTERVAL_SECONDS
	for peer_identifier: int in _get_metric_peer_identifiers():
		var sample := metrics.sample_peer(transport, peer_identifier)
		if not sample.is_empty():
			metrics_sampled.emit(peer_identifier, sample)

func _get_metric_peer_identifiers() -> Array[int]:
	var identifiers: Array[int] = []
	if not is_hosting:
		if is_client_authenticated:
			identifiers.append(GdLinkCore.HOST_PEER_IDENTIFIER)
		return identifiers
	for peer: Peer in get_authenticated_peers():
		identifiers.append(peer.peer_identifier)
	return identifiers

## Host: opens a scene barrier. Returns ERR_BUSY while one is open.
func swap_scene(scene: String, args: Dictionary) -> Error:
	if !is_hosting:
		return ERR_UNAUTHORIZED
	if scene_gate.is_open:
		return ERR_BUSY
	if not (SceneCodec.is_valid_scene(scene) && SceneCodec.is_valid_args(args)):
		return ERR_INVALID_PARAMETER
	var members: Array[int] = [GdLinkCore.HOST_PEER_IDENTIFIER]
	for peer: Peer in get_authenticated_peers():
		members.append(peer.peer_identifier)
	scene_gate.begin_swap(scene, args, members)
	_broadcast_scene_set()
	_check_scene_barrier()
	return OK

func _broadcast_scene_set() -> void:
	var message := SceneCodec.encode_set(scene_gate.epoch, scene_gate.current_scene, scene_gate.current_args)
	for peer: Peer in get_authenticated_peers():
		transport.send_control(peer.peer_identifier, message)

## Host: closes the barrier and broadcasts SCENE_READY once every member has confirmed.
func _check_scene_barrier() -> void:
	if !scene_gate.is_complete():
		return
	var completed_epoch := scene_gate.epoch
	scene_gate.close()
	var message := SceneCodec.encode_confirm(GdLinkCore.ControlMessage.SCENE_READY, completed_epoch)
	for peer: Peer in get_authenticated_peers():
		transport.send_control(peer.peer_identifier, message)
	scene_ready.emit(completed_epoch)

## Host and client: call once the scene has loaded. Host confirms itself.
func confirm_scene_loaded() -> void:
	if is_hosting:
		_confirm_scene(GdLinkCore.HOST_PEER_IDENTIFIER, scene_gate.epoch)

func _confirm_scene(peer_identifier: int, confirm_epoch: int) -> void:
	if scene_gate.confirm(peer_identifier, confirm_epoch):
		_check_scene_barrier()
