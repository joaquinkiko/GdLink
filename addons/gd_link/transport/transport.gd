## Low-level connection layer: hosting, joining, peer lifecycle, and control messages.
@abstract
class_name Transport
extends RefCounted

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
