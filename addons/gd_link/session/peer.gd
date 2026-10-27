class_name Peer
extends RefCounted

enum State { CONNECTING, AWAITING_HELLO, AUTHENTICATED }

var peer_identifier: int
var identity: String
var state: State = State.CONNECTING

func _init(peer_identifier_value: int, identity_value: String) -> void:
	peer_identifier = peer_identifier_value
	identity = identity_value

func is_authenticated() -> bool:
	return state == State.AUTHENTICATED

func mark_authenticated() -> void:
	state = State.AUTHENTICATED
