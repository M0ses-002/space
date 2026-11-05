extends SceneTree
var failures := 0
var checks := 0
var visited: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func step(game: Node, count: int = 1) -> void:
	for index in range(count):
		game.accumulator = 0.0
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)

func wait_step(tutorial: Node, id: String) -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while tutorial.active and tutorial.current_step_id() != id and Time.get_ticks_msec() < deadline:
		var current: String = tutorial.current_step_id()
		if not visited.has(current):
			visited.append(current)
		var dialogue: Node = tutorial.get_parent().get_node("DialogueWindow")
		if dialogue.phase == dialogue.Phase.WAITING_CONFIRM:
			dialogue.confirm_button.pressed.emit()
		await process_frame
	check(tutorial.current_step_id() == id, "教程到达步骤：" + id)

func confirm_message(game: Node) -> void:
	var dialogue: Node = game.get_node("DialogueWindow")
	var deadline := Time.get_ticks_msec() + 2000
	while dialogue.phase != dialogue.Phase.WAITING_CONFIRM and Time.get_ticks_msec() < deadline:
		await process_frame
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM, "教程读条结束等待手动确认")
	dialogue.confirm_button.pressed.emit()
	await process_frame
	await process_frame

func check_tutorial_camera(game: Node, message: String) -> void:
	var camera: Node = game.get_node("NavigationCamera")
	var tutorial: Node = game.get_node("TutorialController")
	var vessel: Node2D = tutorial.tutorial_ship if is_instance_valid(tutorial.tutorial_ship) else game.ships[0]
	camera.apply_tutorial_view()
	var screen: Vector2 = game.get_viewport().get_canvas_transform() * game.get_node("World").to_global(game._to_screen(vessel.flight_position))
	check(camera.is_tutorial_locked() and camera.following and not game.get_node("StarMapView").map_mode and camera.zoom.is_equal_approx(Vector2.ONE * tutorial.tutorial_zoom), message + "：固定近域缩放与跟随")
	check(screen.distance_to(game.get_viewport_rect().size * 0.5) < 0.1, message + "：严格视口中心")

