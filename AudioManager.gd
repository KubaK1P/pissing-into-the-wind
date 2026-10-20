class_name AudioManager
extends Node

## AudioManager.gd
##
## Autoload / Audio Manager and Sample Management system for the upright piano rhythm/horror game.
## Manages a pre-allocated pool of AudioStreamPlayer nodes, acoustic piano samples recorded
## in minor thirds with pitch-scaling fallback, sustain pedal states, and mechanical atmospheric noises.

# --- Exported Configuration ---

## Size of the AudioStreamPlayer pool (pre-allocated at runtime, typically 24-32).
@export_range(16, 64) var pool_size: int = 32

## Audio bus for piano note voices.
@export var audio_bus: StringName = &"Master"

## Audio bus for mechanical atmospheric effects (pedal thuds, damper clatter).
@export var mechanical_bus: StringName = &"Master"

## Directory where acoustic piano samples (WAV/OGG) are stored.
@export_dir var samples_directory: String = "res://audio/piano_samples/"

## Directory where mechanical sound samples (pedal down/up, damper, keybed) are stored.
@export_dir var mechanical_directory: String = "res://audio/mechanical/"

## Maximum allowable semitone shift for fallback pitch scaling (+/- 12 semitones is 1 octave).
## With minor third sampling (every 3 semitones), normal shift never exceeds +/- 1 semitone.
@export_range(1, 24) var max_pitch_shift_semitones: int = 12

## Duration in seconds to fade out a non-sustained note when its key is released.
@export_range(0.01, 0.5) var damper_fade_time: float = 0.08

## Master volume offset for piano voices in decibels.
@export var piano_volume_db: float = 0.0

## Volume offset for mechanical atmospheric sounds in decibels.
@export var mechanical_volume_db: float = -6.0

## Master toggle for mechanical atmospheric sound effects.
@export var mechanical_effects_enabled: bool = true

# --- Mechanical Sound Collections ---
@export var pedal_down_samples: Array[AudioStream] = []
@export var pedal_up_samples: Array[AudioStream] = []
@export var damper_release_samples: Array[AudioStream] = []
@export var key_click_samples: Array[AudioStream] = []

# --- Internal State ---

# Dictionary mapping MIDI pitch (int) -> AudioStream
var _sample_library: Dictionary = {}
# Sorted Array[int] of loaded MIDI pitches for binary/nearest search
var _loaded_pitches: Array[int] = []

# AudioStreamPlayer voice pool entries:
# Array of Dictionary {
#   "player": AudioStreamPlayer,
#   "voice_id": int,
#   "pitch": int,
#   "is_sustain": bool,
#   "start_ticks": int,
#   "active_tween": Tween
# }
var _voice_pool: Array[Dictionary] = []
var _voice_id_counter: int = 0

# Dedicated mechanical players so atmospheric noises never steal piano voice players
var _pedal_player: AudioStreamPlayer
var _damper_player: AudioStreamPlayer
var _key_player: AudioStreamPlayer

# Global sustain pedal state
var _is_pedal_depressed: bool = false


func _enter_tree() -> void:
	_ensure_initialized()


func _ready() -> void:
	_ensure_initialized()


## Ensures voice pool and sample library are ready even if used before _ready().
func _ensure_initialized() -> void:
	if _voice_pool.is_empty():
		_init_voice_pool()
		_init_mechanical_players()
		load_samples()


# ==============================================================================
# 1. AUDIO STREAM PLAYER POOLING (LRU & Pre-allocation)
# ==============================================================================

## Pre-allocates player pool as children of this node to prevent runtime hitching.
func _init_voice_pool() -> void:
	_voice_pool.clear()
	for i in range(pool_size):
		var player := AudioStreamPlayer.new()
		player.name = "PianoVoice_%02d" % i
		player.bus = audio_bus
		add_child(player)

		_voice_pool.append({
			"player": player,
			"voice_id": 0,
			"pitch": -1,
			"is_sustain": false,
			"start_ticks": 0,
			"active_tween": null
		})


