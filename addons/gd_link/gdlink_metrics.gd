## Samples link quality and traffic into a fixed ring per peer. Local only, never on the wire.
class_name GdLinkMetrics
extends RefCounted

enum Mode {
	OFF,
	RTT_ONLY,
	QUALITY_ONLY,
	DATA_IO_ONLY,
	ALL,
	}

const FLAG_RTT := 1
const FLAG_LOSS := 2
const FLAG_DATA_IO := 4
const RING_SLOTS := 10
const SAMPLE_INTERVAL_SECONDS := 1.0
const TRAFFIC_KEYS: Array[String] = ["packets_in", "packets_out", "bytes_in", "bytes_out"]

## Per-peer ring and baseline totals used for deltas.
class PeerWindow extends RefCounted:
	var samples: Array[Dictionary] = []
	var write_index := 0
	var baseline: Dictionary = {}

var flags := 0
var windows: Dictionary = {}

func set_mode(mode: Mode) -> void:
	flags = _flags_for_mode(mode)
	clear()

func is_enabled() -> bool:
	return flags != 0

## Drops all windows and baselines.
func clear() -> void:
	windows.clear()

func forget_peer(peer_identifier: int) -> void:
	windows.erase(peer_identifier)

## Samples one peer. Returns this tick's values: packets_in/out and bytes_in/out as
## per-second rates, plus rtt_msec and loss when enabled. Empty on the baseline tick.
func sample_peer(transport: Transport, peer_identifier: int) -> Dictionary:
	if not is_enabled(): return {}
	var window: PeerWindow = windows.get(peer_identifier)
	if window == null:
		window = _create_window()
		windows[peer_identifier] = window
	var totals := _read_totals(transport, peer_identifier)
	var previous := window.baseline
	window.baseline = totals
	if previous.is_empty(): return {}
	var sample := {}
	if flags & FLAG_DATA_IO:
		sample.merge(_traffic_rates(previous, totals))
	if flags & (FLAG_RTT | FLAG_LOSS):
		sample.merge(_link_quality(transport, peer_identifier))
	_push(window, sample)
	return sample

## Returns {latest, average, min, max}, each keyed by metric name. Empty if unknown peer.
func get_snapshot(peer_identifier: int) -> Dictionary:
	var window: PeerWindow = windows.get(peer_identifier)
	if window == null: return {}
	var latest_index := (window.write_index + RING_SLOTS - 1) % RING_SLOTS
	var sums := {}
	var counts := {}
	var minimums := {}
	var maximums := {}
	for sample: Dictionary in window.samples:
		for key: String in sample:
			var value: float = sample[key]
			if not counts.has(key):
				counts[key] = 0
				sums[key] = 0.0
				minimums[key] = value
				maximums[key] = value
			counts[key] += 1
			sums[key] += value
			minimums[key] = minf(minimums[key], value)
			maximums[key] = maxf(maximums[key], value)
	var averages := {}
	for key: String in sums:
		averages[key] = sums[key] / counts[key]
	return {"latest": window.samples[latest_index], "average": averages, "min": minimums, "max": maximums}

static func _flags_for_mode(mode: Mode) -> int:
	match mode:
		Mode.RTT_ONLY: return FLAG_RTT
		Mode.QUALITY_ONLY: return FLAG_RTT | FLAG_LOSS
		Mode.DATA_IO_ONLY: return FLAG_DATA_IO
		Mode.ALL: return FLAG_RTT | FLAG_LOSS | FLAG_DATA_IO
	return 0

func _create_window() -> PeerWindow:
	var window := PeerWindow.new()
	for index in RING_SLOTS:
		window.samples.append({})
	return window

func _push(window: PeerWindow, sample: Dictionary) -> void:
	window.samples[window.write_index] = sample
	window.write_index = (window.write_index + 1) % RING_SLOTS

func _read_totals(transport: Transport, peer_identifier: int) -> Dictionary:
	var counters: Transport.TrafficCounters = transport.get_traffic_counters(peer_identifier)
	if counters == null: counters = Transport.TrafficCounters.new()
	return {
		"packets_in": counters.packets_in,
		"packets_out": counters.packets_out,
		"bytes_in": counters.bytes_in,
		"bytes_out": counters.bytes_out,
	}

func _traffic_rates(previous: Dictionary, current: Dictionary) -> Dictionary:
	var rates := {}
	for key: String in TRAFFIC_KEYS:
		rates[key] = (current[key] - previous[key]) / SAMPLE_INTERVAL_SECONDS
	return rates

func _link_quality(transport: Transport, peer_identifier: int) -> Dictionary:
	var stats := transport.get_link_stats(peer_identifier)
	var quality := {}
	if stats.is_empty():
		return quality
	if flags & FLAG_RTT:
		quality["rtt_msec"] = stats.get("rtt_msec", 0.0)
	if flags & FLAG_LOSS:
		quality["loss"] = stats.get("loss", 0.0)
	return quality
