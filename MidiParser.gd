class_name MidiParser
extends RefCounted

## MidiParser.gd
##
## A GDScript utility class for parsing Standard MIDI Files (.mid / SMF Type 0 and Type 1)
## and converting them into a chronological Array of NoteEvent resources for a rhythm game.

enum LaneMappingMode {
	MODULO,         ## pitch % lane_count
	PITCH_RANGE,    ## Uniformly distributes [min_pitch, max_pitch] into lane_count lanes
	OCTAVE_RANGE,   ## Wraps pitch into lanes within [min_pitch, max_pitch] (octave filter)
	CUSTOM_CALLABLE ## Uses custom_lane_mapper Callable: func(pitch: int, channel: int) -> int
}

# --- Configuration Properties ---

## Total number of rhythm game lanes (default: 5, typically 4 or 5, mapped to 0..lane_count-1).
@export_range(1, 5) var lane_count: int = 5

## Lane mapping strategy.
@export var mapping_mode: LaneMappingMode = LaneMappingMode.MODULO

## Lowest pitch for range-based mapping / filtering (default: 36 = C2).
@export var min_pitch: int = 36

## Highest pitch for range-based mapping / filtering (default: 84 = C6).
@export var max_pitch: int = 84

## If true, notes falling outside [min_pitch, max_pitch] are discarded.
@export var filter_out_of_range: bool = false

## Custom Callable for lane mapping: `func(pitch: int, channel: int) -> int`.
## Return an integer in [0, lane_count - 1], or -1 to discard the note.
@export var custom_lane_mapper: Callable

## If true, sustain pedal (CC 64) is checked per channel. If false, checked globally.
@export var match_sustain_per_channel: bool = true

## If true, note duration_ms is extended to sustain pedal release when pedal is held.
@export var extend_sustain_duration: bool = false

## Optional channel whitelist (0-15). If non-empty, only notes on these channels are parsed.
@export var channel_filter: Array[int] = []

## Optional track whitelist. If non-empty, only notes on these track indices are parsed.
@export var track_filter: Array[int] = []

## Last error message recorded during parsing, or empty if successful.
var last_error: String = ""

# --- Pitch Name Table ---
const NOTE_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# --- Internal Data Structures ---
var _tpq: int = 480
var _tempo_map: Array[Dictionary] = [] # Array of { "tick": int, "tempo_us": int, "start_ms": float }
var _cc64_events_by_channel: Dictionary = {} # channel: int -> Array[Dictionary] of { "tick": int, "value": int }
var _cc64_events_all: Array[Dictionary] = [] # Array of { "tick": int, "channel": int, "value": int }


## Convenience static method to quickly parse a MIDI file with default settings.
static func parse(p_path: String, p_lane_count: int = 5) -> Array[NoteEvent]:
	var parser := MidiParser.new()
	parser.lane_count = p_lane_count
	return parser.parse_file(p_path)


