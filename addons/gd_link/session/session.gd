## Host/client session lifecycle: connection, authentication, and peer tracking.
class_name Session
extends Node

## Single-byte payload the host sends to accept a client's hello.
const ACCEPT_BYTE := 1

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

## Active transport.
var transport: Transport
## Active authenticator.
var authenticator: Authenticator
## True if currently hosting.
var is_hosting := false
## Client only. True once the host accepts the hello.
var is_client_authenticated := false
## Host only. Peer objects keyed by peer identifier.
var peers: Dictionary = {}

func _process(_delta: float) -> void:
	if transport != null: transport.poll()

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
	is_hosting = true
	return transport.host(bind_address)

## Joins the host at join_address. Returns the transport's error code.
func join(join_address: String) -> Error:
	is_hosting = false
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
	transport.send_control(server_peer_identifier, authenticator.build_hello())

func _on_control_received(peer_identifier: int, payload: PackedByteArray) -> void:
	if is_hosting:
		_handle_hello(peer_identifier, payload)
	elif payload.size() == 5 and payload[0] == ACCEPT_BYTE:
		is_client_authenticated = true
		join_succeeded.emit(payload.decode_u32(1))

## Host: verifies the hello once. Replays from authenticated peers are ignored.
func _handle_hello(peer_identifier: int, payload: PackedByteArray) -> void:
	var peer: Peer = peers.get(peer_identifier)
	if peer == null or peer.state != Peer.State.AWAITING_HELLO: return
	var reason := authenticator.verify_hello(peer.identity, payload)
	if reason != GdLinkCore.DisconnectReason.NONE:
		transport.disconnect_peer(peer_identifier, reason)
		return
	peer.mark_authenticated()
	transport.send_control(peer_identifier, _build_accept(peer_identifier))
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
		if peer != null: peer_removed.emit(peer, reason)
	elif is_client_authenticated:
		is_client_authenticated = false
		session_closed.emit(reason)
	else:
		join_failed.emit(reason)

func _build_accept(assigned_identifier: int) -> PackedByteArray:
	var accept := PackedByteArray()
	accept.resize(5)
	accept[0] = ACCEPT_BYTE
	accept.encode_u32(1, assigned_identifier)
	return accept
