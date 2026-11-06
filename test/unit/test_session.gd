extends GutTest

class FakeTransport extends Transport:
	var disconnected_calls: Array = []
	var sent_controls: Array = []
	var sent_data: Array = []
	var identities: Dictionary = {}

	func poll() -> void:
		pass

	func host(_bind_address: String) -> Error:
		return OK

	func join(_join_address: String) -> Error:
		return OK

	func disconnect_peer(peer_identifier: int, reason: GdLinkCore.DisconnectReason) -> void:
		disconnected_calls.append([peer_identifier, reason])

	func close(_reason: GdLinkCore.DisconnectReason) -> void:
		pass

	func send_control(peer_identifier: int, payload: PackedByteArray) -> void:
		sent_controls.append([peer_identifier, payload])

	func send_data(peer_identifier: int, channel: int, payload: PackedByteArray, reliable: bool) -> void:
		sent_data.append({"peer": peer_identifier, "channel": channel, "payload": payload, "reliable": reliable})

	func get_identity(peer_identifier: int) -> String:
		return identities.get(peer_identifier, "")

const FAKE_PORT := "7800"
const FAKE_IP := "10.0.0.2"
const FAKE_ADDRESS := "%s:%s"%[FAKE_IP, FAKE_PORT]

var transport: FakeTransport
var authenticator: VersionAuthenticator
var session: Session

func before_each() -> void:
	transport = FakeTransport.new()
	authenticator = VersionAuthenticator.new()
	session = Session.new()
	add_child_autofree(session)
	session.setup(transport, authenticator)

func _connect_peer(peer_identifier: int, identity: String) -> void:
	transport.identities[peer_identifier] = identity
	transport.peer_connected.emit(peer_identifier)

func test_connected_peer_awaits_hello() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	assert_eq(session.get_peer(1).state, Peer.State.AWAITING_HELLO)

func test_valid_hello_authenticates_and_sends_accept() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	watch_signals(session)
	transport.control_received.emit(1, session._build_hello_message())
	assert_true(session.get_peer(1).is_authenticated())
	assert_signal_emitted(session, "peer_authenticated")
	assert_eq(transport.sent_controls[0][1], session._build_accept(1))

func test_replayed_hello_after_auth_is_ignored() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	watch_signals(session)
	transport.control_received.emit(1, session._build_hello_message())
	transport.control_received.emit(1, session._build_hello_message())
	assert_signal_emit_count(session, "peer_authenticated", 1)
	assert_eq(transport.sent_controls.size(), 2, "accept plus empty snapshot end")

func test_timeout_disconnects_unauthenticated_peer() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	session._on_authentication_timeout(1)
	assert_eq(transport.disconnected_calls[0][1], GdLinkCore.DisconnectReason.AUTH_REJECT_TIMEOUT)

func test_timeout_ignores_authenticated_peer() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	transport.control_received.emit(1, session._build_hello_message())
	session._on_authentication_timeout(1)
	assert_eq(transport.disconnected_calls.size(), 0)

func test_kick_forwards_reason_on_host() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	session.kick(1, GdLinkCore.DisconnectReason.KICKED)
	assert_eq(transport.disconnected_calls[0][1], GdLinkCore.DisconnectReason.KICKED)

func test_disconnect_removes_peer_and_emits() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	watch_signals(session)
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.KICKED)
	assert_null(session.get_peer(1))
	assert_signal_emitted(session, "peer_removed")

func test_client_sends_hello_on_join_succeeded() -> void:
	session.join(FAKE_ADDRESS)
	transport.join_succeeded.emit(1)
	assert_eq(transport.sent_controls[0][1], session._build_hello_message())

func test_client_marks_authenticated_on_accept() -> void:
	session.join(FAKE_ADDRESS)
	watch_signals(session)
	var accept := PackedByteArray()
	accept.resize(5)
	accept[0] = Session.ACCEPT_BYTE
	accept.encode_u32(1, 7)
	transport.control_received.emit(1, accept)
	assert_true(session.is_client_authenticated)
	assert_signal_emitted_with_parameters(session, "join_succeeded", [7])

func test_accept_with_wrong_length_is_ignored() -> void:
	session.join(FAKE_ADDRESS)
	watch_signals(session)
	transport.control_received.emit(1, PackedByteArray([Session.ACCEPT_BYTE]))
	assert_false(session.is_client_authenticated)
	assert_signal_not_emitted(session, "join_succeeded")

func test_kick_is_noop_on_client() -> void:
	session.join(FAKE_ADDRESS)
	session.kick(1, GdLinkCore.DisconnectReason.KICKED)
	assert_true(transport.disconnected_calls.is_empty())