## Dedicated players for mechanical noise triggers.
func _init_mechanical_players() -> void:
	_pedal_player = AudioStreamPlayer.new()
	_pedal_player.name = "Mechanical_Pedal"
	_pedal_player.bus = mechanical_bus
	add_child(_pedal_player)

	_damper_player = AudioStreamPlayer.new()
	_damper_player.name = "Mechanical_Damper"
	_damper_player.bus = mechanical_bus
	add_child(_damper_player)

	_key_player = AudioStreamPlayer.new()
	_key_player.name = "Mechanical_Key"
	_key_player.bus = mechanical_bus
	add_child(_key_player)


## Finds an idle player or steals the least-recently-used (oldest) voice.
func _acquire_voice() -> Dictionary:
	# 1. Search for an idle player
	for voice in _voice_pool:
		var player: AudioStreamPlayer = voice["player"]
		if not player.playing:
			_clean_voice_tween(voice)
			return voice

	# 2. All players are busy: apply LRU voice-stealing (oldest start_ticks)
	var oldest_voice: Dictionary = _voice_pool[0]
	var oldest_time: int = oldest_voice["start_ticks"]

	for i in range(1, _voice_pool.size()):
		var v: Dictionary = _voice_pool[i]
		if v["start_ticks"] < oldest_time:
			oldest_time = v["start_ticks"]
			oldest_voice = v

	# Gracefully terminate the stolen voice
	_clean_voice_tween(oldest_voice)
	var stolen_player: AudioStreamPlayer = oldest_voice["player"]
	stolen_player.stop()

	return oldest_voice


func _clean_voice_tween(voice: Dictionary) -> void:
	if voice["active_tween"] != null and is_instance_valid(voice["active_tween"]):
		var tw: Tween = voice["active_tween"]
		tw.kill()
	voice["active_tween"] = null


# ==============================================================================
# 2. MINOR-THIRD SAMPLE MAPPING & PITCH-SCALING FALLBACK
# ==============================================================================

## Scans the samples directory or populates procedural fallback tones.
func load_samples() -> void:
	_sample_library.clear()
	_loaded_pitches.clear()

	var loaded_count: int = _scan_and_load_sample_directory(samples_directory)
	_scan_mechanical_directory(mechanical_directory)

	if loaded_count == 0:
		push_warning("AudioManager: No acoustic piano samples found in '%s'. Initializing procedural fallback tones for minor-third intervals." % samples_directory)
		_init_procedural_placeholders()

	_rebuild_pitch_index()


## Scans a directory for audio sample files and maps them to pitches.
func _scan_and_load_sample_directory(dir_path: String) -> int:
	if not DirAccess.dir_exists_absolute(dir_path):
		return 0

	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0

	var count: int = 0
	dir.list_dir_begin()
	var file_name := dir.get_next()

	while not file_name.is_empty():
		if not dir.current_is_dir():
			var ext := file_name.get_extension().to_lower()
			if ext in ["wav", "ogg", "mp3"]:
				var base := file_name.get_basename()
				var pitch := _extract_pitch_from_filename(base)
				if pitch >= 0:
					var full_path := dir_path.path_join(file_name)
					var stream: AudioStream = load(full_path)
					if stream != null:
						register_sample(pitch, stream)
						count += 1
		file_name = dir.get_next()

	dir.list_dir_end()
	return count


## Attempts to parse a pitch number or pitch name from a filename (e.g., "C4", "Eb3", "piano_60", "F#5").
func _extract_pitch_from_filename(base: String) -> int:
	# Check if base is directly a MIDI pitch number (e.g., "60")
	if base.is_valid_int():
		var num := base.to_int()
		if num >= 0 and num <= 127:
			return num

	# Check standard pitch names
	var direct_pitch := NoteEvent.pitch_name_to_midi(base)
	if direct_pitch >= 0:
		return direct_pitch

	# Check regex pattern for tokens like "C4", "Eb3", "F#5" embedded in the filename
	var regex := RegEx.new()
	regex.compile("(?i)([A-G][#B]?-?[0-9])")
	var result := regex.search(base)
	if result != null:
		var match_str := result.get_string()
		return NoteEvent.pitch_name_to_midi(match_str)

	return -1


