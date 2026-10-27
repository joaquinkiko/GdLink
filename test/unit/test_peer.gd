extends GutTest

var peer: Peer

func before_each() -> void:
	peer = Peer.new(1, "127.0.0.1")

func test_new_peer_starts_connecting() -> void:
	assert_eq(peer.state, Peer.State.CONNECTING)
	assert_false(peer.is_authenticated())

func test_mark_authenticated_sets_state() -> void:
	peer.mark_authenticated()
	assert_eq(peer.state, Peer.State.AUTHENTICATED)
	assert_true(peer.is_authenticated())

func test_constructor_stores_identifier_and_identity() -> void:
	assert_eq(peer.peer_identifier, 1)
	assert_eq(peer.identity, "127.0.0.1")
