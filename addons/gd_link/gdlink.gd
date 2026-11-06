extends Node

## Global session. Call session.setup() with a transport and authenticator before host() or join().
var session: Session
var rpc_peer: GdLinkRpcPeer

func _ready() -> void:
	GdLinkCore.configure_logging()
	session = Session.new()
	add_child(session, true)
	rpc_peer = GdLinkRpcPeer.new(session)
	get_tree().get_multiplayer().multiplayer_peer = rpc_peer
