## Barrier state for scene swaps
class_name SceneGate
extends RefCounted

var epoch := 0
var current_scene := ""
var current_args: Dictionary
var is_open := false
var pending_identifiers: Dictionary

## Opens a barrier for [param member_identifiers] at a new epoch.
func begin_swap(scene: String, args: Dictionary, member_identifiers: Array[int]) -> void:
	epoch += 1
	current_scene = scene
	current_args = args.duplicate(true)
	pending_identifiers.clear()
	for identifier in member_identifiers:
		pending_identifiers[identifier] = true
	is_open = true

## Returns true if peer_identifier was pending for confirm_epoch.
func confirm(peer_identifier: int, confirm_epoch: int) -> bool:
	if not (is_open && confirm_epoch == epoch):
		return false
	return pending_identifiers.erase(peer_identifier)

## Returns true if peer_identifier was pending.
func remove_peer(peer_identifier: int) -> bool:
	return is_open && pending_identifiers.erase(peer_identifier)

func is_pending(peer_identifier: int) -> bool:
	return is_open && pending_identifiers.has(peer_identifier)

func is_complete() -> bool:
	return is_open && pending_identifiers.is_empty()

func close() -> void:
	is_open = false
	pending_identifiers.clear()
