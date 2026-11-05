extends SceneTree
var failures := 0
var checks := 0
func _initialize() -> void:
	_run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
func click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
		await process_frame
func wait_confirm(dialogue: Node) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while dialogue.phase != dialogue.Phase.WAITING_CONFIRM and Time.get_ticks_msec() < deadline:
		await process_frame
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM, "计时结束等待确认")
func _run() -> void:
	if not OS.get_user_data_dir().contains("space-confirm-review"):
		quit(1)
		return
	root.size = Vector2i(1280, 720)
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var dialogue: Node = game.get_node("DialogueWindow")
	var city: Node = game.get_node("TutorialController")
	var orbit: Node = game.get_node("OrbitTutorialController")
	var progression: Node = game.get_node("ProgressionManager")
	var skip: Button = game.get_node("TutorialHUD/Root/Panel/Margin/Content/Skip")
	dialogue.slide_seconds = 0.0
	city.duration_scale = 0.01
	orbit.duration_scale = 0.01
	progression.start_new_game()
	await process_frame
	check(dialogue.confirm_button.visible and dialogue.confirm_button.disabled, "读条期间确认禁用")
	check(orbit.current_step_id() == "observe", "行星观察为第一课，无需选船")
	await wait_confirm(dialogue)
	for index in range(8):
		await process_frame
	check(orbit.current_step_id() == "observe", "计时结束不自动推进")
	check(dialogue.confirm_button.mouse_filter == Control.MOUSE_FILTER_STOP, "确认按钮拦截输入")
	await click(dialogue.confirm_button)
	for index in range(4):
		await process_frame
	check(orbit.current_step_id() == "orbit_physics", "真实点击确认进入轨道科普步骤")
	await wait_confirm(dialogue)
	check(orbit.current_step_id() == "orbit_physics", "前次点击未确认下一弹窗")
	await click(dialogue.confirm_button)
	for index in range(4):
		await process_frame
	check(orbit.current_step_id() == "thrust", "科普确认后进入推进步骤")
	await click(skip)
	for index in range(4):
		await process_frame
	check(progression.stage == progression.Stage.CITY and city.active and not city.skipped, "行星跳过仅进入城市阶段")
	await wait_confirm(dialogue)
	check(city.current_step_id() == "select_ship", "城市选船不自动推进")
	game._select_target(game.ships[0])
	await wait_confirm(dialogue)
	await click(dialogue.confirm_button)
	for index in range(4):
		await process_frame
	check(city.current_step_id() == "accelerate", "城市选船确认后进入加速步骤")
	await click(skip)
	for index in range(4):
		await process_frame
	check(progression.stage == progression.Stage.WORLD and city.skipped, "城市跳过后进入世界")
	dialogue.clear_queue()
	dialogue.enqueue_dialogue({"text": "普通通知", "duration": 0.01})
	check(not dialogue.confirm_button.visible, "普通通知隐藏确认")
	var deadline := Time.get_ticks_msec() + 2000
	while dialogue.pending_count() > 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(dialogue.pending_count() == 0, "普通通知仍自动结束")
	game.queue_free()
	await process_frame
	print("TUTORIAL_CONFIRM_REVIEW: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
