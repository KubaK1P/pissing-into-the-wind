class_name NoteHighway
extends Control

## NoteHighway.gd
##
## Core Note Highway & Input Evaluator for the upright piano rhythm/horror game.
## Manages 4 vertical lanes (D, F, J, K), scrolling NoteEvent visuals, song clock synchronization,
## timing window evaluation (Perfect / Good / Miss), score tracking, and sustain pedal input (Spacebar).

signal note_hit(event: NoteEvent, judgment: String, timing_diff_ms: float)
signal note_missed(event: NoteEvent)
signal combo_changed(new_combo: int)
signal score_changed(new_score: int)
signal song_finished()

# --- Configuration Properties ---

## Total lanes on the highway (fixed to 4 for D, F, J, K).
const LANE_COUNT: int = 4

## Milliseconds for a note to travel from spawn (top) to hit line (bottom).
@export var approach_time_ms: float = 1500.0

## Vertical distance ratio from top where the hit line is positioned (0.0 to 1.0).
@export_range(0.5, 0.95) var hit_line_ratio: float = 0.85

## Hit timing windows in milliseconds.
@export var perfect_window_ms: float = 45.0
@export var good_window_ms: float = 110.0
@export var miss_window_ms: float = 160.0

## Default keyboard mapping for lanes 0 through 3.
@export var lane_keys: Array[Key] = [KEY_D, KEY_F, KEY_J, KEY_K]

## Key used for sustain pedal depress / release.
@export var sustain_key: Key = KEY_SPACE

# --- Aesthetic & Visual Colors ---
@export var highway_bg_color: Color = Color(0.06, 0.06, 0.08, 0.92)
@export var lane_border_color: Color = Color(0.22, 0.22, 0.26, 0.7)
@export var hit_line_color: Color = Color(0.95, 0.82, 0.55, 0.95)
@export var lane_active_glow_color: Color = Color(0.95, 0.82, 0.55, 0.25)

# Note colors per lane (ivory for outer lanes, brass/mahogany for inner lanes)
@export var note_colors: Array[Color] = [
	Color(0.92, 0.92, 0.88), # Lane 0 (D): Ivory
	Color(0.85, 0.65, 0.40), # Lane 1 (F): Warm Brass
	Color(0.85, 0.65, 0.40), # Lane 2 (J): Warm Brass
	Color(0.92, 0.92, 0.88), # Lane 3 (K): Ivory
]
@export var sustain_tail_alpha: float = 0.45

# --- Gameplay State ---
var song_time_ms: float = 0.0
var is_playing: bool = false
var score: int = 0
var combo: int = 0
var max_combo: int = 0
var perfect_count: int = 0
var good_count: int = 0
var miss_count: int = 0

# Chart note storage
var _all_notes: Array[NoteEvent] = []
var _spawn_index: int = 0
var _active_notes: Array[Dictionary] = []

# Lane visual press states
var _lane_pressed: Array[bool] = [false, false, false, false]

# Receptors hit flash animation: Array of float (decaying from 1.0 to 0.0)
var _receptor_flash: Array[float] = [0.0, 0.0, 0.0, 0.0]

# Judgment popup text display
var _current_judgment_text: String = ""
var _judgment_color: Color = Color.WHITE
var _judgment_timer: float = 0.0

# Sustain pedal state
var _is_sustain_down: bool = false

# Hold-note tracking per lane (references to currently held active note dictionary)
var _lane_held_notes: Array = [null, null, null, null]


func _ready() -> void:
	# Enable input processing
	set_process_unhandled_input(true)
	custom_minimum_size = Vector2(400, 500)


## Starts playing the given array of NoteEvents.
## start_delay_ms gives a brief countdown lead-in so early notes scroll in smoothly.
func start_chart(notes: Array[NoteEvent], start_delay_ms: float = 1200.0) -> void:
	_all_notes = notes.duplicate()
	_all_notes.sort_custom(func(a: NoteEvent, b: NoteEvent) -> bool:
		return a.timestamp_ms < b.timestamp_ms
	)

	_spawn_index = 0
	_active_notes.clear()
	_lane_held_notes = [null, null, null, null]
	song_time_ms = -start_delay_ms
	score = 0
	combo = 0
	max_combo = 0
	perfect_count = 0
	good_count = 0
	miss_count = 0
	_current_judgment_text = ""
	is_playing = true
	queue_redraw()