func test_client_disconnect_before_accept_emits_join_failed() -> void:
	session.join(FAKE_ADDRESS)
	watch_signals(session)
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.AUTH_REJECT_TIMEOUT)
	assert_signal_emitted_with_parameters(session, "join_failed", [GdLinkCore.DisconnectReason.AUTH_REJECT_TIMEOUT])

func test_client_disconnect_after_accept_emits_session_closed() -> void:
	session.join(FAKE_ADDRESS)
	var accept := PackedByteArray()
	accept.resize(5)
	accept[0] = Session.ACCEPT_BYTE
	accept.encode_u32(1, 7)
	transport.control_received.emit(1, accept)
	watch_signals(session)
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.KICKED)
	assert_signal_emitted_with_parameters(session, "session_closed", [GdLinkCore.DisconnectReason.KICKED])

func test_disconnect_of_unknown_peer_emits_nothing() -> void:
	session.host(FAKE_PORT)
	watch_signals(session)
	transport.peer_disconnected.emit(99, GdLinkCore.DisconnectReason.VOLUNTARY)
	assert_signal_not_emitted(session, "peer_removed")

func test_non_hello_before_auth_disconnects_peer() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	transport.control_received.emit(1, PackedByteArray([GdLinkCore.ControlMessage.ACCEPT, 0, 0, 0, 0]))
	assert_eq(transport.disconnected_calls[0][1], GdLinkCore.DisconnectReason.AUTH_REJECT_GAME_MISMATCH)

func test_empty_control_payload_is_ignored() -> void:
	session.host(FAKE_PORT)
	_connect_peer(1, FAKE_IP)
	transport.control_received.emit(1, PackedByteArray())
	assert_eq(transport.disconnected_calls.size(), 0)
	assert_eq(session.get_peer(1).state, Peer.State.AWAITING_HELLO)

func _authenticate_peer(peer_identifier: int) -> void:
	_connect_peer(peer_identifier, FAKE_IP)
	transport.control_received.emit(peer_identifier, session._build_hello_message())

func test_host_peer_exists_and_is_not_in_peers() -> void:
	session.host(FAKE_PORT)
	assert_eq(session.host_peer.peer_identifier, GdLinkCore.HOST_PEER_IDENTIFIER)
	assert_true(session.get_authenticated_peers().is_empty())

func test_join_clears_host_peer() -> void:
	session.host(FAKE_PORT)
	session.join(FAKE_ADDRESS)
	assert_null(session.host_peer)

func test_host_writes_server_meta() -> void:
	session.host(FAKE_PORT)
	session.set_server_meta(&"round", 3)
	assert_eq(session.get_server_meta(), {&"round": 3})

func test_get_server_meta_returns_copy() -> void:
	session.host(FAKE_PORT)
	session.set_server_meta(&"round", 3)
	var copy := session.get_server_meta()
	copy[&"round"] = 99
	assert_eq(session.get_server_meta()[&"round"], 3)

func test_erase_server_meta() -> void:
	session.host(FAKE_PORT)
	session.set_server_meta(&"round", 3)
	session.erase_server_meta(&"round")
	assert_true(session.get_server_meta().is_empty())

func test_host_writes_meta_for_authenticated_peer() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_peer_meta(4, &"team", "red")
	assert_eq(session.get_peer_meta(4), {&"team": "red"})

func test_peer_meta_ignored_before_authentication() -> void:
	session.host(FAKE_PORT)
	_connect_peer(4, FAKE_IP)
	session.set_peer_meta(4, &"team", "red")
	assert_true(session.get_peer_meta(4).is_empty())

func test_host_peer_meta_under_host_identifier() -> void:
	session.host(FAKE_PORT)
	session.set_peer_meta(GdLinkCore.HOST_PEER_IDENTIFIER, &"motd", "hi")
	assert_eq(session.get_peer_meta(GdLinkCore.HOST_PEER_IDENTIFIER), {&"motd": "hi"})

func test_erase_peer_meta() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_peer_meta(4, &"team", "red")
	session.erase_peer_meta(4, &"team")
	assert_true(session.get_peer_meta(4).is_empty())

func test_invalid_key_and_value_are_ignored() -> void:
	session.host(FAKE_PORT)
	session.set_server_meta("", 1)
	session.set_server_meta(&"obj", RefCounted.new())
	assert_true(session.get_server_meta().is_empty())

func test_removing_peer_discards_its_meta() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_peer_meta(4, &"team", "red")
	transport.peer_disconnected.emit(4, GdLinkCore.DisconnectReason.VOLUNTARY)
	assert_true(session.get_peer_meta(4).is_empty())

