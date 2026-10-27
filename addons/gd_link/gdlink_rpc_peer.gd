## [MultiplayerPeer] that passes data to GdLink
class_name GdLinkRpcPeer
extends MultiplayerPeerExtension

const MAX_QUEUED_PACKETS := 1024

var session: Session
var queued_packets: Array[Dictionary] = []
var current_packet: Dictionary = {}
var target_peer_identifier := 0
var _transfer_mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _transfer_channel := 0
var unique_identifier := 1
var status := MultiplayerPeer.CONNECTION_DISCONNECTED
var refuse_connections := false

func _init(session_instance: Session) -> void:
	session = session_instance
	session.data_received.connect(_on_data_received)
	session.peer_authenticated.connect(func(peer: Peer) -> void:
		peer_connected.emit(peer.peer_identifier)
		)
	session.peer_removed.connect(func(peer: Peer, _reason: GdLinkCore.DisconnectReason) -> void:
		peer_disconnected.emit(peer.peer_identifier)
		)
	session.join_succeeded.connect(_on_join_succeeded)
	session.join_failed.connect(_on_session_lost)
	session.session_closed.connect(func(_reason: GdLinkCore.DisconnectReason) -> void:
		_on_session_lost()
		)

func _on_join_succeeded(assigned_identifier: int) -> void:
	unique_identifier = assigned_identifier
	status = MultiplayerPeer.CONNECTION_CONNECTED
	peer_connected.emit(1)

func _on_session_lost() -> void:
	status = MultiplayerPeer.CONNECTION_DISCONNECTED
	peer_disconnected.emit(1)

func _on_data_received(peer_identifier: int, channel: int, payload: PackedByteArray) -> void:
	if queued_packets.size() < MAX_QUEUED_PACKETS:
		queued_packets.append({"peer": peer_identifier, "channel": channel, "payload": payload})

func _resolve_recipients() -> Array[int]:
	var recipients: Array[int] = []
	if not session.is_hosting:
		recipients.append(1)
		return recipients
	if target_peer_identifier > 0:
		recipients.append(target_peer_identifier)
		return recipients
	for peer in session.get_authenticated_peers():
		if target_peer_identifier == 0 or peer.peer_identifier != -target_peer_identifier:
			recipients.append(peer.peer_identifier)
	return recipients

func _put_packet_script(buffer: PackedByteArray) -> Error:
	var reliable := transfer_mode != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	for recipient in _resolve_recipients():
		session.send_data(recipient, transfer_channel, buffer, reliable)
	return OK

func _get_packet_script() -> PackedByteArray:
	if !queued_packets.is_empty():
		current_packet = queued_packets.pop_front()
	else:
		current_packet = {}
	return current_packet.get("payload", PackedByteArray())

func _get_available_packet_count() -> int:
	return queued_packets.size()

func _get_packet_peer() -> int:
	return current_packet.get("peer", 0)

func _get_packet_channel() -> int:
	return current_packet.get("channel", 0)

func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return transfer_mode

func _get_max_packet_size() -> int:
	return GdLinkCore.MAX_PAYLOAD_BYTES

func _get_unique_id() -> int:
	return unique_identifier

func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return status

func _is_server() -> bool:
	return session.is_hosting

func _is_server_relay_supported() -> bool:
	return false

func _poll() -> void:
	pass

func _set_target_peer(peer_identifier: int) -> void:
	target_peer_identifier = peer_identifier

func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode

func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = mode

func _get_transfer_channel() -> int:
	return _transfer_channel

func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel

func _set_refuse_new_connections(refuse: bool) -> void:
	refuse_connections = refuse

func _is_refusing_new_connections() -> bool:
	return refuse_connections

func _disconnect_peer(peer_identifier: int, _force: bool) -> void:
	session.kick(peer_identifier, GdLinkCore.DisconnectReason.KICKED)

func _close() -> void:
	session.leave()
