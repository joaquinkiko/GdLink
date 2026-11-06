extends GutTest

class SpoofVersionAuthenticator extends VersionAuthenticator:
	func _get_project_name() -> String:
		return "GdLinkScene"

	func _get_project_version() -> String:
		return "1.0.0"

const TEST_PORT := "7795"
const TEST_ADDRESS := "127.0.0.1:" + TEST_PORT
const TIMEOUT_SECONDS := 3.0

var host_session: Session
var client_sessions: Array[Session] = []

func after_each() -> void:
	for client in client_sessions:
		client.leave()
	if host_session != null: host_session.transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	await wait_until(_all_transports_closed, TIMEOUT_SECONDS)
	client_sessions.clear()

func _all_transports_closed() -> bool:
	if (host_session.transport as ENetTransport).connection != null: return false
	for client in client_sessions:
		if (client.transport as ENetTransport).connection != null: return false
	return true

func _make_session() -> Session:
	var session := Session.new()
	add_child_autofree(session)
	session.setup(ENetTransport.new(), SpoofVersionAuthenticator.new())
	return session

func _start_host() -> void:
	host_session = _make_session()
	host_session.host(TEST_PORT)

func _join_client() -> Session:
	var client := _make_session()
	client.join(TEST_ADDRESS)
	client_sessions.append(client)
	await wait_until(func() -> bool: return client.is_client_authenticated, TIMEOUT_SECONDS)
	return client

func test_swap_completes_after_host_and_client_confirm() -> void:
	_start_host()
	var client: Session = await _join_client()
	watch_signals(host_session)
	watch_signals(client)
	host_session.swap_scene("arena", {&"mode": 1})
	host_session.confirm_scene_loaded()
	await wait_until(func() -> bool: return get_signal_emit_count(client, "scene_changed") > 0, TIMEOUT_SECONDS)
	client.confirm_scene_loaded()
	await wait_until(func() -> bool:
		return get_signal_emit_count(host_session, "scene_ready") > 0 \
			and get_signal_emit_count(client, "scene_ready") > 0, TIMEOUT_SECONDS)
	assert_signal_emitted_with_parameters(client, "scene_changed", ["arena", {&"mode": 1}])
	assert_signal_emitted_with_parameters(host_session, "scene_ready", [1])
	assert_signal_emitted_with_parameters(client, "scene_ready", [1])

func test_meta_flows_and_data_blocked_during_barrier() -> void:
	_start_host()
	var client: Session = await _join_client()
	var client_identifier: int = host_session.get_authenticated_peers()[0].peer_identifier
	host_session.swap_scene("arena", {})
	host_session.confirm_scene_loaded()
	watch_signals(client)
	host_session.set_server_meta(&"round", 2)
	host_session.send_data(client_identifier, 0, PackedByteArray([1]), true)
	await wait_until(func() -> bool: return client.get_server_meta().has(&"round"), TIMEOUT_SECONDS)
	assert_eq(client.get_server_meta()[&"round"], 2)
	assert_signal_not_emitted(client, "data_received")

func test_late_joiner_receives_pending_scene_and_must_confirm() -> void:
	_start_host()
	var first: Session = await _join_client()
	host_session.swap_scene("arena", {})
	host_session.confirm_scene_loaded()
	var second: Session = await _join_client()
	await wait_until(func() -> bool: return second.scene_gate.is_open, TIMEOUT_SECONDS)
	watch_signals(host_session)
	first.confirm_scene_loaded()
	await get_tree().create_timer(0.2).timeout
	assert_signal_not_emitted(host_session, "scene_ready")
	second.confirm_scene_loaded()
	await wait_until(func() -> bool: return get_signal_emit_count(host_session, "scene_ready") > 0, TIMEOUT_SECONDS)
	assert_signal_emitted_with_parameters(host_session, "scene_ready", [1])

func test_unconfirmed_client_is_kicked_on_timeout() -> void:
	_start_host()
	var client: Session = await _join_client()
	watch_signals(client)
	host_session.swap_scene("arena", {}, 0.2)
	host_session.confirm_scene_loaded()
	await wait_until(func() -> bool: return get_signal_emit_count(client, "session_closed") > 0, TIMEOUT_SECONDS)
	assert_signal_emitted_with_parameters(client, "session_closed",
		[GdLinkCore.DisconnectReason.SCENE_LOAD_TIMEOUT])