## Main parsing entry point. Reads the file and returns a sorted Array[NoteEvent].
func parse_file(file_path: String) -> Array[NoteEvent]:
	last_error = ""
	_tempo_map.clear()
	_cc64_events_by_channel.clear()
	_cc64_events_all.clear()

	if not FileAccess.file_exists(file_path):
		last_error = "File does not exist: %s" % file_path
		push_error("MidiParser: " + last_error)
		return []

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		last_error = "Failed to open file: %s (Error: %d)" % [file_path, FileAccess.get_open_error()]
		push_error("MidiParser: " + last_error)
		return []

	var file_size: int = file.get_length()
	if file_size < 14:
		last_error = "File is too small to be a valid MIDI file: %d bytes" % file_size
		push_error("MidiParser: " + last_error)
		file.close()
		return []

	var raw_bytes: PackedByteArray = file.get_buffer(file_size)
	file.close()

	var stream := StreamPeerBuffer.new()
	stream.data_array = raw_bytes
	stream.big_endian = true

	# 1. Parse Header Chunk (MThd)
	var header_tag_res: Array = stream.get_data(4)
	if header_tag_res[0] != OK or header_tag_res[1].get_string_from_ascii() != "MThd":
		last_error = "Invalid MIDI header: Missing 'MThd' signature"
		push_error("MidiParser: " + last_error)
		return []

	var header_length: int = stream.get_u32()
	if header_length < 6:
		last_error = "Invalid MIDI header length: %d (expected at least 6)" % header_length
		push_error("MidiParser: " + last_error)
		return []

	var format: int = stream.get_u16()
	var ntrks: int = stream.get_u16()
	var division: int = stream.get_u16()

	# Skip any extra bytes if header length > 6
	if header_length > 6:
		stream.seek(stream.get_position() + (header_length - 6))

	if format != 0 and format != 1:
		last_error = "Unsupported SMF format: %d (only Type 0 and Type 1 are supported)" % format
		push_error("MidiParser: " + last_error)
		return []

	if ntrks == 0:
		last_error = "MIDI file has 0 tracks"
		push_error("MidiParser: " + last_error)
		return []

	# Division (TPQ) handling
	if (division & 0x8000) != 0:
		# SMPTE timecode (rare in rhythm game MIDIs)
		var frames_per_sec: int = -(division >> 8) & 0xFF
		var ticks_per_frame: int = division & 0xFF
		_tpq = frames_per_sec * ticks_per_frame
		if _tpq <= 0:
			_tpq = 480
	else:
		_tpq = division & 0x7FFF

	if _tpq <= 0:
		_tpq = 480

	# 2. Parse All Tracks
	var raw_tempos: Array[Dictionary] = []
	var raw_notes: Array[Dictionary] = [] # { track, channel, pitch, start_tick, end_tick, velocity }

	for track_idx in range(ntrks):
		if stream.get_available_bytes() < 8:
			break # EOF reached early

		var chunk_tag_res: Array = stream.get_data(4)
		if chunk_tag_res[0] != OK:
			break

		var chunk_id: String = chunk_tag_res[1].get_string_from_ascii()
		var chunk_length: int = stream.get_u32()
		var chunk_end_pos: int = stream.get_position() + chunk_length

		if chunk_id != "MTrk":
			# Skip non-track chunk
			stream.seek(chunk_end_pos)
			continue

		var track_notes: Array[Dictionary] = _parse_track(stream, chunk_end_pos, track_idx, raw_tempos)
		raw_notes.append_array(track_notes)

		# Ensure stream position is at the end of the chunk
		if stream.get_position() != chunk_end_pos:
			stream.seek(chunk_end_pos)

	# 3. Build Global Tempo Map
	_build_tempo_map(raw_tempos)

	# Sort CC 64 events
	_sort_sustain_events()

	# 4. Convert Notes into NoteEvent Objects
	var result_events: Array[NoteEvent] = []

	for n in raw_notes:
		# Channel filter
		if not channel_filter.is_empty() and not channel_filter.has(n.channel):
			continue
		# Track filter
		if not track_filter.is_empty() and not track_filter.has(n.track):
			continue

		var lane: int = get_lane_for_pitch(n.pitch, n.channel)
		if lane < 0:
			continue # Filtered out

		var is_sustain: bool = is_sustain_pedal_active(n.start_tick, n.end_tick, n.channel)

		var effective_end_tick: int = n.end_tick
		if extend_sustain_duration and is_sustain:
			effective_end_tick = _get_extended_sustain_end_tick(n.end_tick, n.channel)

		var start_ms: float = tick_to_ms(n.start_tick)
		var end_ms: float = tick_to_ms(effective_end_tick)
		var duration_ms: float = maxf(0.0, end_ms - start_ms)
		var pitch_name_str: String = pitch_to_name(n.pitch)

		var event := NoteEvent.new(
			start_ms,
			lane,
			pitch_name_str,
			duration_ms,
			is_sustain
		)
		result_events.append(event)

	# 5. Chronological Sort
	result_events.sort_custom(func(a: NoteEvent, b: NoteEvent) -> bool:
		if not is_equal_approx(a.timestamp_ms, b.timestamp_ms):
			return a.timestamp_ms < b.timestamp_ms
		if a.lane != b.lane:
			return a.lane < b.lane
		return a.duration_ms < b.duration_ms
	)

	return result_events