## Stops and resets the highway.
func stop_chart() -> void:
	is_playing = false
	_active_notes.clear()
	_lane_held_notes = [null, null, null, null]
	_spawn_index = 0
	AudioManager.set_sustain_pedal(false)
	queue_redraw()


func _process(delta: float) -> void:
	if not is_playing:
		return

	# Advance song clock
	song_time_ms += delta * 1000.0

	# Decay visual receptor flashes and judgment timer
	for i in range(LANE_COUNT):
		if _receptor_flash[i] > 0.0:
			_receptor_flash[i] = maxf(0.0, _receptor_flash[i] - delta * 4.0)

	if _judgment_timer > 0.0:
		_judgment_timer = maxf(0.0, _judgment_timer - delta)

	# 1. Spawn upcoming notes within approach window
	var spawn_threshold: float = song_time_ms + approach_time_ms
	while _spawn_index < _all_notes.size():
		var note_event: NoteEvent = _all_notes[_spawn_index]
		if note_event.timestamp_ms <= spawn_threshold:
			# Map to 4 lanes (modulo or clamp)
			var lane_idx: int = clampi(posmod(note_event.lane, LANE_COUNT), 0, LANE_COUNT - 1)
			_active_notes.append({
				"event": note_event,
				"lane": lane_idx,
				"timestamp_ms": note_event.timestamp_ms,
				"duration_ms": note_event.duration_ms,
				"is_sustain": note_event.is_sustain,
				"pitch_name": note_event.pitch_name,
				"is_hit": false,
				"is_missed": false
			})
			_spawn_index += 1
		else:
			break

	# 2. Check for Missed Notes (unhit notes that traveled past the hit window)
	var i: int = _active_notes.size() - 1
	while i >= 0:
		var n: Dictionary = _active_notes[i]
		if not n["is_hit"] and not n["is_missed"]:
			var passed_time: float = song_time_ms - n["timestamp_ms"]
			if passed_time > miss_window_ms:
				# Registered a miss!
				n["is_missed"] = true
				_on_note_missed(n["event"])

		# If note was being held and duration has completed:
		if n.get("is_holding", false):
			var note_end: float = n["timestamp_ms"] + n["duration_ms"]
			if song_time_ms >= note_end:
				n["is_holding"] = false
				if _lane_held_notes[n["lane"]] == n:
					_lane_held_notes[n["lane"]] = null

		# Cleanup expired notes (already hit/missed and completely scrolled off screen)
		var note_tail_ms: float = n["timestamp_ms"] + n["duration_ms"]
		if (n["is_hit"] or n["is_missed"]) and (song_time_ms - note_tail_ms > 400.0):
			if _lane_held_notes[n["lane"]] == n:
				_lane_held_notes[n["lane"]] = null
			_active_notes.remove_at(i)
		i -= 1

	# 3. Check for Song Finish
	if _spawn_index >= _all_notes.size() and _active_notes.is_empty():
		is_playing = false
		song_finished.emit()

	queue_redraw()


# ==============================================================================
# INPUT HANDLING & TIMING EVALUATOR
# ==============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return

	var key_event := event as InputEventKey
	if key_event.echo:
		return

	# Sustain Pedal (Spacebar)
	if key_event.keycode == sustain_key:
		_is_sustain_down = key_event.pressed
		AudioManager.set_sustain_pedal(_is_sustain_down)
		queue_redraw()
		return

	# Lane Inputs (D, F, J, K)
	for lane in range(LANE_COUNT):
		if key_event.keycode == lane_keys[lane]:
			_lane_pressed[lane] = key_event.pressed
			if key_event.pressed:
				_evaluate_lane_input(lane)
				_receptor_flash[lane] = 1.0
			else:
				_on_lane_key_released(lane)
			queue_redraw()
			return


