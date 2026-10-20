class_name MainGame
extends Control

## MainGame.gd
##
## Main gameplay scene bootstrap script for the Godot 4 upright piano rhythm/horror game.
## Bootstraps an initial chart file (generating res://charts/test_song.json if absent),
## initializes the NoteHighway, hooks up gameplay signals, and starts the song clock.

@export var chart_path: String = "res://charts/test_song.json"

var note_highway: NoteHighway
var score_label: Label
var combo_label: Label
var status_label: Label
var instructions_label: Label


func _ready() -> void:
	_setup_ui()
	_ensure_chart_exists()
	_load_and_play()


## Constructs the visual layout and adds NoteHighway as a centered child.
func _setup_ui() -> void:
	# Full screen layout
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Deep charcoal horror background
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.04, 0.04, 0.05, 1.0)
	add_child(bg)

	# Center container for Note Highway
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	# Note Highway instance
	note_highway = NoteHighway.new()
	note_highway.custom_minimum_size = Vector2(440, 680)
	center.add_child(note_highway)

	# Connect highway signals
	note_highway.note_hit.connect(_on_note_hit)
	note_highway.note_missed.connect(_on_note_missed)
	note_highway.combo_changed.connect(_on_combo_changed)
	note_highway.score_changed.connect(_on_score_changed)
	note_highway.song_finished.connect(_on_song_finished)

	# Header HUD overlay
	var hud := VBoxContainer.new()
	hud.position = Vector2(30, 30)
	add_child(hud)

	var title := Label.new()
	title.text = "UPRIGHT PIANO - RHYTHM PROTOTYPE"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.82, 0.65))
	hud.add_child(title)

	score_label = Label.new()
	score_label.text = "Score: 0"
	score_label.add_theme_font_size_override("font_size", 18)
	score_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	hud.add_child(score_label)

	combo_label = Label.new()
	combo_label.text = "Combo: 0"
	combo_label.add_theme_font_size_override("font_size", 18)
	combo_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	hud.add_child(combo_label)

	status_label = Label.new()
	status_label.text = ""
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	hud.add_child(status_label)

	# Bottom Instructions HUD
	instructions_label = Label.new()
	instructions_label.text = "Lanes: [D]  [F]  [J]  [K]   |   Sustain Pedal: [SPACEBAR]"
	instructions_label.add_theme_font_size_override("font_size", 15)
	instructions_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75, 0.8))
	instructions_label.position = Vector2(30, 720 - 45)
	add_child(instructions_label)


## Generates a realistic dummy piano rhythm chart if the file does not already exist.
func _ensure_chart_exists() -> void:
	if FileAccess.file_exists(chart_path):
		return

	var dir := chart_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	print("MainGame: Generating prototype piano chart at '%s'..." % chart_path)

	# Pattern: an atmospheric piano etude across lanes 0-3 with varying durations and sustain notes
	var sample_notes: Array[NoteEvent] = []
	var t: float = 800.0 # Initial time in ms
	var beat_ms: float = 400.0 # 150 BPM

	# Sequence of (lane, pitch_name, duration_beats, is_sustain)
	var etude_pattern := [
		[0, "C4", 1.0, false],
		[1, "E4", 1.0, false],
		[2, "G4", 1.0, false],
		[3, "C5", 2.0, true], # Held sustain note

		[2, "G4", 1.0, false],
		[1, "E4", 1.0, false],
		[0, "C4", 2.0, false],

		[0, "D4", 1.0, false],
		[1, "F#4", 1.0, false],
		[2, "A4", 1.0, false],
		[3, "D5", 2.0, true],

		[2, "A4", 1.0, false],
		[1, "F#4", 1.0, false],
		[0, "D4", 2.0, false],

		# Chord run
		[0, "C4", 1.0, false],
		[1, "G4", 1.0, false],
		[2, "E4", 1.0, false],
		[3, "C5", 1.0, false],

		[0, "E4", 2.0, true],
		[1, "G4", 2.0, true],
		[2, "B4", 2.0, true],
		[3, "E5", 4.0, true]
	]

	for item in etude_pattern:
		var lane: int = item[0]
		var pitch: String = item[1]
		var dur_beats: float = item[2]
		var is_sus: bool = item[3]
		var dur_ms: float = dur_beats * beat_ms

		sample_notes.append(NoteEvent.new(t, lane, pitch, dur_ms, is_sus))
		t += beat_ms

	# Export using ChartExporter
	var exporter := ChartExporter.new()
	exporter.export_notes_to_chart(sample_notes, chart_path)
	print("MainGame: Successfully generated prototype chart with %d notes." % sample_notes.size())


## Loads the curated chart and starts playback on the highway.
func _load_and_play() -> void:
	var notes: Array[NoteEvent] = SongLoader.load_chart_file(chart_path)
	if notes.is_empty():
		push_error("MainGame: Failed to load chart from: %s" % chart_path)
		status_label.text = "ERROR: Failed to load chart!"
		status_label.add_theme_color_override("font_color", Color.RED)
		return

	status_label.text = "Loaded %d notes. Starting..." % notes.size()
	note_highway.start_chart(notes, 1500.0)


func _on_note_hit(_event: NoteEvent, _judgment: String, _diff_ms: float) -> void:
	pass


func _on_note_missed(_event: NoteEvent) -> void:
	pass


func _on_score_changed(new_score: int) -> void:
	if score_label:
		score_label.text = "Score: %d" % new_score


func _on_combo_changed(new_combo: int) -> void:
	if combo_label:
		combo_label.text = "Combo: %d" % new_combo


func _on_song_finished() -> void:
	if status_label:
		status_label.text = "Song Finished! Final Score: %d | Max Combo: %d" % [
			note_highway.score, note_highway.max_combo
		]
		status_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