## Registers an AudioStream sample for a given MIDI pitch or pitch name.
func register_sample(pitch_id: Variant, stream: AudioStream) -> void:
	var pitch: int = -1
	if pitch_id is int:
		pitch = pitch_id
	elif pitch_id is String:
		pitch = NoteEvent.pitch_name_to_midi(pitch_id)

	if pitch < 0 or pitch > 127:
		push_warning("AudioManager: Invalid pitch identifier: %s" % str(pitch_id))
		return

	_sample_library[pitch] = stream
	_rebuild_pitch_index()


func _rebuild_pitch_index() -> void:
	_loaded_pitches.clear()
	for p in _sample_library.keys():
		_loaded_pitches.append(int(p))
	_loaded_pitches.sort()


## Resolves the closest reference sample and calculates the pitch_scale using semitone differences.
## Formula: pitch_scale = pow(2.0, (target_pitch - reference_pitch) / 12.0)
func _get_stream_for_pitch(target_pitch: int) -> Dictionary:
	if _sample_library.is_empty():
		return { "stream": null, "pitch_scale": 1.0, "ref_pitch": target_pitch }

	# 1. Exact match
	if _sample_library.has(target_pitch):
		return {
			"stream": _sample_library[target_pitch],
			"pitch_scale": 1.0,
			"ref_pitch": target_pitch
		}

	# 2. Find closest reference sample from available minor-third recordings
	var closest_pitch: int = _loaded_pitches[0]
	var min_distance: int = abs(target_pitch - closest_pitch)

	for i in range(1, _loaded_pitches.size()):
		var p: int = _loaded_pitches[i]
		var dist: int = abs(target_pitch - p)
		if dist < min_distance:
			min_distance = dist
			closest_pitch = p

	var semitone_diff: int = target_pitch - closest_pitch

	# Apply safety bounds to extreme shifts
	semitone_diff = clampi(semitone_diff, -max_pitch_shift_semitones, max_pitch_shift_semitones)

	# Calculate mathematical pitch scale factor
	var calculated_pitch_scale: float = pow(2.0, float(semitone_diff) / 12.0)

	# Additional safety clamp on pitch scale (0.25 = down 2 octaves, 4.0 = up 2 octaves)
	calculated_pitch_scale = clampf(calculated_pitch_scale, 0.25, 4.0)

	return {
		"stream": _sample_library[closest_pitch],
		"pitch_scale": calculated_pitch_scale,
		"ref_pitch": closest_pitch
	}


# ==============================================================================
# 3. PLAYBACK & SUSTAIN INTEGRATION
# ==============================================================================

## Primary rhythm game entry point: plays a note directly from a NoteEvent resource.
func play_note_event(event: NoteEvent) -> AudioStreamPlayer:
	if event == null:
		return null
	return play_pitch(event.pitch_name, event.is_sustain, event.duration_ms)


## Plays a note by scientific pitch name (e.g. "C4", "F#3") with sustain awareness.
func play_pitch(pitch_name: String, is_sustain: bool = false, duration_ms: float = 0.0) -> AudioStreamPlayer:
	var pitch_num := NoteEvent.pitch_name_to_midi(pitch_name)
	if pitch_num < 0:
		push_warning("AudioManager: Cannot play unknown pitch name: '%s'" % pitch_name)
		return null
	return play_midi_pitch(pitch_num, is_sustain, duration_ms)


## Plays a note by MIDI pitch number (0-127).
func play_midi_pitch(pitch_num: int, is_sustain: bool = false, duration_ms: float = 0.0) -> AudioStreamPlayer:
	var sample_info := _get_stream_for_pitch(pitch_num)
	if sample_info["stream"] == null:
		push_warning("AudioManager: No sample available to play pitch %d" % pitch_num)
		return null

	var voice := _acquire_voice()
	var player: AudioStreamPlayer = voice["player"]

	_voice_id_counter += 1
	var current_voice_id: int = _voice_id_counter

	# Configure player
	player.stream = sample_info["stream"]
	player.pitch_scale = sample_info["pitch_scale"]
	player.volume_db = piano_volume_db
	player.play()

	# Update voice record
	voice["voice_id"] = current_voice_id
	voice["pitch"] = pitch_num
	voice["is_sustain"] = is_sustain or _is_pedal_depressed
	voice["start_ticks"] = Time.get_ticks_msec()

	# Sustain handling:
	# If sustain is active (either on note or via physical pedal), let the note ring out fully.
	# If sustain is false and duration_ms > 0, schedule natural damper release at key release.
	if not voice["is_sustain"] and duration_ms > 0.0:
		_schedule_damper_release(voice, current_voice_id, duration_ms / 1000.0)

	return player