func test_client_meta_writes_are_ignored() -> void:
	session.join(FAKE_ADDRESS)
	session.set_server_meta(&"round", 3)
	session.set_peer_meta(GdLinkCore.HOST_PEER_IDENTIFIER, &"motd", "hi")
	assert_true(session.get_server_meta().is_empty())
	assert_true(session.get_peer_meta(GdLinkCore.HOST_PEER_IDENTIFIER).is_empty())

func _flush_frame() -> void:
	session._process(0.0)

func _accept_payload(assigned_identifier: int) -> PackedByteArray:
	var accept := PackedByteArray()
	accept.resize(Session.ACCEPT_SIZE)
	accept[0] = Session.ACCEPT_BYTE
	accept.encode_u32(1, assigned_identifier)
	return accept

func _sent_to(peer_identifier: int) -> Array:
	var payloads: Array = []
	for entry: Array in transport.sent_controls:
		if entry[0] == peer_identifier: payloads.append(entry[1])
	return payloads

func test_flush_sends_server_set_to_authenticated_peer() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	transport.sent_controls.clear()
	session.set_server_meta(&"round", 3)
	_flush_frame()
	assert_eq(_sent_to(4), [MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3)])

func test_flush_coalesces_last_write_per_key() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	transport.sent_controls.clear()
	session.set_server_meta(&"round", 1)
	session.set_server_meta(&"round", 2)
	_flush_frame()
	assert_eq(_sent_to(4), [MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 2)])

func test_flush_clears_queue() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_server_meta(&"round", 1)
	_flush_frame()
	transport.sent_controls.clear()
	_flush_frame()
	assert_true(transport.sent_controls.is_empty())

func test_flush_skips_unauthenticated_peer() -> void:
	session.host(FAKE_PORT)
	_connect_peer(9, FAKE_IP)
	session.set_server_meta(&"round", 1)
	_flush_frame()
	assert_true(_sent_to(9).is_empty())

func test_erase_server_meta_flushes_erase_message() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.set_server_meta(&"round", 1)
	_flush_frame()
	transport.sent_controls.clear()
	session.erase_server_meta(&"round")
	_flush_frame()
	assert_eq(_sent_to(4), [MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_SERVER_ERASE, 0, &"round")])

func test_erase_missing_key_queues_nothing() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	transport.sent_controls.clear()
	session.erase_server_meta(&"missing")
	_flush_frame()
	assert_true(transport.sent_controls.is_empty())

func test_snapshot_on_auth_contains_server_and_peer_meta() -> void:
	session.host(FAKE_PORT)
	session.set_server_meta(&"round", 3)
	_authenticate_peer(4)
	session.set_peer_meta(4, &"team", "red")
	transport.sent_controls.clear()
	_connect_peer(5, FAKE_IP)
	transport.control_received.emit(5, session._build_hello_message())
	var sent := _sent_to(5)
	assert_eq(sent[0], session._build_accept(5))
	assert_eq(sent[1], MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3))
	assert_true(sent.has(MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, 4, &"team", "red")))
	assert_eq(sent.back(), MetaCodec.encode_snapshot_end())

func test_snapshot_includes_host_peer_meta() -> void:
	session.host(FAKE_PORT)
	session.set_peer_meta(GdLinkCore.HOST_PEER_IDENTIFIER, &"motd", "hi")
	transport.sent_controls.clear()
	_authenticate_peer(4)
	assert_true(_sent_to(4).has(
		MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, GdLinkCore.HOST_PEER_IDENTIFIER, &"motd", "hi")))

func test_removed_peer_erases_its_keys_for_remaining_peers() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	_authenticate_peer(5)
	session.set_peer_meta(4, &"team", "red")
	_flush_frame()
	transport.sent_controls.clear()
	transport.peer_disconnected.emit(4, GdLinkCore.DisconnectReason.VOLUNTARY)
	_flush_frame()
	assert_eq(_sent_to(5), [MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_PEER_ERASE, 4, &"team")])
	assert_true(_sent_to(4).is_empty())

func test_removed_peer_drops_its_pending_sets() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	_authenticate_peer(5)
	session.set_peer_meta(4, &"team", "red")
	transport.peer_disconnected.emit(4, GdLinkCore.DisconnectReason.VOLUNTARY)
	transport.sent_controls.clear()
	_flush_frame()
	assert_false(_sent_to(5).has(MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, 4, &"team", "red")))

func test_stored_value_is_isolated_from_caller_mutation() -> void:
	session.host(FAKE_PORT)
	var loadout: Array = [1, 2]
	session.set_server_meta(&"loadout", loadout)
	loadout.append(3)
	assert_eq(session.get_server_meta()[&"loadout"], [1, 2])

