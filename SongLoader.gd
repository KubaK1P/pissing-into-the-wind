class_name SongLoader
extends RefCounted

## SongLoader.gd
##
## A runtime utility for loading curated rhythm game chart files (.json)
## and reconstructing them into an Array[NoteEvent] for the note highway.

## Last recorded error message when loading fails.
var last_error: String = ""


## Convenience static function to load a chart directly from a JSON file.
static func load_chart_file(json_path: String) -> Array[NoteEvent]:
	var loader := SongLoader.new()
	return loader.load_chart(json_path)


## Loads a chart file from disk and parses it into an Array[NoteEvent].
func load_chart(json_path: String) -> Array[NoteEvent]:
	last_error = ""

	# 1. Check file existence
	if not FileAccess.file_exists(json_path):
		last_error = "Chart file does not exist: %s" % json_path
		push_error("SongLoader: " + last_error)
		return []

	# 2. Open and read file contents
	var file := FileAccess.open(json_path, FileAccess.READ)
	if file == null:
		last_error = "Failed to open chart file '%s' (Error: %d)" % [json_path, FileAccess.get_open_error()]
		push_error("SongLoader: " + last_error)
		return []

	var json_text: String = file.get_as_text()
	file.close()

	if json_text.strip_edges().is_empty():
		last_error = "Chart file is empty: %s" % json_path
		push_error("SongLoader: " + last_error)
		return []

	# 3. Parse JSON string
	var parsed_data: Variant = JSON.parse_string(json_text)
	if parsed_data == null:
		last_error = "Failed to parse JSON (malformed syntax) in: %s" % json_path
		push_error("SongLoader: " + last_error)
		return []

	# 4. Extract raw note array (supports both direct Array and { "notes": [...] } wrapper)
	var raw_notes: Array = []
	if parsed_data is Array:
		raw_notes = parsed_data
	elif parsed_data is Dictionary and parsed_data.has("notes") and parsed_data["notes"] is Array:
		raw_notes = parsed_data["notes"]
	else:
		last_error = "Invalid chart structure in '%s'. Expected Array of notes or Dictionary containing 'notes' array." % json_path
		push_error("SongLoader: " + last_error)
		return []

	# 5. Reconstruct NoteEvent objects
	var notes: Array[NoteEvent] = []
	for i in range(raw_notes.size()):
		var element: Variant = raw_notes[i]
		if element is Dictionary:
			var note_event: NoteEvent = NoteEvent.from_dict(element)
			notes.append(note_event)
		else:
			push_warning("SongLoader: Skipping non-dictionary entry at index %d in '%s'" % [i, json_path])

	return notes
