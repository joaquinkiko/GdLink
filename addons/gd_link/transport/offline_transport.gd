## Loopback transport for in-process sessions
class_name OfflineTransport
extends Transport

enum EventType { CONNECT, JOIN_SUCCEEDED, CONTROL, DATA, DISCONNECT }

const LOCAL_IDENTITY := "127.0.0.1"
const ADDRESS_SEPARATOR := ":"

## Hosting endpoints keyed by port. Process-wide, so only same-process joins resolve.
static var _hosts_by_port: Dictionary = {}

var _port := ""
var _is_hosting := false
var _inbox: Array[Dictionary] = []
## Host only: client endpoints keyed by peer identifier.
var _clients_by_identifier: Dictionary = {}
var _next_identifier := 2
## Client only: paired host endpoint and our assigned identifier.
var _host_endpoint: OfflineTransport
var _own_identifier := 0

func poll() -> void:
	while not _inbox.is_empty():
		_handle_event(_inbox.pop_front())

func host(bind_address: String) -> Error:
	_port = _get_port(bind_address)
	if _hosts_by_port.has(_port):
		return ERR_ALREADY_IN_USE
	_is_hosting = true
	_hosts_by_port[_port] = self
	return OK

func join(join_address: String) -> Error:
	if not join_address.contains(ADDRESS_SEPARATOR):
		return ERR_INVALID_PARAMETER
	var host_endpoint: OfflineTransport = _hosts_by_port.get(_get_port(join_address))
	if host_endpoint == null:
		return ERR_CANT_CONNECT
	_host_endpoint = host_endpoint
	host_endpoint._accept_client(self)
	return OK

func disconnect_peer(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
	var client: OfflineTransport = _clients_by_identifier.get(peer_identifier)
	if client == null:
		return
	_clients_by_identifier.erase(peer_identifier)
	client._push({"type": EventType.DISCONNECT, "peer": GdLinkCore.HOST_PEER_IDENTIFIER, "reason": reason})
	client._host_endpoint = null
	_push({"type": EventType.DISCONNECT, "peer": peer_identifier, "reason": reason})

func close(reason: GdLinkCore.DisconnectReason) -> void:
	if _is_hosting:
		for peer_identifier: int in _clients_by_identifier.keys():
			disconnect_peer(peer_identifier, reason)
		if _hosts_by_port.get(_port) == self:
			_hosts_by_port.erase(_port)
		_is_hosting = false
	elif _host_endpoint != null:
		_host_endpoint.disconnect_peer(_own_identifier, reason)

func send_control(peer_identifier: int, payload: PackedByteArray) -> void:
	_send(peer_identifier, EventType.CONTROL, GdLinkCore.CHANNEL_GDLINK, payload)

## Loopback is always ordered and lossless, so [param _reliable] is ignored.
func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, _reliable: bool) -> void:
	_send(peer_identifier, EventType.DATA, channel, payload)

func get_identity(peer_identifier: int) -> String:
	return LOCAL_IDENTITY if _clients_by_identifier.has(peer_identifier) else ""

## Host: registers a client and queues connect events for both sides.
func _accept_client(client: OfflineTransport) -> void:
	var peer_identifier := _next_identifier
	_next_identifier += 1
	_clients_by_identifier[peer_identifier] = client
	client._own_identifier = peer_identifier
	_push({"type": EventType.CONNECT, "peer": peer_identifier})
	client._push({"type": EventType.JOIN_SUCCEEDED, "peer": GdLinkCore.HOST_PEER_IDENTIFIER})

func _send(peer_identifier: int, event_type: EventType, channel: int, payload: PackedByteArray) -> void:
	if _is_hosting:
		var client: OfflineTransport = _clients_by_identifier.get(peer_identifier)
		if client != null:
			client._push({"type": event_type, "peer": GdLinkCore.HOST_PEER_IDENTIFIER, "channel": channel, "payload": payload})
	elif _host_endpoint != null:
		_host_endpoint._push({"type": event_type, "peer": _own_identifier, "channel": channel, "payload": payload})

func _push(event: Dictionary) -> void:
	_inbox.append(event)

func _handle_event(event: Dictionary) -> void:
	match event["type"]:
		EventType.CONNECT:
			peer_connected.emit(event["peer"])
		EventType.JOIN_SUCCEEDED:
			join_succeeded.emit(event["peer"])
		EventType.CONTROL:
			control_received.emit(event["peer"], event["payload"])
		EventType.DATA:
			data_received.emit(event["peer"], event["channel"], event["payload"])
		EventType.DISCONNECT:
			peer_disconnected.emit(event["peer"], event["reason"])

static func _get_port(address: String) -> String:
	return address.rsplit(ADDRESS_SEPARATOR, true, 1)[-1]
