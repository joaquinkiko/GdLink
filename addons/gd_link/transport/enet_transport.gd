## ENet backend for Transport. Owns the ENetConnection and its event loop.
class_name ENetTransport
extends Transport

const CHANNEL_COUNT: int = GdLinkCore.CHANNEL_GDLINK + 1
const MAX_PEERS := 32

var connection: ENetConnection
var is_hosting := false
var is_client_connected := false
var next_identifier := 1
var packet_peers_by_identifier: Dictionary = {}
var identifiers_by_packet_peer: Dictionary = {}
var local_reasons_by_identifier: Dictionary = {}
var is_closing := false

func poll() -> void:
	while connection != null:
		var event := connection.service(0)
		if event[0] == ENetConnection.EVENT_NONE: return
		_handle_event(event)

func host(bind_address: String) -> Error:
	const ANY_ADDRESS := "*"
	_destroy_connection()
	connection = ENetConnection.new()
	is_hosting = true
	next_identifier = 2 # 1 is reserved for the server in [SceneMultiplayer]
	var error := connection.create_host_bound(ANY_ADDRESS, bind_address.to_int(), MAX_PEERS, CHANNEL_COUNT)
	if error != OK: _destroy_connection()
	return error

func join(join_address: String) -> Error:
	var parts := join_address.rsplit(":", true, 1)
	if parts.size() != 2:
		return ERR_INVALID_PARAMETER
	_destroy_connection()
	connection = ENetConnection.new()
	# Client-side local host, one outgoing peer
	var error := connection.create_host(1, CHANNEL_COUNT)
	if error != OK:
		_destroy_connection()
		return error
	is_hosting = false
	next_identifier = 1 # Server is always 1 on the client side
	var packet_peer := connection.connect_to_host(parts[0], parts[1].to_int(), CHANNEL_COUNT)
	if packet_peer == null:
		_destroy_connection()
		return ERR_CANT_CONNECT
	return OK

func disconnect_peer(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
	var packet_peer: ENetPacketPeer = packet_peers_by_identifier.get(peer_identifier)
	if packet_peer == null:
		return
	local_reasons_by_identifier[peer_identifier] = reason
	packet_peer.peer_disconnect(reason)

func close(reason: GdLinkCore.DisconnectReason) -> void:
	is_closing = true
	for peer_identifier: int in packet_peers_by_identifier.keys():
		disconnect_peer(peer_identifier, reason)
	_destroy_if_closed()

func send_control(peer_identifier: int, payload: PackedByteArray) -> void:
	var packet_peer: ENetPacketPeer = packet_peers_by_identifier.get(peer_identifier)
	if packet_peer == null:
		return
	packet_peer.send(GdLinkCore.CHANNEL_GDLINK, payload, ENetPacketPeer.FLAG_RELIABLE)

func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
	var packet_peer: ENetPacketPeer = packet_peers_by_identifier.get(peer_identifier)
	if packet_peer == null:
		return
	var flags := ENetPacketPeer.FLAG_UNSEQUENCED
	if reliable: flags = ENetPacketPeer.FLAG_RELIABLE
	packet_peer.send(channel, payload, flags)

func get_identity(peer_identifier: int) -> String:
	var packet_peer: ENetPacketPeer = packet_peers_by_identifier.get(peer_identifier)
	if packet_peer != null:
		return packet_peer.get_remote_address()
	else:
		return ""

## Handle received [param event]
func _handle_event(event: Array) -> void:
	# event layout: [type, peer, data, channel]
	var event_type: int = event[0]
	var packet_peer: ENetPacketPeer = event[1]
	match event_type:
		ENetConnection.EVENT_CONNECT:
			_on_connect(packet_peer)
		ENetConnection.EVENT_DISCONNECT:
			_on_disconnect(packet_peer, event[2])
		ENetConnection.EVENT_RECEIVE:
			_on_receive(packet_peer, event)
		ENetConnection.EVENT_ERROR:
			GdLinkCore.log_message(GdLinkCore.LogLevel.ERROR, "Unrecognized ENet event")

## Handle conencted [param packet_peer]
func _on_connect(packet_peer: ENetPacketPeer) -> void:
	var peer_identifier := _register(packet_peer)
	if is_hosting:
		peer_connected.emit(peer_identifier)
	else:
		is_client_connected = true
		join_succeeded.emit(peer_identifier)

## Handle disconencted [param packet_peer]
func _on_disconnect(packet_peer: ENetPacketPeer, remote_reason: int) -> void:
	var peer_identifier: int = identifiers_by_packet_peer.get(packet_peer, 0)
	if peer_identifier == 0:
		return
	var reason: int = local_reasons_by_identifier.get(peer_identifier, remote_reason)
	if reason == GdLinkCore.DisconnectReason.NONE:
		reason = GdLinkCore.DisconnectReason.TRANSPORT_FAILURE
	_forget(peer_identifier, packet_peer)
	if is_hosting:
		peer_disconnected.emit(peer_identifier, reason)
	elif is_client_connected:
		is_client_connected = false
		peer_disconnected.emit(peer_identifier, reason)
	else:
		join_failed.emit(reason)
	_destroy_if_closed()

## Handle received packet [param event]
func _on_receive(packet_peer: ENetPacketPeer, event: Array) -> void:
	var payload := packet_peer.get_packet()
	match event[3]:
		GdLinkCore.CHANNEL_GDLINK:
			control_received.emit(identifiers_by_packet_peer.get(packet_peer, 0), payload)
		_:
			data_received.emit(identifiers_by_packet_peer.get(packet_peer, 0), event[3], payload)

## Register a new [param packet_peer]
func _register(packet_peer: ENetPacketPeer) -> int:
	var peer_identifier := next_identifier
	next_identifier += 1
	packet_peers_by_identifier[peer_identifier] = packet_peer
	identifiers_by_packet_peer[packet_peer] = peer_identifier
	return peer_identifier

## Erase a [param packet_peer] from memory
func _forget(peer_identifier: int, packet_peer: ENetPacketPeer) -> void:
	packet_peers_by_identifier.erase(peer_identifier)
	identifiers_by_packet_peer.erase(packet_peer)
	local_reasons_by_identifier.erase(peer_identifier)

## Call [method _destroy_connection if connection is closed
func _destroy_if_closed() -> void:
	if is_closing and packet_peers_by_identifier.is_empty():
		_destroy_connection()

## Remove connection data from memory
func _destroy_connection() -> void:
	if connection != null: connection.destroy()
	connection = null
	is_closing = false
	is_client_connected = false
	packet_peers_by_identifier.clear()
	identifiers_by_packet_peer.clear()
	local_reasons_by_identifier.clear()
