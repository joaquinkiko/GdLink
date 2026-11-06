## Steam relay transport over GodotSteam SteamNetworkingMessages. Requires Steam initialized.
class_name SteamRelayTransport
extends Transport

enum FrameType { PROBE, PROBE_ACK, DATA, DISCONNECT }

const HOST_IDENTIFIER := GdLinkCore.HOST_PEER_IDENTIFIER
const MAX_PEERS := 32
const FRAME_HEADER_BYTES := 2
const ADDRESS_SEPARATOR := ":"
const MESSAGE_BATCH := 64
const JOIN_TIMEOUT_MSEC := 5000
const HEARTBEAT_INTERVAL_MSEC := 1000
const SESSION_LINGER_MSEC := 250
const SEND_UNRELIABLE := 0
const SEND_RELIABLE := 8 # k_nSteamNetworkingSend_Reliable

var _steam: Object # Holds the steam singleton, assigned during _init
var _is_hosting := false
var _is_joining := false
var _is_client_connected := false
var _virtual_port := 0
var _host_steam_id := 0
var _join_started_msec := 0
var _last_heartbeat_msec := 0
var _next_identifier := 2
var _steam_ids_by_identifier: Dictionary = {}
var _identifiers_by_steam_id: Dictionary = {}
## Steam ID -> msec deadline for closing the session.
var _lingering_sessions: Dictionary = {}

## [param steam_backend] allows defining a custom backend. If left null, will
## attempt to retrieve Steam singleton.
func _init(steam_backend: Object = null) -> void:
	if steam_backend == null:
		if Engine.has_singleton("Steam"):
			_steam = Engine.get_singleton("Steam")
	else:
		_steam = steam_backend
	if _steam == null:
		GdLinkCore.log_message(GdLinkCore.LogLevel.ERROR, "GodotSteam singleton not found")
		return
	_steam.network_messages_session_request.connect(_on_session_request)

func poll() -> void:
	_close_lingering_sessions()
	if not _is_active(): return
	for message: Dictionary in _steam.readMessagesOnChannel(_virtual_port, MESSAGE_BATCH):
		_handle_frame(message.get("remote_steam_id", 0), message.get("payload", PackedByteArray()))
	_check_sessions()

func host(bind_address: String) -> Error:
	if _is_active(): return ERR_ALREADY_IN_USE
	if not _steam.isSteamRunning(): return ERR_UNAVAILABLE
	if not bind_address.is_valid_int(): return ERR_INVALID_PARAMETER
	_virtual_port = bind_address.to_int()
	_is_hosting = true
	return OK

func join(join_address: String) -> Error:
	if _is_active(): return ERR_ALREADY_IN_USE
	var parts := join_address.rsplit(ADDRESS_SEPARATOR, true, 1)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return ERR_INVALID_PARAMETER
	if not _steam.isSteamRunning(): return ERR_UNAVAILABLE
	_host_steam_id = parts[0].to_int()
	_virtual_port = parts[1].to_int()
	_register(HOST_IDENTIFIER, _host_steam_id)
	_is_joining = true
	_join_started_msec = Time.get_ticks_msec()
	_send_frame(HOST_IDENTIFIER, FrameType.PROBE, 0, PackedByteArray(), true)
	return OK