func test_client_mirror_applies_server_set() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, _accept_payload(7))
	watch_signals(session)
	transport.control_received.emit(1, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3))
	assert_eq(session.get_server_meta(), {&"round": 3})
	assert_signal_emitted_with_parameters(session, "server_meta_changed", [&"round", 3])

func test_client_mirror_applies_server_erase() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, _accept_payload(7))
	transport.control_received.emit(1, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3))
	watch_signals(session)
	transport.control_received.emit(1, MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_SERVER_ERASE, 0, &"round"))
	assert_true(session.get_server_meta().is_empty())
	assert_signal_emitted_with_parameters(session, "server_meta_removed", [&"round"])

func test_client_mirror_applies_peer_set_and_erase() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, _accept_payload(7))
	watch_signals(session)
	transport.control_received.emit(1, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, 4, &"team", "red"))
	assert_eq(session.get_peer_meta(4), {&"team": "red"})
	assert_signal_emitted_with_parameters(session, "peer_meta_changed", [4, &"team", "red"])
	transport.control_received.emit(1, MetaCodec.encode_erase(GdLinkCore.ControlMessage.META_PEER_ERASE, 4, &"team"))
	assert_true(session.get_peer_meta(4).is_empty())
	assert_signal_emitted_with_parameters(session, "peer_meta_removed", [4, &"team"])

func test_client_ignores_meta_before_accept() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3))
	assert_true(session.get_server_meta().is_empty())

func test_client_ignores_meta_from_non_host_peer() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, _accept_payload(7))
	transport.control_received.emit(5, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3))
	assert_true(session.get_server_meta().is_empty())

func test_client_snapshot_end_emits_meta_synchronized() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, _accept_payload(7))
	watch_signals(session)
	transport.control_received.emit(1, MetaCodec.encode_snapshot_end())
	assert_signal_emitted(session, "meta_synchronized")

func test_client_mirror_cleared_on_session_closed() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, _accept_payload(7))
	transport.control_received.emit(1, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3))
	transport.control_received.emit(1, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, 4, &"team", "red"))
	transport.peer_disconnected.emit(1, GdLinkCore.DisconnectReason.KICKED)
	assert_true(session.get_server_meta().is_empty())
	assert_true(session.get_peer_meta(4).is_empty())

func test_client_getters_return_copies() -> void:
	session.join(FAKE_ADDRESS)
	transport.control_received.emit(1, _accept_payload(7))
	transport.control_received.emit(1, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 3))
	var copy := session.get_server_meta()
	copy[&"round"] = 99
	assert_eq(session.get_server_meta()[&"round"], 3)

func test_client_sent_meta_is_not_applied_on_host() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	transport.control_received.emit(4, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_SERVER_SET, 0, &"round", 99))
	transport.control_received.emit(4, MetaCodec.encode_set(GdLinkCore.ControlMessage.META_PEER_SET, 4, &"team", "red"))
	assert_true(session.get_server_meta().is_empty())
	assert_true(session.get_peer_meta(4).is_empty())
	assert_true(transport.disconnected_calls.is_empty())

func test_swap_rejected_on_client() -> void:
	session.join(FAKE_ADDRESS)
	assert_eq(session.swap_scene("arena", {}), ERR_UNAUTHORIZED)

func test_second_swap_returns_busy() -> void:
	session.host(FAKE_PORT)
	assert_eq(session.swap_scene("arena", {}), OK)
	assert_eq(session.swap_scene("lobby", {}), ERR_BUSY)

func test_invalid_scene_rejected() -> void:
	session.host(FAKE_PORT)
	assert_eq(session.swap_scene("", {}), ERR_INVALID_PARAMETER)

func test_swap_sends_scene_set_with_new_epoch() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	transport.sent_controls.clear()
	session.swap_scene("arena", {&"mode": 1})
	assert_eq(_sent_to(4), [SceneCodec.encode_set(1, "arena", {&"mode": 1})])

func test_barrier_waits_for_host_and_all_clients() -> void:
	session.host(FAKE_PORT)
	_authenticate_peer(4)
	session.swap_scene("arena", {})
	watch_signals(session)
	session.confirm_scene_loaded()
	assert_signal_not_emitted(session, "scene_ready")
	session._confirm_scene(4, 1)
	assert_signal_emitted_with_parameters(session, "scene_ready", [1])

func test_host_confirm_without_open_barrier_is_noop() -> void:
	session.host(FAKE_PORT)
	watch_signals(session)
	session.confirm_scene_loaded()
	assert_signal_not_emitted(session, "scene_ready")