## Schedules dampening of the string when a non-sustained key is released.
func _schedule_damper_release(voice: Dictionary, expected_voice_id: int, hold_seconds: float) -> void:
	var timer := get_tree().create_timer(hold_seconds)
	timer.timeout.connect(func() -> void:
		# Check if the voice is still playing the exact same note trigger and sustain wasn't pressed
		if voice["voice_id"] == expected_voice_id and not _is_pedal_depressed:
			_dampen_voice(voice)
	)


## Applies gentle string damping and triggers the atmospheric damper clack.
func _dampen_voice(voice: Dictionary) -> void:
	var player: AudioStreamPlayer = voice["player"]
	if not player.playing:
		return

	_clean_voice_tween(voice)

	var tween := create_tween()
	voice["active_tween"] = tween
	tween.tween_property(player, "volume_db", -80.0, damper_fade_time)
	tween.tween_callback(func() -> void:
		player.stop()
		player.volume_db = piano_volume_db
	)

	# Trigger subtle physical damper sound
	play_damper_release()


## Dampens all currently sounding notes of a specific pitch.
func stop_pitch(pitch_name: String) -> void:
	var pitch_num := NoteEvent.pitch_name_to_midi(pitch_name)
	if pitch_num < 0:
		return

	for voice in _voice_pool:
		var player: AudioStreamPlayer = voice["player"]
		if player.playing and voice["pitch"] == pitch_num:
			if not _is_pedal_depressed:
				_dampen_voice(voice)


## Stops all currently playing voices.
func stop_all_voices(fade_time: float = 0.05) -> void:
	for voice in _voice_pool:
		var player: AudioStreamPlayer = voice["player"]
		if player.playing:
			_clean_voice_tween(voice)
			if fade_time <= 0.0:
				player.stop()
			else:
				var tween := create_tween()
				voice["active_tween"] = tween
				tween.tween_property(player, "volume_db", -80.0, fade_time)
				tween.tween_callback(func() -> void:
					player.stop()
					player.volume_db = piano_volume_db
				)


# ==============================================================================
# 4. MECHANICAL & PEDAL SAMPLE HOOKS
# ==============================================================================

## Sets the global sustain pedal state, triggering mechanical sounds and voice damping.
func set_sustain_pedal(depressed: bool) -> void:
	if _is_pedal_depressed == depressed:
		return

	_is_pedal_depressed = depressed

	if _is_pedal_depressed:
		play_pedal_down()
		# Mark all currently sounding notes as sustained so they ring out
		for voice in _voice_pool:
			if voice["player"].playing:
				voice["is_sustain"] = true
	else:
		play_pedal_up()
		# Release pedal: dampen any voices that aren't individually marked sustain
		for voice in _voice_pool:
			if voice["player"].playing and not voice["is_sustain"]:
				_dampen_voice(voice)


## Plays the mechanical pedal down thud / acoustic soundboard resonance.
func play_pedal_down(volume_scale: float = 1.0) -> void:
	_play_mechanical_stream(_pedal_player, pedal_down_samples, volume_scale)


## Plays the mechanical pedal up clunk / damper assembly return sound.
func play_pedal_up(volume_scale: float = 1.0) -> void:
	_play_mechanical_stream(_pedal_player, pedal_up_samples, volume_scale)


## Plays the subtle felt damper falling back onto piano strings.
func play_damper_release(volume_scale: float = 1.0) -> void:
	_play_mechanical_stream(_damper_player, damper_release_samples, volume_scale * 0.7)


## Plays subtle wooden keybed click when striking or releasing keys.
func play_key_click(volume_scale: float = 1.0) -> void:
	_play_mechanical_stream(_key_player, key_click_samples, volume_scale * 0.5)


