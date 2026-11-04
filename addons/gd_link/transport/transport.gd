## Low-level connection layer: hosting, joining, peer lifecycle, and control messages.
@abstract
class_name Transport
extends RefCounted

class TrafficCounters extends RefCounted:
	var packets_in: int = 0
	var packets_out: int = 0
	var bytes_in: int = 0
	var bytes_out: int = 0

## Emitted when a peer completes the transport handshake.
signal peer_connected(peer_identifier: int)
## Emitted when a peer disconnects, with the transport-level reason.
signal peer_disconnected(peer_identifier: int, reason: GdLinkCore.DisconnectReason)
## Emitted when a control payload arrives on [member GdLinkCore.CHANNEL_GDLINK].
signal control_received(peer_identifier: int, payload: PackedByteArray)
## Emmitted when non-control payload is received.
signal data_received(peer_identifier: int, channel: int, payload: PackedByteArray)
## Emitted on client when the host connection is established.
signal join_succeeded(server_peer_identifier: int)
## Emitted on client when the join fails at the transport level.
signal join_failed(reason: GdLinkCore.DisconnectReason)

## Per-peer traffic totals, written by backends through the _record helpers.
var traffic_counters: Dictionary = {}

## Typically called every frame to actually run the backend.
@abstract func poll() -> void

## Starts hosting. Format of [param bind_address] depends on transport.
## Returns error if [param bind_address] formatted incorrectly.
@abstract func host(bind_address: String) -> Error

## Joins a host. Format of [param join_address] depends on transport.
## Returns error if [param join_address] formatted incorrectly.
@abstract func join(join_address: String) -> Error

## Called on host to disconnect a peer and sends reason before closing.
@abstract func disconnect_peer(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void

## Closes the local connection with reason.
@abstract func close(reason: GdLinkCore.DisconnectReason) -> void

## Sends control payload to a peer on [member GdLinkCore.CHANNEL_GDLINK] only.
@abstract func send_control(peer_identifier: int, payload: PackedByteArray) -> void

## Sends payload to a peer on [param channel].
@abstract func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void

## Returns a stable identity for authentication.
@abstract func get_identity(peer_identifier: int) -> String

## Returns counters for peer_identifier, or null if no traffic has been recorded.
func get_traffic_counters(peer_identifier: int) -> TrafficCounters:
	return traffic_counters.get(peer_identifier)

## Returns {rtt_msec, loss} for peer_identifier. Backends without link stats return empty.
func get_link_stats(_peer_identifier: int) -> Dictionary:
	return {}

func _record_sent(peer_identifier: int, byte_count: int) -> void:
	if peer_identifier <= 0: return
	var counters := _counters_for(peer_identifier)
	counters.packets_out += 1
	counters.bytes_out += byte_count

func _record_received(peer_identifier: int, byte_count: int) -> void:
	if peer_identifier <= 0: return
	var counters := _counters_for(peer_identifier)
	counters.packets_in += 1
	counters.bytes_in += byte_count

func _counters_for(peer_identifier: int) -> TrafficCounters:
	if not traffic_counters.has(peer_identifier):
		traffic_counters[peer_identifier] = TrafficCounters.new()
	return traffic_counters[peer_identifier]
