extends Node

## Global session. Call session.setup() with a transport and authenticator before host() or join().
var session: Session

func _ready() -> void:
	GdLinkCore.configure_logging()
	session = Session.new()
	add_child(session, true)