## Evaluates key press timing against active notes in the pressed lane.
func _evaluate_lane_input(lane: int) -> void:
	if not is_playing:
		return

	# Search for the closest unhit note in this lane within the miss window
	var closest_idx: int = -1
	var min_diff_ms: float = INF

	for i in range(_active_notes.size()):
		var n: Dictionary = _active_notes[i]
		if n["lane"] == lane and not n["is_hit"] and not n["is_missed"]:
			var diff: float = absf(n["timestamp_ms"] - song_time_ms)
			if diff <= miss_window_ms and diff < min_diff_ms:
				min_diff_ms = diff
				closest_idx = i

	# If a note is within hit range, evaluate timing
	if closest_idx >= 0:
		var target_note: Dictionary = _active_notes[closest_idx]
		target_note["is_hit"] = true
		target_note["is_holding"] = true
		target_note["released_early"] = false
		_lane_held_notes[lane] = target_note

		var judgment := ""
		if min_diff_ms <= perfect_window_ms:
			judgment = "PERFECT"
			score += 300
			combo += 1
			perfect_count += 1
			_set_judgment("PERFECT", Color(1.0, 0.85, 0.35))
		elif min_diff_ms <= good_window_ms:
			judgment = "GOOD"
			score += 150
			combo += 1
			good_count += 1
			_set_judgment("GOOD", Color(0.35, 0.90, 0.55))
		else:
			judgment = "MISS"
			combo = 0
			miss_count += 1
			_set_judgment("MISS", Color(0.92, 0.25, 0.25))

		max_combo = maxi(max_combo, combo)
		combo_changed.emit(combo)
		score_changed.emit(score)

		# Trigger audio playback via AudioManager
		AudioManager.play_note_event(target_note["event"])
		note_hit.emit(target_note["event"], judgment, min_diff_ms)
	else:
		# Ghost tap: play subtle wooden keybed click
		AudioManager.play_key_click(0.7)


## Handles key release on a specific lane, detecting early release on hold notes and triggering damper.
func _on_lane_key_released(lane: int) -> void:
	var held_note: Dictionary = _lane_held_notes[lane] if _lane_held_notes[lane] != null else {}
	if not held_note.is_empty():
		var note_start: float = held_note.get("timestamp_ms", 0.0)
		var note_dur: float = held_note.get("duration_ms", 0.0)
		# Check if key was released early before note's duration expired
		if note_dur > 0.0 and song_time_ms < (note_start + note_dur):
			held_note["released_early"] = true
		held_note["is_holding"] = false
		_lane_held_notes[lane] = null

	# Trigger key release damper dampening immediately via AudioManager
	AudioManager.release_lane(lane)


func _on_note_missed(event: NoteEvent) -> void:
	combo = 0
	miss_count += 1
	_set_judgment("MISS", Color(0.92, 0.25, 0.25))
	combo_changed.emit(combo)
	note_missed.emit(event)


func _set_judgment(text: String, col: Color) -> void:
	_current_judgment_text = text
	_judgment_color = col
	_judgment_timer = 0.65


# ==============================================================================
# DRAWING & VISUAL RENDERING
# ==============================================================================

