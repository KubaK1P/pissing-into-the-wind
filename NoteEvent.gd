class_name NoteEvent
extends Resource

@export var timestamp_ms: float = 0.0
@export_range(0, 4) var lane: int = 0
@export var pitch_name: String = ""
@export var duration_ms: float = 0.0
@export var is_sustain: bool = false

const NOTE_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

func _init(
	p_timestamp_ms: float = 0.0,
	p_lane: int = 0,
	p_pitch_name: String = "",
	p_duration_ms: float = 0.0,
	p_is_sustain: bool = false
) -> void:
	timestamp_ms = p_timestamp_ms
	lane = p_lane
	pitch_name = p_pitch_name
	duration_ms = p_duration_ms
	is_sustain = p_is_sustain


## Exports all properties to a Dictionary.
func to_dict() -> Dictionary:
	return {
		"timestamp_ms": timestamp_ms,
		"lane": lane,
		"pitch_name": pitch_name,
		"duration_ms": duration_ms,
		"is_sustain": is_sustain
	}


## Instantiates and returns a NoteEvent from dictionary data.
static func from_dict(data: Dictionary) -> NoteEvent:
	return NoteEvent.new(
		float(data.get("timestamp_ms", 0.0)),
		int(data.get("lane", 0)),
		str(data.get("pitch_name", "")),
		float(data.get("duration_ms", 0.0)),
		bool(data.get("is_sustain", false))
	)


## Helper to convert a pitch name (e.g. "C4", "F#3", "C-1") back into a MIDI pitch number (0-127).
## Returns -1 if the name cannot be parsed.
static func pitch_name_to_midi(name_str: String) -> int:
	if name_str.is_empty():
		return -1

	var clean_name: String = name_str.strip_edges().to_upper()
	var note_token: String = ""
	var octave_start: int = 1

	if clean_name.length() >= 2 and (clean_name[1] == '#' or clean_name[1] == 'B'):
		# Sharp or flat
		if clean_name[1] == 'B':
			# Convert flat to sharp equivalent (e.g., Db -> C#, Eb -> D#, Gb -> F#, Ab -> G#, Bb -> A#)
			match clean_name.substr(0, 2):
				"DB": note_token = "C#"
				"EB": note_token = "D#"
				"GB": note_token = "F#"
				"AB": note_token = "G#"
				"BB": note_token = "A#"
				_: note_token = clean_name.substr(0, 2)
		else:
			note_token = clean_name.substr(0, 2)
		octave_start = 2
	else:
		note_token = clean_name.substr(0, 1)
		octave_start = 1

	var note_idx: int = NOTE_NAMES.find(note_token)
	if note_idx < 0:
		return -1

	var octave_str: String = clean_name.substr(octave_start)
	if octave_str.is_empty() or not octave_str.is_valid_int():
		return -1

	var octave: int = octave_str.to_int()
	var midi_pitch: int = (octave + 1) * 12 + note_idx
	return midi_pitch
