extends GutTest

const TEST_PORT := "7794"
const TEST_ADDRESS := "127.0.0.1:" + TEST_PORT
const TIMEOUT_SECONDS := 3.0

class SpoofVersionAuthenticator extends VersionAuthenticator:
	func _get_project_name() -> String:
		return "GdLinkIntegration"

	func _get_project_version() -> String:
		return "1.0.0"

class RpcProbe extends Node:
	@export var replicated_value := 0
	var received_messages: Array = []

	@rpc("any_peer", "call_remote", "reliable")
	func ping(message: String) -> void:
		received_messages.append([message, multiplayer.get_remote_sender_id()])

class Endpoint extends RefCounted:
	var session: Session
	var rpc_peer: GdLinkRpcPeer
	var api: SceneMultiplayer
	var probe: RpcProbe

var host_endpoint: Endpoint
var client_endpoint: Endpoint

func after_each() -> void:
	if client_endpoint != null: client_endpoint.session.leave()
	if host_endpoint != null: host_endpoint.session.transport.close(GdLinkCore.DisconnectReason.VOLUNTARY)
	await _pump_until(_all_transports_destroyed)
	await get_tree().process_frame
	client_endpoint = null
	host_endpoint = null

func _all_transports_destroyed() -> bool:
	var host_done := host_endpoint == null \
		or (host_endpoint.session.transport as ENetTransport).connection == null
	var client_done := client_endpoint == null \
		or (client_endpoint.session.transport as ENetTransport).connection == null
	return host_done and client_done

func _make_endpoint() -> Endpoint:
	var endpoint := Endpoint.new()
	endpoint.session = add_child_autofree(Session.new())
	endpoint.session.setup(ENetTransport.new(), SpoofVersionAuthenticator.new())
	endpoint.rpc_peer = GdLinkRpcPeer.new(endpoint.session)
	watch_signals(endpoint.rpc_peer)
	endpoint.api = SceneMultiplayer.new()

	var scene_root = add_child_autofree(Node.new())
	get_tree().set_multiplayer(endpoint.api, scene_root.get_path())

	endpoint.probe = RpcProbe.new()
	endpoint.probe.name = "Probe"
	scene_root.add_child(endpoint.probe)

	var synchronizer := MultiplayerSynchronizer.new()
	synchronizer.name = "Sync"
	var replication_config := SceneReplicationConfig.new()
	replication_config.add_property(NodePath(":replicated_value"))
	synchronizer.replication_config = replication_config
	endpoint.probe.add_child(synchronizer)
	return endpoint

func _start_host() -> void:
	host_endpoint = _make_endpoint()
	assert_eq(host_endpoint.session.host(TEST_PORT), OK)
	host_endpoint.api.multiplayer_peer = host_endpoint.rpc_peer

func _connect_client() -> void:
	_start_host()
	client_endpoint = _make_endpoint()
	assert_eq(client_endpoint.session.join(TEST_ADDRESS), OK)
	client_endpoint.api.multiplayer_peer = client_endpoint.rpc_peer
	var connected := await _pump_until(func() -> bool:
		var client_identifier := client_endpoint.api.get_unique_id()
		return client_identifier > 1 and host_endpoint.api.get_peers().has(client_identifier))
	assert_true(connected, "client never connected through RPC peer")

func _pump_until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT_SECONDS * 1000)
	while Time.get_ticks_msec() < deadline:
		if condition.call(): return true
		await get_tree().process_frame
	return condition.call()

func test_client_connects_through_rpc_peer() -> void:
	await _connect_client()
	assert_eq(host_endpoint.api.get_peers().size(), 1)
	assert_eq(client_endpoint.api.get_unique_id(), host_endpoint.api.get_peers()[0])

func test_client_rpc_reaches_host_with_sender_id() -> void:
	await _connect_client()
	client_endpoint.probe.rpc_id(1, "ping", "from_client")
	var received := await _pump_until(func() -> bool:
		return host_endpoint.probe.received_messages.size() > 0)
	assert_true(received, "host never received client RPC")
	if not received: return
	assert_eq(host_endpoint.probe.received_messages[0], ["from_client", client_endpoint.api.get_unique_id()])

func test_host_rpc_reaches_client_with_host_sender() -> void:
	await _connect_client()
	host_endpoint.probe.rpc("ping", "from_host")
	var received := await _pump_until(func() -> bool:
		return client_endpoint.probe.received_messages.size() > 0)
	assert_true(received, "client never received host RPC")
	if not received: return
	assert_eq(client_endpoint.probe.received_messages[0], ["from_host", 1])

func test_replicated_property_syncs_host_to_client() -> void:
	await _connect_client()
	host_endpoint.probe.replicated_value = 42
	var synced := await _pump_until(func() -> bool:
		return client_endpoint.probe.replicated_value == 42)
	assert_true(synced, "replicated_value never synced to client")

func test_host_kick_propagates_to_client_rpc_peer() -> void:
	await _connect_client()
	var client_identifier := client_endpoint.api.get_unique_id()
	watch_signals(host_endpoint.api)
	host_endpoint.session.kick(client_identifier, GdLinkCore.DisconnectReason.KICKED)
	var disconnected := await _pump_until(func() -> bool:
		return client_endpoint.rpc_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED \
			and get_signal_emit_count(host_endpoint.api, "peer_disconnected") > 0)
	assert_true(disconnected, "client RPC peer or host peer_disconnected never fired")
	assert_signal_emitted_with_parameters(host_endpoint.api, "peer_disconnected", [client_identifier])