func _run() -> void:
	check(OS.get_user_data_dir().contains("space-tutorial-test"), "专项必须使用隔离用户目录")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var save: Node = root.get_node("SaveManager")
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_physics_process(false)
	await process_frame
	await process_frame
	var tutorial: Node = game.get_node("TutorialController")
	var dialogue: Node = game.get_node("DialogueWindow")
	var menu: Node = game.get_node("PauseMenu")
	dialogue.dialogue_started.connect(func(data: Dictionary):
		if not data.has("tutorial_token"):
			return
		check(str(data.get("portrait", "")) == "res://assets/ui/tutorial_portrait.png", "所有教程弹窗使用用户提供的新图片")
		check(dialogue.portrait.texture != null and dialogue.portrait.texture.resource_path == "res://assets/ui/tutorial_portrait.png", "教程头像实际加载新贴图")
	)
	check(not tutorial.active, "直接打开演示场景不自动开启教程")
	tutorial.duration_scale = 0.003
	dialogue.slide_seconds = 0.0
	tutorial.start_new_game()
	check(tutorial.active and tutorial.current_step_id() == "select_ship" and not game.selected and game.simulation_paused, "新游戏暂停并等待真实选船")
	check(game.ship.flight_velocity == Vector2.ZERO and game._gravity_at(game.ship.flight_position) == Vector2.ZERO and not game._touches_planet(game.ship.flight_position), "真实地图港口附近零速无引力安全起点")
	var camera: Node = game.get_node("NavigationCamera")
	var view: Node = game.get_node("StarMapView")
	check_tutorial_camera(game, "选船前暂停")
	camera._pan(Vector2.RIGHT, 2.0)
	var pan_key := InputEventKey.new()
	pan_key.pressed = true
	pan_key.physical_keycode = KEY_D
	Input.parse_input_event(pan_key)
	Input.flush_buffered_events()
	camera._process(1.0)
	pan_key = InputEventKey.new()
	pan_key.pressed = false
	pan_key.physical_keycode = KEY_D
	Input.parse_input_event(pan_key)
	Input.flush_buffered_events()
	var wheel := InputEventMouseButton.new()
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.position = Vector2(460.0, 280.0)
	Input.parse_input_event(wheel)
	Input.flush_buffered_events()
	var toggle := InputEventKey.new()
	toggle.pressed = true
	toggle.physical_keycode = KEY_M
	Input.parse_input_event(toggle)
	Input.flush_buffered_events()
	view.map_button.pressed.emit()
	view.set_map_mode(true)
	view._fit_star_map()
	check_tutorial_camera(game, "WASD滚轮M与切图按钮不能打破锁")
	check(view.map_button.disabled, "教程星图按钮禁用")
	var initial_region: Node2D = game.ships[0].region_source
	game.ships[0].region_source = game.planets[0]
	view.pending_region_id = game.planets[0].get_instance_id()
	view.pending_since_msec = Time.get_ticks_msec() - 1000
	view._observe_region()
	game.ships[0].region_source = initial_region
	check_tutorial_camera(game, "区域自动切图不能缩小教程")
	var ship_sprite: Sprite2D = game.ships[0].get_node("Visual/NearSprite")
	check(ship_sprite.visible and ship_sprite.texture.get_width() * ship_sprite.scale.x * camera.zoom.x >= 70.0, "教程飞船贴图明显至少70屏幕像素")
	game._select_target(game.ships[0], false)
	check(tutorial.current_step_id() == "select_ship", "自动选船不满足玩家选船目标")
	menu.open()
	game._toggle_pause()
	menu.close()
	check(game.simulation_paused, "ESC关闭与暂停按钮不能解除教程暂停")
	game._begin_orbit_selection()
	check(not game.selecting_orbit and game.simulation_paused, "讲解期间不能通过入轨选择绕过教程暂停")
	for target: String in tutorial.TARGET_PATHS:
		check(tutorial.resolve_highlight_target(target) != null, "高亮映射有效：" + target)
	check(tutorial.resolve_highlight_target("port") == tutorial.target_city.get_node("DockButton"), "港口高亮引用实际城市按钮")
	check(tutorial.resolve_highlight_target("ship") == game.ships[0], "选船前ship高亮引用真实起始船")
	check(tutorial.resolve_highlight_target("port_line") == tutorial.target_city.get_node("PortGuideLine") and tutorial.resolve_highlight_target("port_marker") == tutorial.target_city.get_node("Port/DockMarker"), "引导线与泊船标记高亮映射有效")
	var highlight: Node = game.get_node("HighlightLayer")
	check(highlight != null and highlight.frame != null and highlight.ring != null, "教程高亮层节点与高亮框存在")
	highlight._on_highlight("accelerate")
	await process_frame
	check(highlight.frame.visible and not highlight.ring.visible, "指定按钮目标后高亮框可见")
	var accel: Control = game.get_node("HUD/Root/ThrustDial/Layout/AccelerateButton")
	check(highlight.frame.get_global_rect().encloses(accel.get_global_rect()), "高亮框覆盖加速按钮")
	highlight._on_highlight("port_marker")
	await process_frame
	check(highlight.ring.visible and not highlight.frame.visible, "世界节点目标显示圆环标记")
	highlight._clear()
	await process_frame
	check(not highlight.frame.visible and not highlight.ring.visible, "清除后高亮框隐藏")
	var throttle: VSlider = game.get_node("HUD/Root/ThrustDial/Layout/Throttle")
	var track: StyleBox = throttle.get_theme_stylebox("slider")
	check(track is StyleBoxFlat and (track as StyleBoxFlat).bg_color.a > 0.0, "油门滑条轨道有底色")
	check(tutorial._steps.size() == 19, "实际JSON包含19个细步骤（含港口界面介绍）")
	game._select_target(game.ships[0])
	check(tutorial.current_step_id() == "select_ship", "真实选船达成但未确认消息不推进")
	await confirm_message(game)
	check(tutorial.current_step_id() == "accelerate" and not game.simulation_paused, "选船与手动确认后恢复模拟")
	menu.open()
	var menu_snapshot: Dictionary = save.make_snapshot(game)
	check(not menu_snapshot.tutorial_state.previous_pause and not menu_snapshot.paused, "ESC菜单保存不固化临时暂停")
	check(save.restore_snapshot(game, menu_snapshot) and game.simulation_paused, "菜单内读档保留菜单暂停")
	menu.close()
	check(not game.simulation_paused, "菜单内读档再关闭正常恢复")
	await confirm_message(game)
	game.ship.flight_velocity = game.ship.heading * 25.0
	step(game)
	check(tutorial.current_step_id() == "accelerate", "外部已有高速不算真实正向推进")
	game.ship.flight_velocity = Vector2.ZERO
	game.ship.fuel = 0.0
	game._start_thrust(1.0)
	step(game)
	check(tutorial.current_step_id() == "accelerate", "无油按加速不能过关")
	game.ship.fuel = 1000.0
	game.ship.flight_velocity = game.ship.heading * 10.0
	game._set_thrust_direction(game.ship.heading.rotated(PI * 0.5))
	game._set_throttle(1.0)
	step(game)
	check(tutorial.current_step_id() == "accelerate", "侧向推进不算正向目标")
	game._stop_thrust()
	game.ship.flight_velocity = game.ship.heading * 19.0
	game._start_thrust(1.0)
	game._physics_process(0.5)
	check(tutorial.current_step_id() == "coast" and game.simulation_paused and game.ship.flight_velocity.length() < 21.0, "大帧多固定步在20m/s阈值立即停止，不跨越继续推进")
	check_tutorial_camera(game, "真实移动后暂停仍居中")
	check(game.ship.manual_thrust == 0.0 and not game.ship.steering, "完成目标自动收油")
	check(not game.get_node("TaskManager").triggered_tasks.is_empty() and dialogue.current_dialogue.get("id") == "coast", "旧首次加速通知不混入教程队列")
	menu.open()
	await wait_step(tutorial, "brake")
	check(game.simulation_paused, "说明结束时ESC菜单仍持有暂停")
	menu.close()
	check(not game.simulation_paused, "关闭ESC后恢复当前运行步骤")
	await confirm_message(game)
	game._start_thrust(-1.0)
	step(game, 30)
	check(tutorial.current_step_id() == "fuel" and game.simulation_paused and game.ship.flight_velocity.length() <= 0.1, "减速固定步检测到停稳并暂停")
	var snapshot: Dictionary = save.make_snapshot(game)
	check(snapshot.version == 6 and snapshot.tutorial_state.active and snapshot.tutorial_state.step == 4, "v6存档包含独立教程状态")
	tutorial.skip_tutorial()
	check(not tutorial.active and not game.tutorial_pause and not game.simulation_paused and dialogue.pending_count() == 0, "跳过清队列与教程暂停")
	check(not camera.is_tutorial_locked(), "跳过解除教程相机锁")
	var released_position: Vector2 = camera.position
	camera._pan(Vector2.RIGHT, 0.1)
	if game.ship.camera_always_follow:
		check(camera.position == released_position and camera.following, "跳过教程后仍保持「视角始终跟随」，WASD 不平移")
	else:
		check(camera.position != released_position and not camera.following, "跳过后WASD平移恢复可用")
	view.set_map_mode(false)
	var released_zoom: Vector2 = camera.zoom
	camera._input(wheel)
	check(camera.zoom != released_zoom, "跳过后滚轮缩放恢复可用")
	view.set_map_mode(true)
	check(view.map_mode and not view.map_button.disabled, "跳过后切星图按钮恢复可用")
	var legacy_camera_snapshot: Dictionary = snapshot.duplicate(true)
	legacy_camera_snapshot.erase("tutorial_state")
	check(save.restore_snapshot(game, legacy_camera_snapshot) and not camera.is_tutorial_locked(), "恢复非教程存档清除相机锁")
	check(save.restore_snapshot(game, snapshot) and tutorial.current_step_id() == "fuel" and game.simulation_paused, "续档恢复步骤并重播当前说明")
	check_tutorial_camera(game, "活动教程读档重建视角锁")
	var invalid: Dictionary = snapshot.duplicate(true)
	invalid.tutorial_state.step = 1000
	check(not save.restore_snapshot(game, invalid) and tutorial.current_step_id() == "fuel", "非法教程状态在修改游戏前拒绝")
	await wait_step(tutorial, "dock")
	check(visited.has("throttle") and visited.has("acceleration") and visited.has("needles") and visited.has("directions") and visited.has("angle") and visited.has("world_direction") and visited.has("return_port") and visited.has("approach"), "所有说明经真实对话队列完整播放")
	check(not game.simulation_paused and game.ship.has_navigation_target and game.ship.navigation_target == tutorial.target_city.get_dock_position(), "返回港口保持正常模拟与真实导航引导")
	# 从教学起点真实飞回港口，不搬运飞船、不篡改地图或泊船资格。
	var city: Node2D = tutorial.target_city
	var center: Vector2 = city.flight_position + city.port_offset_m.rotated(deg_to_rad(city.rotation_degrees_m))
	var distance_before: float = game.ship.flight_position.distance_to(center)
	var travel_steps := 0
	while travel_steps < 10000 and game.ship.flight_position.distance_to(center) > city.docking_radius_m * 0.8 + game.ship.flight_velocity.length_squared() / 10.0 + 30.0:
		if game.ship.flight_velocity.length() < 100.0:
			game._set_thrust_direction((center - game.ship.flight_position).normalized())
			game._set_throttle(1.0)
		else:
			game._stop_thrust()
		step(game)
		travel_steps += 1
	game._start_thrust(-1.0)
	while game.ship.flight_velocity.length() > 0.1 and travel_steps < 10000:
		step(game)
		travel_steps += 1
	check(travel_steps < 10000 and game.ship.flight_position.distance_to(center) < distance_before and not game.ship.crashed, "教程实际地图起点可正常手动推力飞回港口")
	check(tutorial._dock_prompted and game._can_dock_city(city), "正常物理停稳后使用既有泊船资格提示")
	check(tutorial.current_step_id() == "dock", "仅具备资格不算实际泊船完成")
	# 目标栏在三种逻辑窗口完整显示，不覆盖教程对话、推力或星图控制。
	root.content_scale_size = Vector2i.ZERO
	for viewport_size: Vector2i in [Vector2i(960, 640), Vector2i(1200, 720), Vector2i(1600, 900)]:
		root.size = viewport_size
		await process_frame
		await process_frame
		check_tutorial_camera(game, "窗口变化%s" % viewport_size)
		dialogue.clear_queue()
		dialogue.enqueue_dialogue({"text": "展开中的教程对话，用于检验目标栏不会遮挡文字与头像。", "duration": 30})
		tutorial._layout_view()
		dialogue._place_panel(1.0)
		await process_frame
		dialogue._place_panel(1.0)
		check(dialogue.visible, "布局断言时对话真实展开：" + str(viewport_size))
		var bounds: Rect2 = game.get_node("TutorialHUD/Root/Panel").get_global_rect()
		check(Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(bounds), "目标栏完整位于窗口内：" + str(viewport_size))
		check(not bounds.intersects(dialogue.panel.get_global_rect()) and not bounds.intersects(game.get_node("HUD/Root/ThrustDial").get_global_rect()) and not bounds.intersects(game.get_node("StarMapView").navigation_buttons.get_global_rect()), "目标栏不挡对话、推力与星图：" + str(viewport_size))
		check(not dialogue.panel.get_global_rect().intersects(game.get_node("HUD/Root/BottomActions").get_global_rect()), "横向对话不挡底部快捷栏：" + str(viewport_size))
		for config_step: Dictionary in tutorial._steps:
			dialogue.message.text = config_step.text
			dialogue._place_panel(1.0)
			await process_frame
			await process_frame
			dialogue._place_panel(1.0)
			check(dialogue.message.get_line_count() == dialogue.message.get_visible_line_count() and dialogue.panel.get_global_rect().encloses(dialogue.message.get_global_rect()), "教程正文在大字横框中完整换行显示：%s %s" % [viewport_size, config_step.id])
	# 布局测试替换过队列，恢复当前教学并逐条确认泊船说明。
	tutorial._enter_step()
	tutorial._on_simulation_step(game.ship)
	await confirm_message(game)
	if dialogue.pending_count() > 0:
		await confirm_message(game)
	game._dock_city(city)
	await wait_step(tutorial, "completed")
	var deadline := Time.get_ticks_msec() + 2000
	while tutorial.active and Time.get_ticks_msec() < deadline:
		if dialogue.phase == dialogue.Phase.WAITING_CONFIRM:
			dialogue.confirm_button.pressed.emit()
		await process_frame
	check(tutorial.completed and not tutorial.active and game.get_node("PortController").active and game.ship.arrival_source == city, "实际进入目标city并播放完成提示后结束")
	check(not camera.is_tutorial_locked(), "完整教程完成解除相机锁")
	var finished: Dictionary = save.make_snapshot(game)
	check(save.restore_snapshot(game, finished) and tutorial.completed and not tutorial.active, "已完成续档不重启")
	var legacy: Dictionary = finished.duplicate(true)
	legacy.erase("tutorial_state")
	check(save.restore_snapshot(game, legacy) and not tutorial.active and not game.tutorial_pause, "旧v1无教程字段默认不启动")
	game.get_node("PortController").leave_port()
	game._reset()
	await process_frame
	tutorial.start_new_game()
	menu.open()
	tutorial.skip_tutorial()
	check(game.simulation_paused and not game.tutorial_pause, "菜单内跳过保留菜单暂停")
	menu.close()
	check(not game.simulation_paused, "跳过后关闭菜单不残留教程暂停")
	tutorial.start_new_game()
	game._reset()
	check(tutorial.active and tutorial.step_index == 0 and tutorial.current_step_id() == "select_ship" and game.tutorial_pause and game.simulation_paused, "重置航行重做当前教程第0步")
	check(camera.is_tutorial_locked(), "重置航行重建当前教程相机锁")
	await process_frame
	var cities: Array = game.cities.duplicate()
	game.cities.clear()
	tutorial.start_new_game()
	check(not tutorial.active and tutorial.skipped and game.flight_message.contains("没有可安全使用"), "无城市优雅跳过，不造假目标")
	game.cities.assign(cities)
	dialogue.clear_queue()
	# 使用真实SaveManager新游戏入口，验证新顺序先进入行星教程。
	save.start_new_game()
	await save._attach_after_scene_change(game)
	check(save.enabled and game.get_node("OrbitTutorialController").active and game.get_node("OrbitTutorialController").current_step_id() == "observe", "真实新游戏挂载自动开始并保存教程（行星先）")
	game.set_physics_process(false)
	# 跳过行星进入城市，验证城市选船续档不抢跑。
	game.get_node("ProgressionManager")._on_skip_pressed()
	await process_frame
	check(tutorial.active and tutorial.current_step_id() == "select_ship" and not game.selected, "跳过行星进入城市选船")
	var active_save: Dictionary = save.make_snapshot(game)
	tutorial.skip_tutorial()
	check(save.restore_snapshot(game, active_save) and tutorial.current_step_id() == "select_ship", "选船前续档仍等待真实选择")
	check(tutorial.tutorial_ship == null, "step0续档没有虚假教程船引用")
	game._select_target(game.ships[0])
	await confirm_message(game)
	check(tutorial.current_step_id() == "accelerate", "step0续档可真实选择第一船并确认继续")
	tutorial.skip_tutorial()
	# 该用例只验证城市提前泊船：先结束行星教程并固定到含城市的世界地图。
	# 重置航行现在改为重做当前课，不再借重置推进到世界地图。
	game.get_node("OrbitTutorialController").cancel_for_reset()
	game.load_world_map()
	await process_frame
	# 两个返港说明阶段提前泊船，须直接进入完成说明，不能等到dock再卡住。
	for early_id: String in ["return_port", "approach"]:
		game.get_node("PortController").leave_port()
		game._reset()
		await process_frame
		tutorial.start_new_game()
		game._select_target(game.ships[0])
		for index in range(tutorial._steps.size()):
			if tutorial._steps[index].id == early_id:
				tutorial.step_index = index
				tutorial._enter_step()
		game.ship.flight_position = tutorial.target_city.flight_position + tutorial.target_city.port_offset_m.rotated(deg_to_rad(tutorial.target_city.rotation_degrees_m)) + Vector2.LEFT * tutorial.target_city.docking_radius_m * 0.9
		game.ship.flight_velocity = Vector2.ZERO
		game._dock_city(tutorial.target_city)
		tutorial._process(0.0)
		check(tutorial.current_step_id() == early_id and game.get_node("PortController").active, "返港提前泊船不越过待确认说明：" + early_id)
		await confirm_message(game)
		check(tutorial.current_step_id() == "port_events", "确认后保留提前泊船结果并进入港口界面介绍：" + early_id)
		await confirm_message(game)
		await confirm_message(game)
		await confirm_message(game)
		await confirm_message(game)
		check(tutorial.current_step_id() == "completed", "港口界面介绍确认完毕进入完成说明：" + early_id)
		tutorial.skip_tutorial()
	game.get_node("PortController").leave_port()
	tutorial._load_config("res://data/missing_tutorial.json")
	tutorial.start_new_game()
	check(not tutorial.active and tutorial.skipped and game.flight_message.contains("配置无法读取") and not game.tutorial_pause, "配置读取失败优雅跳过并说明")
	game.queue_free()
	await process_frame
	print("TUTORIAL_TEST: %s (%d checks, %d failures); isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", checks, failures, OS.get_user_data_dir()])
	quit(0 if failures == 0 else 1)
