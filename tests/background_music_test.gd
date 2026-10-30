extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	var music = root.get_node_or_null("BackgroundMusic")
	check(music != null, "背景音乐自动加载")
	if music == null:
		quit(1)
		return
	await process_frame
	check(music.current_track == &"space" and music.playing, "启动时播放默认音乐")
	check(music.stream is AudioStreamWAV and music.stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, "音乐使用 WAV 正向循环")
	check(music.stream.loop_begin == 769746 and music.stream.loop_end == 3078983, "循环点精确覆盖循环体，不重复开头")
	check(music.stream.mix_rate == 44100 and music.stream.stereo, "音乐保留原始采样率和声道")
	check(music.stream.get_length() > 0.0, "音乐包含可播放的音频")
	check(music.play_track(&"space") and music.playing, "重复选择当前曲目不会停止")
	var previous_stream: AudioStream = music.stream
	check(not music.play_track(&"missing"), "未配置的曲目返回失败")
	check(music.stream == previous_stream and music.playing, "未配置曲目不打断播放")
	var alternate := AudioStreamWAV.new()
	alternate.mix_rate = 8000
	alternate.data = PackedByteArray([128, 128, 128, 128])
	alternate.loop_mode = AudioStreamWAV.LOOP_FORWARD
	alternate.loop_end = 4
	music.tracks[&"alternate"] = alternate
	check(music.play_track(&"alternate") and music.stream == alternate, "可切换到其他界面曲目")
	music.stop_music()
	check(not music.playing and music.current_track.is_empty(), "停止音乐并清除当前曲目")
	check(music.play_track(&"space") and music.playing, "停止后可恢复播放")
	paused = true
	check(music.can_process(), "暂停时音乐节点仍可运行")
	paused = false
	music.stop_music()
	music.queue_free()
	await create_timer(0.3).timeout
	quit(1 if failures else 0)
