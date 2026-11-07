## Host/client session lifecycle: connection, authentication, and peer tracking.
class_name Session
extends Node

## Single-byte payload the host sends to accept a client's hello.
const ACCEPT_BYTE := GdLinkCore.ControlMessage.ACCEPT
## Total size of an accept message
const ACCEPT_SIZE := 5
## Max queued packets during a scene swap gate before packets are dropped.
const MAX_DEFERRED_DATA := 1024

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
## Client: scene set by the host.
signal scene_changed(scene: String, args: Dictionary)
## Host: host has not confirmed the scene within the timeout. Barrier stays open; game decides next steps.
signal scene_load_stalled(epoch: int)
## Host: emitted once the host has closed and all peers are gone.
signal hosting_stopped
## Emitted when barrier or overflow drops data. Unreliable sends drop during barriers.
signal data_dropped(peer_identifier: int, channel: int)

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
## Client: identifier assigned by the host.
var local_identifier := 0
## Host: timeout applied to the open barrier.
var scene_timeout_seconds := 0.0
## True if we are stopping hosting
var is_stopping_host := false
## Reliable sends queued while the scene gate is open.
var deferred_sends: Array[Dictionary]
## Inbound data queued while the scene gate is open.
var deferred_inbound: Array[Dictionary]

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
	scene_gate.close()
	_clear_deferred()
	return transport.join(join_address)

## Client: closes the session with DisconnectReason.VOLUNTARY.
func leave() -> void:
	if is_hosting || transport == null:
		return
	transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)

## Host: disconnects a peer with reason. No-op on clients.
func kick(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
	if is_hosting:
		transport.disconnect_peer(peer_identifier, reason)

func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
	if not _is_channel_allowed(channel) || payload.size() > GdLinkCore.MAX_PAYLOAD_BYTES:
		return
	if not _is_peer_reachable(peer_identifier):
		return
	if scene_gate.is_open:
		if reliable:
			_defer(
				deferred_sends,
				{"peer": peer_identifier, "channel": channel, "payload": payload, "reliable": reliable}
				)
		else:
			data_dropped.emit(peer_identifier, channel)
		return
	transport.send_data(peer_identifier, channel, payload, reliable)

func _on_data_received(peer_identifier: int, channel: int, payload: PackedByteArray) -> void:
	if not _is_channel_allowed(channel):
		return
	if scene_gate.is_open:
		_defer(deferred_inbound, {"peer": peer_identifier, "channel": channel, "payload": payload})
		return
	if not _is_peer_reachable(peer_identifier):
		return
	data_received.emit(peer_identifier, channel, payload)

func _is_peer_reachable(peer_identifier: int) -> bool:
	if not is_hosting:
		return is_client_authenticated
	var peer := get_peer(peer_identifier)
	return peer != null && peer.is_authenticated()

## Queues an entry, or emits data_dropped if the queue is full.
func _defer(queue: Array[Dictionary], entry: Dictionary) -> void:
	if queue.size() >= MAX_DEFERRED_DATA:
		data_dropped.emit(entry["peer"], entry["channel"])
		return
	queue.append(entry)

## Sends queued data now that the gate is closed. Reachability is rechecked per entry.
func _flush_deferred() -> void:
	var outbound := deferred_sends.duplicate()
	var inbound := deferred_inbound.duplicate()
	deferred_sends.clear()
	deferred_inbound.clear()
	for entry: Dictionary in outbound:
		send_data(entry["peer"], entry["channel"], entry["payload"], entry["reliable"])
	for entry: Dictionary in inbound:
		_on_data_received(entry["peer"], entry["channel"], entry["payload"])

func _clear_deferred() -> void:
	deferred_sends.clear()
	deferred_inbound.clear()

func _is_channel_allowed(channel: int) -> bool:
	return channel >= 0 and channel < GdLinkCore.RESERVED_CHANNEL_LIMIT

func _is_route_open(peer_identifier: int) -> bool:
	if scene_gate.is_open: return false
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
		if get_peer(peer_identifier) == null: return
		if not _is_valid_client_message(peer_identifier, message_type, payload.size()):
			transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.AUTH_REJECT_MALFORMED)
			return
		if message_type == GdLinkCore.ControlMessage.SCENE_LOADED:
			_handle_scene_loaded(peer_identifier, payload)
		else:
			_handle_client_control(peer_identifier, message_type, payload.slice(1))
	elif message_type == ACCEPT_BYTE and payload.size() == ACCEPT_SIZE:
		is_client_authenticated = true
		local_identifier = payload.decode_u32(1)
		join_succeeded.emit(local_identifier)
	elif is_client_authenticated and peer_identifier == GdLinkCore.HOST_PEER_IDENTIFIER:
		_handle_host_message(payload)