func _draw() -> void:
	var total_w: float = size.x
	var total_h: float = size.y
	if total_w <= 0.0 or total_h <= 0.0:
		return

	var lane_w: float = total_w / float(LANE_COUNT)
	var spawn_y: float = 0.0
	var hit_y: float = total_h * hit_line_ratio
	var travel_dist: float = hit_y - spawn_y

	# 1. Background Highway Canvas
	draw_rect(Rect2(0, 0, total_w, total_h), highway_bg_color)

	# 2. Lane Dividers and Active Key Glows
	for lane in range(LANE_COUNT):
		var lx: float = lane * lane_w

		# Lane active glow beam when key is held down
		if _lane_pressed[lane] or _receptor_flash[lane] > 0.0:
			var alpha_boost: float = 0.25 if _lane_pressed[lane] else _receptor_flash[lane] * 0.25
			var glow_col := Color(lane_active_glow_color.r, lane_active_glow_color.g, lane_active_glow_color.b, alpha_boost)
			draw_rect(Rect2(lx, spawn_y, lane_w, hit_y), glow_col)

		# Divider line
		if lane > 0:
			draw_line(Vector2(lx, 0), Vector2(lx, total_h), lane_border_color, 1.5)

	# Outer border lines
	draw_line(Vector2(0, 0), Vector2(0, total_h), lane_border_color, 2.0)
	draw_line(Vector2(total_w, 0), Vector2(total_w, total_h), lane_border_color, 2.0)

	# 3. Hit Line & Lane Receptors
	draw_line(Vector2(0, hit_y), Vector2(total_w, hit_y), hit_line_color, 3.5)

	# Draw key label targets at the bottom of each lane
	var default_font: Font = ThemeDB.fallback_font
	var font_size: int = 16
	var key_names := ["D", "F", "J", "K"]

	for lane in range(LANE_COUNT):
		var lx: float = lane * lane_w
		var receptor_rect := Rect2(lx + 6, hit_y - 6, lane_w - 12, 12)
		var rec_color := hit_line_color
		if _lane_pressed[lane]:
			rec_color = Color.WHITE
		draw_rect(receptor_rect, rec_color, false, 2.0)

		# Key text hint
		var key_str: String = key_names[lane]
		var text_pos := Vector2(lx + lane_w * 0.5 - 6.0, hit_y + 32.0)
		draw_string(default_font, text_pos, key_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(0.8, 0.8, 0.85, 0.7))

	# 4. Sustain Pedal Indicator
	var pedal_text := "SUSTAIN: [SPACE]" if not _is_sustain_down else "SUSTAIN: DOWN"
	var pedal_col := Color(0.95, 0.82, 0.55) if _is_sustain_down else Color(0.5, 0.5, 0.55)
	draw_string(default_font, Vector2(total_w * 0.5 - 60.0, total_h - 14.0), pedal_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 13, pedal_col)

	# 5. Draw Active Scrolling Notes
	for n in _active_notes:
		# Time remaining until hit line (in ms)
		var dt_ms: float = n["timestamp_ms"] - song_time_ms
		var note_y: float = hit_y - (dt_ms / approach_time_ms) * travel_dist
		var lane_idx: int = n["lane"]
		var lx: float = lane_idx * lane_w + 6.0
		var nw: float = lane_w - 12.0
		var nh: float = 20.0
		var base_col: Color = note_colors[lane_idx]

		# Dim note if missed or hit
		if n["is_missed"]:
			base_col = Color(0.4, 0.4, 0.4, 0.3)
		elif n["is_hit"]:
			base_col = Color(base_col.r, base_col.g, base_col.b, 0.25)

		# Draw Sustain Tail if note has duration
		var dur_ms: float = n["duration_ms"]
		if dur_ms > 0.0 or n["is_sustain"]:
			var tail_length_px: float = (dur_ms / approach_time_ms) * travel_dist
			tail_length_px = maxf(tail_length_px, 15.0)
			var tail_w: float = nw * 0.5
			var tail_x: float = lx + (nw - tail_w) * 0.5
			var tail_y: float = note_y - tail_length_px

			var tail_alpha: float = sustain_tail_alpha
			if n["is_missed"] or n.get("released_early", false):
				tail_alpha = 0.15 # Dimmed when missed or released early
			elif n.get("is_holding", false):
				tail_alpha = 0.85 # Bright glow while actively being held!

			var tail_col := Color(base_col.r, base_col.g, base_col.b, tail_alpha)
			draw_rect(Rect2(tail_x, tail_y, tail_w, tail_length_px), tail_col)
			# Sustain outline
			var outline_alpha: float = minf(1.0, tail_alpha * 1.4)
			draw_rect(Rect2(tail_x, tail_y, tail_w, tail_length_px), Color(base_col.r, base_col.g, base_col.b, outline_alpha), false, 1.2)

		# Draw Note Head Block
		var head_rect := Rect2(lx, note_y - nh * 0.5, nw, nh)
		# Filled note block
		draw_rect(head_rect, base_col)
		# Note border
		draw_rect(head_rect, Color(0.1, 0.1, 0.12, 0.9), false, 1.5)

		# Note pitch name label (e.g., "C4")
		var p_str: String = n["pitch_name"]
		if not p_str.is_empty() and not n["is_missed"]:
			var p_pos := Vector2(lx + nw * 0.5 - 10.0, note_y + 5.0)
			draw_string(default_font, p_pos, p_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 11, Color(0.12, 0.12, 0.15, 0.9))

	# 6. Floating Judgment Feedback
	if _judgment_timer > 0.0 and not _current_judgment_text.is_empty():
		var alpha: float = clampf(_judgment_timer / 0.65, 0.0, 1.0)
		var text_col := Color(_judgment_color.r, _judgment_color.g, _judgment_color.b, alpha)
		var text_pos := Vector2(total_w * 0.5 - 45.0, hit_y - 60.0 - (1.0 - alpha) * 20.0)
		draw_string(default_font, text_pos, _current_judgment_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 28, text_col)

	# 7. Combo counter
	if combo > 1:
		var combo_str: String = "%d COMBO" % combo
		var combo_pos := Vector2(total_w * 0.5 - 35.0, hit_y - 100.0)
		draw_string(default_font, combo_pos, combo_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 18, Color(0.95, 0.95, 0.9, 0.85))