func _play_mechanical_stream(player: AudioStreamPlayer, variations: Array[AudioStream], volume_scale: float) -> void:
	if not mechanical_effects_enabled or variations.is_empty():
		return

	var stream: AudioStream = variations[randi() % variations.size()]
	if stream == null:
		return

	player.stream = stream
	player.volume_db = mechanical_volume_db + linear_to_db(maxf(0.01, volume_scale))
	# Subtle random pitch variation for acoustic realism
	player.pitch_scale = randf_range(0.96, 1.04)
	player.play()


func _scan_mechanical_directory(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return

	var dir := DirAccess.open(dir_path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()

	while not file_name.is_empty():
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			var full_path := dir_path.path_join(file_name)
			var stream: AudioStream = load(full_path)

			if stream != null:
				if "pedal_down" in lower:
					pedal_down_samples.append(stream)
				elif "pedal_up" in lower:
					pedal_up_samples.append(stream)
				elif "damper" in lower:
					damper_release_samples.append(stream)
				elif "key" in lower or "clack" in lower:
					key_click_samples.append(stream)

		file_name = dir.get_next()
	dir.list_dir_end()


# ==============================================================================
# 5. PROCEDURAL ACOUSTIC PLACEHOLDERS (Fallback)
# ==============================================================================

## Synthesizes warm, decaying acoustic harmonic piano tone placeholders across minor-third intervals.
## Used when sample files are not yet loaded onto disk.
func _init_procedural_placeholders() -> void:
	# Standard 88-key piano minor third intervals from A0 (21) to C8 (108)
	var minor_third_pitches := [
		21, 24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54, 57, 60,
		63, 66, 69, 72, 75, 78, 81, 84, 87, 90, 93, 96, 99, 102, 105, 108
	]

	for pitch in minor_third_pitches:
		var stream := _generate_piano_tone(pitch)
		register_sample(pitch, stream)

	# Generate procedural mechanical placeholder noises if arrays are empty
	if pedal_down_samples.is_empty():
		pedal_down_samples.append(_generate_thud_noise(60.0, 0.25))
	if pedal_up_samples.is_empty():
		pedal_up_samples.append(_generate_thud_noise(120.0, 0.15))
	if damper_release_samples.is_empty():
		damper_release_samples.append(_generate_thud_noise(250.0, 0.08))
	if key_click_samples.is_empty():
		key_click_samples.append(_generate_thud_noise(400.0, 0.04))


## Procedurally generates a warm acoustic piano-like harmonic tone with natural decay.
func _generate_piano_tone(pitch: int) -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 2.0
	var total_samples: int = int(sample_rate * duration)

	var freq: float = 440.0 * pow(2.0, float(pitch - 69) / 12.0)
	var buffer := PackedByteArray()
	buffer.resize(total_samples * 2)

	for i in range(total_samples):
		var t: float = float(i) / float(sample_rate)
		# Piano harmonic envelope: faster decay for higher harmonics
		var env1: float = exp(-2.0 * t)
		var env2: float = exp(-3.5 * t)
		var env3: float = exp(-5.0 * t)

		# Fundamental + 2nd harmonic + 3rd harmonic
		var s: float = (
			sin(TAU * freq * t) * env1 * 0.6 +
			sin(TAU * freq * 2.0 * t) * env2 * 0.25 +
			sin(TAU * freq * 3.0 * t) * env3 * 0.15
		)
		var s_clamped: float = clampf(s, -1.0, 1.0)
		var val_s16: int = int(s_clamped * 32000.0)
		buffer.encode_s16(i * 2, val_s16)

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = buffer
	return wav


## Generates subtle procedural wooden/thud impulses for mechanical effects.
func _generate_thud_noise(center_freq: float, duration: float) -> AudioStreamWAV:
	var sample_rate: int = 22050
	var total_samples: int = int(sample_rate * duration)

	var buffer := PackedByteArray()
	buffer.resize(total_samples * 2)

	for i in range(total_samples):
		var t: float = float(i) / float(sample_rate)
		var env: float = exp(-18.0 * t)
		var s: float = sin(TAU * center_freq * t) * env * 0.4
		var val_s16: int = int(clampf(s, -1.0, 1.0) * 32000.0)
		buffer.encode_s16(i * 2, val_s16)

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = buffer
	return wav