## Parses a single MTrk chunk and returns note intervals and populates tempo and CC events.
func _parse_track(stream: StreamPeerBuffer, track_end_pos: int, track_idx: int, out_tempos: Array[Dictionary]) -> Array[Dictionary]:
	var current_tick: int = 0
	var running_status: int = 0
	var notes: Array[Dictionary] = []

	# Active notes tracking: key = (channel << 8) | pitch -> Array[Dictionary] (FIFO queue)
	var active_notes: Dictionary = {}

	while stream.get_position() < track_end_pos:
		var delta_time: int = _read_vlq(stream)
		current_tick += delta_time

		if stream.get_position() >= track_end_pos:
			break

		var first_byte: int = stream.get_u8()
		var status_byte: int = 0
		var is_running_status: bool = false

		if (first_byte & 0x80) != 0:
			status_byte = first_byte
		else:
			# Running status
			if running_status == 0:
				# Corrupt track: running status used without previous status
				break
			status_byte = running_status
			is_running_status = true

		# Handle Meta Events (0xFF)
		if status_byte == 0xFF:
			var meta_type: int = stream.get_u8()
			var meta_len: int = _read_vlq(stream)

			if meta_type == 0x51 and meta_len >= 3:
				# Set Tempo (Microseconds per quarter note)
				var d0: int = stream.get_u8()
				var d1: int = stream.get_u8()
				var d2: int = stream.get_u8()
				var tempo_us: int = (d0 << 16) | (d1 << 8) | d2
				out_tempos.append({ "tick": current_tick, "tempo_us": tempo_us })
				if meta_len > 3:
					stream.seek(stream.get_position() + (meta_len - 3))
			elif meta_type == 0x2F:
				# End of Track
				if meta_len > 0:
					stream.seek(stream.get_position() + meta_len)
				break
			else:
				# Skip unhandled meta event
				if meta_len > 0:
					stream.seek(stream.get_position() + meta_len)
			continue

		# Handle SysEx Events (0xF0, 0xF7)
		if status_byte == 0xF0 or status_byte == 0xF7:
			running_status = 0 # SysEx resets running status
			var sysex_len: int = _read_vlq(stream)
			if sysex_len > 0:
				stream.seek(stream.get_position() + sysex_len)
			continue

		# Channel Voice Messages (0x80..0xEF)
		if status_byte >= 0x80 and status_byte <= 0xEF:
			running_status = status_byte
			var message_type: int = status_byte & 0xF0
			var channel: int = status_byte & 0x0F

			var byte1: int = first_byte if is_running_status else stream.get_u8()

			match message_type:
				0x80: # Note Off
					var byte2: int = stream.get_u8()
					_on_note_off(active_notes, notes, track_idx, channel, byte1, current_tick)

				0x90: # Note On
					var byte2: int = stream.get_u8()
					if byte2 == 0:
						# Note On with velocity 0 is Note Off
						_on_note_off(active_notes, notes, track_idx, channel, byte1, current_tick)
					else:
						_on_note_on(active_notes, track_idx, channel, byte1, byte2, current_tick)

				0xA0: # Polyphonic Key Pressure
					stream.get_u8()

				0xB0: # Control Change
					var byte2: int = stream.get_u8()
					if byte1 == 64: # Sustain Pedal (CC 64)
						_record_sustain_event(current_tick, channel, byte2)

				0xC0: # Program Change (1 data byte)
					pass

				0xD0: # Channel Pressure (1 data byte)
					pass

				0xE0: # Pitch Bend (2 data bytes)
					stream.get_u8()

	# Close any remaining open notes at track end
	for key in active_notes.keys():
		var queue: Array = active_notes[key]
		for open_note in queue:
			var end_tick: int = max(current_tick, open_note.start_tick + 1)
			notes.append({
				"track": open_note.track,
				"channel": open_note.channel,
				"pitch": open_note.pitch,
				"start_tick": open_note.start_tick,
				"end_tick": end_tick,
				"velocity": open_note.velocity
			})
	active_notes.clear()

	return notes


