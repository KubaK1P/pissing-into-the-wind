class_name ChartExporter
extends RefCounted

## ChartExporter.gd
##
## A GDScript utility for converting raw MIDI files into curated, lightweight JSON chart files.
## Uses MidiParser to parse the MIDI data and NoteEvent for serialization.

## Default lowest MIDI pitch to retain (48 is C3, one octave below Middle C; Middle C is 60).
## Notes below this threshold (e.g., heavy bass accompaniment) are stripped out.
@export var min_pitch: int = 48

## Default highest MIDI pitch to retain (127 is highest standard MIDI note).
@export var max_pitch: int = 127

## Number of lanes for the rhythm game (typically 4 or 5).
@export var lane_count: int = 5

## Indentation characters used for JSON formatting (e.g., "\t" or "  ").
@export var indent: String = "\t"

## Recorded error message if export fails.
var last_error: String = ""


## Static convenience method to parse a MIDI file and export it directly to a JSON chart file.
static func export_midi_to_json(
	p_midi_path: String,
	p_output_json_path: String,
	p_min_pitch: int = 48,
	p_max_pitch: int = 127,
	p_lane_count: int = 5
) -> bool:
	var exporter := ChartExporter.new()
	exporter.min_pitch = p_min_pitch
	exporter.max_pitch = p_max_pitch
	exporter.lane_count = p_lane_count
	return exporter.export_midi_to_chart(p_midi_path, p_output_json_path)


## Exports a MIDI file to a curated JSON chart file.
## Configures MidiParser and performs pitch-range filtering before writing to disk.
func export_midi_to_chart(
	midi_path: String,
	output_json_path: String,
	custom_parser: MidiParser = null
) -> bool:
	last_error = ""

	if not FileAccess.file_exists(midi_path):
		last_error = "MIDI file does not exist: %s" % midi_path
		push_error("ChartExporter: " + last_error)
		return false

	# 1. Parse the MIDI file using MidiParser
	var parser: MidiParser = custom_parser
	if parser == null:
		parser = MidiParser.new()
		parser.lane_count = lane_count
		parser.min_pitch = min_pitch
		parser.max_pitch = max_pitch
		parser.filter_out_of_range = true

	var parsed_notes: Array[NoteEvent] = parser.parse_file(midi_path)
	if parsed_notes.is_empty() and not parser.last_error.is_empty():
		last_error = "Failed to parse MIDI file: %s" % parser.last_error
		push_error("ChartExporter: " + last_error)
		return false

	# 2. Apply pitch filtering (strips bass accompaniment below min_pitch or above max_pitch)
	var filtered_notes: Array[NoteEvent] = filter_notes_by_pitch(parsed_notes, min_pitch, max_pitch)

	# 3. Export the filtered notes to JSON
	return export_notes_to_chart(filtered_notes, output_json_path)


## Filters an array of NoteEvents according to a minimum and maximum MIDI pitch.
## Any note whose pitch falls outside [p_min_pitch, p_max_pitch] is excluded.
func filter_notes_by_pitch(
	notes: Array[NoteEvent],
	p_min_pitch: int,
	p_max_pitch: int = 127
) -> Array[NoteEvent]:
	var result: Array[NoteEvent] = []
	for note in notes:
		var pitch_num: int = NoteEvent.pitch_name_to_midi(note.pitch_name)
		if pitch_num >= 0 and (pitch_num < p_min_pitch or pitch_num > p_max_pitch):
			continue
		result.append(note)
	return result


## Serializes an Array of NoteEvent objects into formatted JSON and saves it to output_json_path.
func export_notes_to_chart(notes: Array[NoteEvent], output_json_path: String) -> bool:
	last_error = ""

	if output_json_path.strip_edges().is_empty():
		last_error = "Target JSON output path is empty"
		push_error("ChartExporter: " + last_error)
		return false

	# Ensure parent directory exists
	var dir_path: String = output_json_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var dir_err: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if dir_err != OK:
			last_error = "Failed to create directory '%s' (Error: %d)" % [dir_path, dir_err]
			push_error("ChartExporter: " + last_error)
			return false

	# Convert notes to an array of serializable dictionaries
	var serialized_notes: Array[Dictionary] = []
	for note in notes:
		if note != null:
			serialized_notes.append(note.to_dict())

	# Generate indented JSON string
	var json_string: String = JSON.stringify(serialized_notes, indent)

	# Write to disk
	var file := FileAccess.open(output_json_path, FileAccess.WRITE)
	if file == null:
		last_error = "Failed to open file for writing: %s (Error: %d)" % [output_json_path, FileAccess.get_open_error()]
		push_error("ChartExporter: " + last_error)
		return false

	file.store_string(json_string)
	file.close()

	return true
