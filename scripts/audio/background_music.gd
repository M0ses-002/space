extends AudioStreamPlayer

@export var default_track: StringName = &"space"
@export var tracks: Dictionary[StringName, AudioStream] = {}

var current_track: StringName = &""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not default_track.is_empty():
		play_track(default_track)

func play_track(track_name: StringName) -> bool:
	if not tracks.has(track_name) or tracks[track_name] == null:
		push_warning("未配置背景音乐：%s" % track_name)
		return false
	if current_track == track_name and playing:
		return true
	stream = tracks[track_name]
	current_track = track_name
	play()
	return true

func stop_music() -> void:
	stop()
	current_track = &""
