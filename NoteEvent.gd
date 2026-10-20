class_name NoteEvent
extends Resource

@export var timestamp_ms: float = 0.0
@export_range(0, 4) var lane: int = 0
@export var pitch_name: String = ""
@export var duration_ms: float = 0.0
@export var is_sustain: bool = false

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