func disconnect_peer(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
	if not _steam_ids_by_identifier.has(peer_identifier): return
	_send_frame(peer_identifier, FrameType.DISCONNECT, 0, PackedByteArray([reason]), true)
	_drop_peer(peer_identifier, reason)

func close(reason: GdLinkCore.DisconnectReason) -> void:
	for peer_identifier: int in _steam_ids_by_identifier.keys():
		disconnect_peer(peer_identifier, reason)
	_is_hosting = false
	_is_joining = false
	_is_client_connected = false

func send_control(peer_identifier: int, payload: PackedByteArray) -> void:
	_send_frame(peer_identifier, FrameType.DATA, GdLinkCore.CHANNEL_GDLINK, payload, true)

func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
	_send_frame(peer_identifier, FrameType.DATA, channel, payload, reliable)

func get_identity(peer_identifier: int) -> String:
	var steam_id: int = _steam_ids_by_identifier.get(peer_identifier, 0)
	return str(steam_id) if steam_id != 0 else ""

func _is_active() -> bool:
	return _is_hosting or _is_joining or _is_client_connected

## Accepts sessions from registered-capacity hosts, or from our host while joining.
func _on_session_request(remote_steam_id: int) -> void:
	var accept := false
	if _is_hosting:
		accept = _identifiers_by_steam_id.size() < MAX_PEERS
	elif _host_steam_id != 0:
		accept = remote_steam_id == _host_steam_id
	if accept: _steam.acceptSessionWithUser(remote_steam_id)

func _handle_frame(remote_steam_id: int, frame: PackedByteArray) -> void:
	if frame.size() < FRAME_HEADER_BYTES: return
	var frame_type: int = frame[0]
	var channel: int = frame[1]
	var payload := frame.slice(FRAME_HEADER_BYTES)
	var peer_identifier: int = _identifiers_by_steam_id.get(remote_steam_id, 0)
	match frame_type:
		FrameType.PROBE:
			if _is_hosting and peer_identifier == 0: _accept_client(remote_steam_id)
		FrameType.PROBE_ACK:
			if _is_joining and not _is_hosting and peer_identifier == HOST_IDENTIFIER:
				_is_joining = false
				_is_client_connected = true
				_last_heartbeat_msec = Time.get_ticks_msec()
				join_succeeded.emit(HOST_IDENTIFIER)
		FrameType.DATA:
			if peer_identifier == 0: return
			if channel == GdLinkCore.CHANNEL_GDLINK:
				control_received.emit(peer_identifier, payload)
			else:
				data_received.emit(peer_identifier, channel, payload)
		FrameType.DISCONNECT:
			if peer_identifier == 0: return
			var reason: int = payload[0] if not payload.is_empty() else GdLinkCore.DisconnectReason.TRANSPORT_FAILURE
			_drop_peer(peer_identifier, reason)

func _accept_client(remote_steam_id: int) -> void:
	var peer_identifier := _next_identifier
	_next_identifier += 1
	_register(peer_identifier, remote_steam_id)
	_send_frame(peer_identifier, FrameType.PROBE_ACK, 0, PackedByteArray(), true)
	peer_connected.emit(peer_identifier)

func _register(peer_identifier: int, steam_id: int) -> void:
	_steam_ids_by_identifier[peer_identifier] = steam_id
	_identifiers_by_steam_id[steam_id] = peer_identifier

## Forgets the peer, defers session close so queued frames flush, and emits the matching signal.
func _drop_peer(peer_identifier: int, reason: int) -> void:
	var steam_id: int = _steam_ids_by_identifier.get(peer_identifier, 0)
	if steam_id == 0: return
	_steam_ids_by_identifier.erase(peer_identifier)
	_identifiers_by_steam_id.erase(steam_id)
	_lingering_sessions[steam_id] = Time.get_ticks_msec() + SESSION_LINGER_MSEC
	if _is_hosting:
		peer_disconnected.emit(peer_identifier, reason)
		return
	var was_connected := _is_client_connected
	_is_client_connected = false
	_is_joining = false
	_host_steam_id = 0
	if was_connected:
		peer_disconnected.emit(peer_identifier, reason)
	else:
		join_failed.emit(reason)

## Client: join timeout. Both: heartbeat over Steam session errors.
func _check_sessions() -> void:
	var now := Time.get_ticks_msec()
	if _is_joining and now - _join_started_msec > JOIN_TIMEOUT_MSEC:
		_drop_peer(HOST_IDENTIFIER, GdLinkCore.DisconnectReason.TRANSPORT_FAILURE)
		return
	if now - _last_heartbeat_msec < HEARTBEAT_INTERVAL_MSEC: return
	_last_heartbeat_msec = now
	for peer_identifier: int in _steam_ids_by_identifier.keys():
		var steam_id: int = _steam_ids_by_identifier[peer_identifier]
		if _steam.getSessionInformation(steam_id).get("session_error", 0) != 0:
			_drop_peer(peer_identifier, GdLinkCore.DisconnectReason.TRANSPORT_FAILURE)

func _close_lingering_sessions() -> void:
	var now := Time.get_ticks_msec()
	for steam_id: int in _lingering_sessions.keys():
		if now >= _lingering_sessions[steam_id]:
			_steam.closeSessionWithUser(steam_id)
			_lingering_sessions.erase(steam_id)

func _send_frame(peer_identifier: int, frame_type: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
	var steam_id: int = _steam_ids_by_identifier.get(peer_identifier, 0)
	if steam_id == 0: return
	var frame := PackedByteArray([frame_type, channel])
	frame.append_array(payload)
	var flags := SEND_RELIABLE if reliable else SEND_UNRELIABLE
	_steam.sendMessageToUser(steam_id, frame, flags, _virtual_port)
