extends SceneTree
## 对话窗口「单击跳过读条」回归：读条期间单击立即结束当前进度条，
## 带确认的进入等待确认（出现「确认继续」），不带确认的直接完成进入下一条；
## 刚弹出（minimum_read_seconds 内）单击不跳过，防误触。
var failures: int = 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func click(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = point
	press.pressed = true
	root.push_input(press, true)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = point
	release.pressed = false
	root.push_input(release, true)

## 等待对话窗口进入指定阶段（用真实时间轮询，避免 headless 帧率与墙钟脱节）。
func wait_phase(dialogue: Node, wanted: int, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while dialogue.phase != wanted and Time.get_ticks_msec() < deadline:
		await process_frame
	return dialogue.phase == wanted

func _run() -> void:
	check(ProjectSettings.globalize_path("user://").contains("space-dialogue-skip"), "测试必须运行在隔离APPDATA")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var dialogue: Node = game.get_node("DialogueWindow")
	# 缩短滑入时间，测试不等待真实 0.25 秒。
	dialogue.slide_seconds = 0.03

	# 用例1：带确认对话，读条中单击应跳到等待确认，确认按钮可点击。
	dialogue.enqueue_dialogue({"text": "confirm me", "duration": 30.0, "requires_confirmation": true})
	check(await wait_phase(dialogue, dialogue.Phase.READING, 2000), "带确认对话进入读条阶段")
	# 等待超过 minimum_read_seconds（0.2s）再单击。
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 300:
		await process_frame
	click(Vector2(600, 650))
	await process_frame
	await process_frame
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM, "单击后带确认对话跳到等待确认（phase=%d）" % dialogue.phase)
	check(not dialogue.confirm_button.disabled, "单击跳过后确认按钮已可点击")
	dialogue.confirm_button.pressed.emit()
	check(await wait_phase(dialogue, dialogue.Phase.IDLE, 2000) and dialogue.pending_count() == 0, "确认后完成并清空队列")

	# 用例2：不带确认对话，读条中单击应直接完成进入下一条。
	dialogue.enqueue_dialogue({"text": "no confirm", "duration": 30.0})
	check(await wait_phase(dialogue, dialogue.Phase.READING, 2000), "无确认对话进入读条阶段")
	started = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 300:
		await process_frame
	click(Vector2(600, 650))
	check(await wait_phase(dialogue, dialogue.Phase.IDLE, 2000) and dialogue.pending_count() == 0, "无确认对话单击后直接完成")

	# 用例3：刚进入读条（minimum_read_seconds 内）单击不跳过，防误触。
	dialogue.enqueue_dialogue({"text": "guard", "duration": 30.0})
	check(await wait_phase(dialogue, dialogue.Phase.READING, 2000), "第三条进入读条阶段")
	click(Vector2(600, 650))
	await process_frame
	await process_frame
	check(dialogue.phase == dialogue.Phase.READING, "刚弹出瞬间单击不跳过（防误触，phase=%d）" % dialogue.phase)
	# 等待读条自然完成，确认未被误跳过。
	started = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 400:
		await process_frame
	check(dialogue.phase == dialogue.Phase.READING and dialogue.progress.value > 0.0, "未到最小阅读时长单击后读条仍在推进")

	print("DIALOGUE_SKIP_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