func _on_note_on(active_notes: Dictionary, track_idx: int, channel: int, pitch: int, velocity: int, tick: int) -> void:
	var key: int = (channel << 8) | pitch
	if not active_notes.has(key):
		active_notes[key] = []
	active_notes[key].append({
		"track": track_idx,
		"channel": channel,
		"pitch": pitch,
		"velocity": velocity,
		"start_tick": tick
	})


func _on_note_off(active_notes: Dictionary, notes: Array[Dictionary], _track_idx: int, channel: int, pitch: int, tick: int) -> void:
	var key: int = (channel << 8) | pitch
	if active_notes.has(key) and not active_notes[key].is_empty():
		var open_note: Dictionary = active_notes[key].pop_front()
		notes.append({
			"track": open_note.track,
			"channel": open_note.channel,
			"pitch": open_note.pitch,
			"start_tick": open_note.start_tick,
			"end_tick": tick,
			"velocity": open_note.velocity
		})


func _record_sustain_event(tick: int, channel: int, value: int) -> void:
	var ev := { "tick": tick, "channel": channel, "value": value }
	_cc64_events_all.append(ev)
	if not _cc64_events_by_channel.has(channel):
		_cc64_events_by_channel[channel] = []
	_cc64_events_by_channel[channel].append(ev)


func _sort_sustain_events() -> void:
	_cc64_events_all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.tick < b.tick
	)
	for ch in _cc64_events_by_channel.keys():
		_cc64_events_by_channel[ch].sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.tick < b.tick
		)


## Reads a Variable Length Quantity (VLQ) from the stream.
static func _read_vlq(stream: StreamPeerBuffer) -> int:
	var value: int = 0
	for i in range(4):
		if stream.get_available_bytes() < 1:
			return value
		var b: int = stream.get_u8()
		value = (value << 7) | (b & 0x7F)
		if (b & 0x80) == 0:
			return value
	return value


## Builds the cumulative tempo map for O(log N) tick-to-ms conversion.
func _build_tempo_map(raw_tempos: Array[Dictionary]) -> void:
	_tempo_map.clear()
	raw_tempos.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.tick < b.tick
	)

	var default_tempo_us: int = 500000 # 120 BPM default

	if raw_tempos.is_empty():
		_tempo_map.append({ "tick": 0, "tempo_us": default_tempo_us, "start_ms": 0.0 })
		return

	# If the first tempo event is after tick 0, prepend default tempo at tick 0
	if raw_tempos[0].tick > 0:
		_tempo_map.append({ "tick": 0, "tempo_us": default_tempo_us, "start_ms": 0.0 })

	for t in raw_tempos:
		if _tempo_map.is_empty():
			_tempo_map.append({ "tick": t.tick, "tempo_us": t.tempo_us, "start_ms": 0.0 })
		elif _tempo_map[-1].tick == t.tick:
			# Overwrite tempo at identical tick
			_tempo_map[-1].tempo_us = t.tempo_us
		else:
			var prev: Dictionary = _tempo_map[-1]
			var delta_ticks: int = t.tick - prev.tick
			var delta_ms: float = (float(delta_ticks) * float(prev.tempo_us)) / (float(_tpq) * 1000.0)
			_tempo_map.append({
				"tick": t.tick,
				"tempo_us": t.tempo_us,
				"start_ms": prev.start_ms + delta_ms
			})


## Converts a MIDI tick value to absolute milliseconds using the active tempo map.
func tick_to_ms(tick: int) -> float:
	if _tempo_map.is_empty():
		return 0.0

	var low: int = 0
	var high: int = _tempo_map.size() - 1
	var best_idx: int = 0

	while low <= high:
		var mid: int = (low + high) >> 1
		if _tempo_map[mid].tick <= tick:
			best_idx = mid
			low = mid + 1
		else:
			high = mid - 1

	var entry: Dictionary = _tempo_map[best_idx]
	var delta_ticks: int = tick - entry.tick
	return entry.start_ms + (float(delta_ticks) * float(entry.tempo_us)) / (float(_tpq) * 1000.0)


