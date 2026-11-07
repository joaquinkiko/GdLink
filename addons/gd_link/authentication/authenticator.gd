## Authentication contract: client builds the hello, host verifies it.
@abstract
class_name Authenticator
extends RefCounted

## Client: returns the payload sent after join_succeeded.
@abstract func build_hello() -> PackedByteArray

## Host: returns NONE to accept, or the rejection reason.
@abstract func verify_hello(identity: String, payload: PackedByteArray) -> GdLinkCore.DisconnectReason

## Largest valid hello body in bytes. Bounds pre-auth input.
@abstract func get_max_hello_bytes() -> int
