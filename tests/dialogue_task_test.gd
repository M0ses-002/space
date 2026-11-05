extends SceneTree
var failures: int = 0
var starts: Array[String] = []
var finishes: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func step(game: Node) -> void:
	game.accumulator = 0.0
	game._physics_process(game.SIM_STEP / game.TIME_SCALE / game.simulation_speed)

func prepare(game: Node) -> void:
	game._stop_thrust()
	game.simulation_paused = false
	game.selecting_orbit = false
	game._select_target(game.ships[0])
	game.ship.flight_position = Vector2(0, -2000000)
	game.ship.flight_velocity = Vector2.RIGHT * 100.0
	game.ship.heading = Vector2.RIGHT
	game.ship.fuel = 1000.0
	game.ship.crashed = false
	game.ship.voyage_finished = false
	game.ship.thrust_lock_enabled = false
	game.ship.maneuver_commands.clear()
	game.ship.maneuver_index = 0

func _run() -> void:
	check(ProjectSettings.globalize_path("user://").contains("space-dialogue-architect-test"), "测试必须运行在隔离APPDATA")
	if failures > 0:
		quit(1)
		return
	# 音频不属于本测试；headless dummy音频后端退出时会保留循环WAV播放引用。
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var tasks: Node = game.get_node("TaskManager")
	var dialogue: Node = game.get_node("DialogueWindow")
	var save: Node = root.get_node("SaveManager")
	# 线上 data/dialogue_tasks.json 已清空；本测试用固定夹具验证「触发→对话→存档」机制本身，
	# 避免产品数据调整把机制测试带红。
	tasks.config_path = "res://tests/fixtures/dialogue_tasks_lat.json"
	tasks.bind_game(game)
	prepare(game)
	check(tasks._tasks.size() == 1, "独立JSON任务配置已加载")
	check(dialogue.has_node("Root/Portrait") and dialogue.has_node("Root/Panel/Margin/Content/Progress"), "头像文字进度节点来自独立场景")
	check(dialogue.message.get_theme_font_size("font_size") == 18, "横向对话使用18号正文")
	check(dialogue.portrait.custom_minimum_size == Vector2(130, 160), "人物图放大为130×160并保持比例")
	for control: Control in dialogue.get_node("Root").find_children("*", "Control"):
		if control == dialogue.confirm_button:
			check(control.mouse_filter == Control.MOUSE_FILTER_STOP and not control.visible, "教程确认按钮阻止穿透，普通消息不显示")
		else:
			check(control.mouse_filter == Control.MOUSE_FILTER_IGNORE, "非交互对话控件保持鼠标穿透")
	game.ship.fuel = 0.0
	game._start_thrust(1.0)
	game._set_throttle(1.0)
	step(game)
	check(tasks.triggered_tasks.is_empty(), "无油点击不触发")
	prepare(game)
	game.simulation_paused = true
	game._set_thrust_direction(Vector2.RIGHT)
	game._set_thrust_lock(true)
	game._start_thrust(1.0)
	game._set_throttle(1.0)
	var paused_position: Vector2 = game.ship.flight_position
	var paused_velocity: Vector2 = game.ship.flight_velocity
	var paused_fuel: float = game.ship.fuel
	step(game)
	check(game.ship.steering and game.ship.thrust_throttle == 1.0 and game.ship.manual_thrust == 0.0, "暂停保存方向推力设定但拒绝长按按钮")
	check(game.ship.flight_position == paused_position and game.ship.flight_velocity == paused_velocity and game.ship.fuel == paused_fuel and tasks.triggered_tasks.is_empty(), "暂停预设不积分、不耗油、不触发任务")
	game._toggle_pause()
	check(tasks.triggered_tasks.is_empty(), "解除暂停本身不触发任务")
	step(game)
	check(tasks.triggered_tasks.has("first_forward_acceleration") and game.ship.fuel < paused_fuel, "恢复后真实推进提交才触发任务")
	tasks.reset_for_new_game()
	game._set_thrust_lock(false)
	prepare(game)
	game._set_thrust_direction(Vector2.RIGHT)
	game._refresh_preview()
	game._advance_preview_job(20)
	check(tasks.triggered_tasks.is_empty(), "预览及转针不触发")
	game._start_thrust(-1.0)
	step(game)
	check(tasks.triggered_tasks.is_empty(), "固定减速不触发")
	prepare(game)
	game.ship.flight_position = Vector2(0, -255000)
	game.ship.maneuver_commands = [5.0]
	game.ship.maneuver_index = 0
	game.ship.maneuver_target = game.planets[0]
	var automatic_fuel_before: float = game.ship.fuel
	step(game)
	check(game.ship.fuel < automatic_fuel_before and tasks.triggered_tasks.is_empty(), "自动入轨真实耗油命令不触发")
	prepare(game)
	game._set_thrust_direction(Vector2.DOWN)
	game._set_throttle(1.0)
	step(game)
	check(tasks.triggered_tasks.is_empty(), "侧推即使速率略增也不算正向")
	prepare(game)
	game._set_thrust_direction(Vector2.LEFT)
	game._set_throttle(1.0)
	step(game)
	check(tasks.triggered_tasks.is_empty(), "反向方向推进不触发")
	prepare(game)
	game._start_thrust(1.0)
	check(tasks.triggered_tasks.is_empty(), "按下加速尚未提交时不触发")
	step(game)
	check(tasks.triggered_tasks.has("first_forward_acceleration") and dialogue.pending_count() == 1, "固定5m/s²首次真实提交触发")
	step(game)
	game._stop_thrust()
	game._start_thrust(1.0)
	step(game)
	check(dialogue.pending_count() == 1, "多物理步和重复点击只触发一次")
	game._stop_thrust()
	var snapshot: Dictionary = save.make_snapshot(game)
	check(snapshot.has("task_state") and snapshot.task_state.triggered.has("first_forward_acceleration"), "存档记录已触发任务")
	tasks.reset_for_new_game()
	check(save.restore_snapshot(game, snapshot) and tasks.triggered_tasks.has("first_forward_acceleration"), "恢复存档保持已触发")
	check(dialogue.pending_count() == 0, "不重播存档前瞬时对话")
	prepare(game)
	game._start_thrust(1.0)
	step(game)
	check(dialogue.pending_count() == 0, "读档后再次加速不重复")
	var malformed: Dictionary = snapshot.duplicate(true)
	malformed.task_state.triggered["bad"] = "true"
	check(not save.restore_snapshot(game, malformed), "非法任务状态在修改游戏之前拒绝")
	var legacy: Dictionary = snapshot.duplicate(true)
	legacy.erase("task_state")
	check(save.restore_snapshot(game, legacy) and tasks.triggered_tasks.is_empty(), "旧v1无任务字段兼容且默认未触发")
	prepare(game)
	game._set_thrust_direction(Vector2(1.0, 1.0).normalized())
	game._set_throttle(0.5)
	step(game)
	check(tasks.triggered_tasks.has("first_forward_acceleration"), "斜向推进具有正向分量时触发")
	game._reset()
	check(tasks.triggered_tasks.has("first_forward_acceleration") and dialogue.pending_count() == 0, "重置航行清队列但保留本局任务历史")
	tasks.reset_for_new_game()
	prepare(game)
	game.ship.flight_velocity = Vector2.ZERO
	game._set_thrust_direction(Vector2.RIGHT)
	game._set_throttle(0.5)
	step(game)
	check(tasks.triggered_tasks.has("first_forward_acceleration"), "新游戏清历史且静止沿航向正推可触发")
	game._stop_thrust()
	# 验证底部横向人物对话在不同逻辑视口中避让仪表、快捷栏与目标栏。
	root.content_scale_size = Vector2i.ZERO
	dialogue.clear_queue()
	dialogue.enqueue_dialogue(tasks._tasks[0].dialogue)
	for viewport_size: Vector2i in [Vector2i(960, 640), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = viewport_size
		await process_frame
		await process_frame
		dialogue._place_panel(1.0)
		await process_frame
		dialogue._place_panel(1.0)
		var bounds: Rect2 = dialogue.panel.get_global_rect()
		var dial: Control = game.get_node("HUD/Root/ThrustDial")
		var fleet: Control = game.get_node("HUD/Root/FleetBar")
		var map_panel: Control = game.get_node("StarMapView").navigation_buttons
		check(is_equal_approx(bounds.size.x, viewport_size.x * 0.55) and is_equal_approx(bounds.get_center().x, viewport_size.x / 2.0), "视口%s横向对话占窗口55%%并底部居中 %s" % [viewport_size, bounds])
		check(is_equal_approx(bounds.size.y, 100.0) and is_equal_approx(bounds.end.y, viewport_size.y - 76.0), "视口%s对话100高且距底76像素 %s" % [viewport_size, bounds])
		check(not bounds.intersects(game.panel.get_global_rect()) and not bounds.intersects(game.get_node("HUD/Root/BottomActions").get_global_rect()), "对话不遮挡右侧信息栏或底部快捷栏")
		check(dialogue.portrait.get_global_rect().position.x < dialogue.message.get_global_rect().position.x and dialogue.portrait.size.y >= 160.0, "人物在左正文在右，头像保持放大")
		check(dialogue.portrait.get_global_rect().end.y <= dialogue.panel.get_global_rect().end.y + 0.5 and dialogue.portrait.get_global_rect().position.y < dialogue.panel.get_global_rect().position.y, "人物图底部对齐面板并向上超出面板边界")
		check(dialogue.message.get_line_count() == dialogue.message.get_visible_line_count(), "现有通知正文换行后完整显示")
		check(not bounds.intersects(dial.get_global_rect()), "视口%s不遮挡仪表 %s / %s" % [viewport_size, bounds, dial.get_global_rect()])
		check(not bounds.intersects(fleet.get_global_rect()) and not bounds.intersects(map_panel.get_global_rect()), "视口%s不遮挡舰队栏或星图面板 %s / %s" % [viewport_size, bounds, map_panel.get_global_rect()])
		check(Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(bounds), "视口%s通知完整在窗口内" % viewport_size)
	# 独立队列按现实秒计时，使用短配置避免测试等待五秒。
	dialogue.clear_queue()
	dialogue.slide_seconds = 0.03
	dialogue.dialogue_started.connect(func(data: Dictionary) -> void: starts.append(data.text))
	dialogue.dialogue_finished.connect(func(data: Dictionary) -> void: finishes.append(data.text))
	check(not dialogue.enqueue_dialogue({"text": "invalid", "duration": 0.0}), "非法时长拒绝")
	check(dialogue.enqueue_dialogue({"text": "one", "duration": 0.18, "portrait": "res://missing.svg"}), "缺图使用既有头像回退")
	check(dialogue.portrait.texture != null and dialogue.panel.get_global_rect().position.y >= root.get_visible_rect().end.y, "头像有效且向上滑入起点在窗口下方")
	check(dialogue.enqueue_dialogue({"text": "two", "duration": 0.08}), "第二条加入队列")
	check(dialogue.pending_count() == 2, "活动项与等待项计数")
	var deadline: int = Time.get_ticks_msec() + 2000
	while dialogue.phase != dialogue.Phase.READING and Time.get_ticks_msec() < deadline:
		await process_frame
	check(dialogue.phase == dialogue.Phase.READING and dialogue.message.text == "one", "滑入后读第一条")
	check(absf(dialogue.progress.value) < 0.1, "读条不把滑入时间算入配置时长")
	var started: int = Time.get_ticks_msec()
	Engine.time_scale = 4.0
	game._set_simulation_speed(2.0)
	root.get_tree().paused = true
	while Time.get_ticks_msec() - started < 80:
		await process_frame
	check(dialogue.phase == dialogue.Phase.READING and dialogue.progress.value > 0.2 and dialogue.progress.value < 0.85, "全树暂停与模拟倍率/Engine倍率不改变现实读条")
	root.get_tree().paused = false
	Engine.time_scale = 1.0
	while dialogue.pending_count() > 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(starts == ["one", "two"] and finishes == ["one", "two"] and not dialogue.visible, "滑出后FIFO播放第二条并最终隐藏")
	check(Time.get_ticks_msec() - started >= 250, "完整读条与滑动未被倍率压缩")
	print("DIALOGUE_TASK_TEST: %s (%d failures); isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", failures, ProjectSettings.globalize_path("user://")])
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