## Determines if the sustain pedal (CC 64) is depressed when a note is active or hit.
## Returns true if pedal is depressed (value >= 64) at start_tick or any time within [start_tick, end_tick].
func is_sustain_pedal_active(start_tick: int, end_tick: int, channel: int) -> bool:
	var events: Array = []
	if match_sustain_per_channel:
		events = _cc64_events_by_channel.get(channel, [])
	else:
		events = _cc64_events_all

	if events.is_empty():
		return false

	# 1. Check if pedal was depressed at start_tick (look at the last CC 64 event at or before start_tick)
	var low: int = 0
	var high: int = events.size() - 1
	var last_idx: int = -1

	while low <= high:
		var mid: int = (low + high) >> 1
		if events[mid].tick <= start_tick:
			last_idx = mid
			low = mid + 1
		else:
			high = mid - 1

	if last_idx >= 0 and events[last_idx].value >= 64:
		return true

	# 2. Check if pedal was pressed down while note was active (strictly before note off)
	var check_idx: int = 0 if last_idx < 0 else last_idx + 1
	while check_idx < events.size() and events[check_idx].tick < end_tick:
		if events[check_idx].value >= 64:
			return true
		check_idx += 1

	return false


## If sustain pedal is held at note end, finds the tick when the pedal is released.
func _get_extended_sustain_end_tick(end_tick: int, channel: int) -> int:
	var events: Array = []
	if match_sustain_per_channel:
		events = _cc64_events_by_channel.get(channel, [])
	else:
		events = _cc64_events_all

	if events.is_empty():
		return end_tick

	# Find pedal state at end_tick
	var low: int = 0
	var high: int = events.size() - 1
	var last_idx: int = -1

	while low <= high:
		var mid: int = (low + high) >> 1
		if events[mid].tick <= end_tick:
			last_idx = mid
			low = mid + 1
		else:
			high = mid - 1

	# If pedal is not depressed at end_tick, no extension needed
	if last_idx < 0 or events[last_idx].value < 64:
		return end_tick

	# Search for the next release event (value < 64) after end_tick
	for i in range(last_idx + 1, events.size()):
		if events[i].value < 64:
			return events[i].tick

	return end_tick


## Maps a MIDI pitch number (0-127) into a game lane index (0 to lane_count - 1).
## Returns -1 if the note is filtered out.
func get_lane_for_pitch(pitch: int, channel: int = 0) -> int:
	if lane_count <= 0:
		return 0

	# Custom callable mapping
	if mapping_mode == LaneMappingMode.CUSTOM_CALLABLE and custom_lane_mapper.is_valid():
		var args_count: int = custom_lane_mapper.get_argument_count()
		var res: Variant
		if args_count == 1:
			res = custom_lane_mapper.call(pitch)
		else:
			res = custom_lane_mapper.call(pitch, channel)

		if res is int:
			if res < 0:
				return -1 # Filtered
			return clampi(res, 0, lane_count - 1)
		return 0

	# Pitch range mapping
	if mapping_mode == LaneMappingMode.PITCH_RANGE:
		if pitch < min_pitch or pitch > max_pitch:
			if filter_out_of_range:
				return -1
			pitch = clampi(pitch, min_pitch, max_pitch)
		var span: float = float(max_pitch - min_pitch + 1)
		var norm: float = float(pitch - min_pitch) / span
		var lane: int = int(floor(norm * float(lane_count)))
		return clampi(lane, 0, lane_count - 1)

	# Octave range mapping
	if mapping_mode == LaneMappingMode.OCTAVE_RANGE:
		if pitch < min_pitch or pitch > max_pitch:
			return -1
		return posmod(pitch - min_pitch, lane_count)

	# Default: MODULO mapping
	if filter_out_of_range and (pitch < min_pitch or pitch > max_pitch):
		return -1
	return posmod(pitch, lane_count)


## Converts a MIDI note number (0-127) to standard pitch name notation (e.g. 60 -> "C4").
static func pitch_to_name(pitch: int) -> String:
	var note_name: String = NOTE_NAMES[posmod(pitch, 12)]
	var octave: int = int(floor(float(pitch) / 12.0)) - 1
	return "%s%d" % [note_name, octave]