## Host: true if the type is allowed from this peer's state. Pre-auth HELLO is size-capped.
func _is_valid_client_message(peer_identifier: int, message_type: int, size: int) -> bool:
	var peer: Peer = peers.get(peer_identifier)
	if peer == null: return false
	if peer.is_authenticated():
		return message_type == GdLinkCore.ControlMessage.SCENE_LOADED
	return message_type == GdLinkCore.ControlMessage.HELLO \
		and size <= authenticator.get_max_hello_bytes() + 1

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
		if scene_gate.remove_peer(peer_identifier):
			_check_scene_barrier()
		if is_stopping_host and peers.is_empty():
			_finish_hosting()
	elif is_client_authenticated:
		is_client_authenticated = false
		scene_gate.close()
		_clear_deferred()
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
	if scene_gate.is_open:
		transport.send_control(peer_identifier,
			SceneCodec.encode_set(scene_gate.epoch, scene_gate.current_scene, scene_gate.current_args))
		scene_gate.add_pending(peer_identifier)
		_start_load_timeout(peer_identifier)
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
func swap_scene(scene: String, args: Dictionary, timeout_seconds := GdLinkCore.SCENE_LOAD_TIMEOUT_SECONDS) -> Error:
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
	scene_timeout_seconds = timeout_seconds
	_broadcast_scene_set()
	for peer: Peer in get_authenticated_peers():
		_start_load_timeout(peer.peer_identifier)
	_check_scene_barrier()
	get_tree().create_timer(scene_timeout_seconds).timeout.connect(
		_on_host_load_timeout.bind(scene_gate.epoch)
		)
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
	_flush_deferred()
	scene_ready.emit(completed_epoch)

## Host and client: call once the scene has loaded. Host confirms itself.
func confirm_scene_loaded() -> void:
	if is_hosting:
		_confirm_scene(GdLinkCore.HOST_PEER_IDENTIFIER, scene_gate.epoch)
	elif scene_gate.is_open:
		transport.send_control(GdLinkCore.HOST_PEER_IDENTIFIER,
			SceneCodec.encode_confirm(GdLinkCore.ControlMessage.SCENE_LOADED, scene_gate.epoch))

func _confirm_scene(peer_identifier: int, confirm_epoch: int) -> void:
	if scene_gate.confirm(peer_identifier, confirm_epoch):
		_check_scene_barrier()

## Client: routes host messages to scene or meta handlers.
func _handle_host_message(payload: PackedByteArray) -> void:
	var message_type := payload[0]
	if message_type == GdLinkCore.ControlMessage.SCENE_SET:
		_handle_scene_set(payload)
	elif message_type == GdLinkCore.ControlMessage.SCENE_READY:
		_handle_scene_ready(payload)
	else:
		_handle_host_meta(payload)

func _handle_scene_set(payload: PackedByteArray) -> void:
	var message := SceneCodec.decode(payload)
	if message.is_empty():
		return
	scene_gate.adopt_swap(message["epoch"], message["scene"], message["args"], local_identifier)
	scene_changed.emit(message["scene"], message["args"])

## Client: in _handle_scene_ready, flush before emitting scene_ready
func _handle_scene_ready(payload: PackedByteArray) -> void:
	var message := SceneCodec.decode(payload)
	if message.is_empty() || not (scene_gate.is_open && message["epoch"] == scene_gate.epoch):
		return
	scene_gate.close()
	_flush_deferred()
	scene_ready.emit(message["epoch"])

## Host: records a client's scene confirm. Duplicates, stale epochs, and unknown senders are ignored.
func _handle_scene_loaded(peer_identifier: int, payload: PackedByteArray) -> void:
	var message := SceneCodec.decode(payload)
	if message.is_empty():
		return
	_confirm_scene(peer_identifier, message["epoch"])

func _start_load_timeout(peer_identifier: int) -> void:
	get_tree().create_timer(scene_timeout_seconds).timeout.connect(
		_on_scene_load_timeout.bind(scene_gate.epoch, peer_identifier))

## Host: kicks a peer still pending on the same epoch. Stale timers no-op.
func _on_scene_load_timeout(timeout_epoch: int, peer_identifier: int) -> void:
	if not (timeout_epoch == scene_gate.epoch && scene_gate.is_pending(peer_identifier)):
		return
	transport.disconnect_peer(peer_identifier, GdLinkCore.DisconnectReason.SCENE_LOAD_TIMEOUT)

## Host: emits once per epoch when the host itself is still pending. Takes no other action.
func _on_host_load_timeout(timeout_epoch: int) -> void:
	if not (timeout_epoch == scene_gate.epoch && scene_gate.is_pending(GdLinkCore.HOST_PEER_IDENTIFIER)):
		return
	scene_load_stalled.emit(timeout_epoch)

## Host: disconnects all peers. Host state resets after the last peer disconnect event.
func stop_hosting() -> void:
	if not is_hosting || is_stopping_host:
		return
	is_stopping_host = true
	transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	if peers.is_empty():
		_finish_hosting()

func _finish_hosting() -> void:
	is_hosting = false
	is_stopping_host = false
	host_peer = null
	server_meta.clear()
	pending_meta.clear()
	scene_gate.close()
	_clear_deferred()
	metrics.clear()
	hosting_stopped.emit()
