extends SceneTree
## 使用真实GUI鼠标事件回归教程确认、实际操作与待确认消息竞态、共享跳过。
var failures := 0
var checks := 0
var finished: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func click(button: Button) -> void:
	await process_frame
	var position := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	Input.flush_buffered_events()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
		Input.flush_buffered_events()
		await process_frame
	await process_frame

func ready_to_confirm(dialogue: Node) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while dialogue.phase != dialogue.Phase.WAITING_CONFIRM and Time.get_ticks_msec() < deadline:
		await process_frame
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM and not dialogue.confirm_button.disabled, "倒计时结束启用确认")

func check_goal_ready(dialogue: Node, label: String) -> void:
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM and dialogue.progress.value == 1.0 and not dialogue.confirm_button.disabled, label + "：目标达标立即进度1并启用确认")
	check(float(Time.get_ticks_usec() - dialogue._phase_started_usec) / 1000000.0 < dialogue._reading_seconds, label + "：原计时尚未结束")
	var expected_y: float = dialogue.get_viewport().get_visible_rect().size.y - dialogue.screen_margin.y - dialogue.panel.size.y
	check(is_equal_approx(dialogue.panel.position.y, expected_y) and dialogue.portrait.visible and dialogue.visible, label + "：滑入期间达标也完整展开")

func confirm(dialogue: Node) -> void:
	await ready_to_confirm(dialogue)
	await click(dialogue.confirm_button)

func enter_step(controller: Node, id: String) -> void:
	for index in range(controller._steps.size()):
		if controller._steps[index].id == id:
			controller.step_index = index
			controller._enter_step()
			return
	check(false, "步骤存在：" + id)

func _run() -> void:
	check(OS.get_user_data_dir().contains("space-confirm-test"), "必须使用隔离APPDATA")
	if failures > 0:
		quit(1)
		return
	root.get_node("BackgroundMusic").stop_music()
	var game: Node = load("res://scenes/game/star_map_demo.tscn").instantiate()
	root.add_child(game)
	current_scene = game
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
	dialogue.dialogue_finished.connect(func(data: Dictionary): finished.append(str(data.get("text", ""))))

	# 场景节点真实存在；普通消息仍自动结束，无需确认。
	var scene: Node = load("res://scenes/ui/dialogue_window.tscn").instantiate()
	var editor_button: Button = scene.get_node("Root/Panel/Margin/Content/Message/Confirm")
	check(editor_button.visible and editor_button.disabled, "确认按钮在场景编辑器可见且默认禁用")
	scene.free()
	dialogue.enqueue_dialogue({"text": "普通消息", "duration": 0.02})
	var deadline := Time.get_ticks_msec() + 2000
	while dialogue.pending_count() > 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(finished == ["普通消息"] and not dialogue.confirm_button.visible, "普通对话保持自动结束")

	# 快进接口只影响匹配的当前确认消息，不结束、不清队列、不绕过滑出。
	var isolated: Node = load("res://scenes/ui/dialogue_window.tscn").instantiate()
	root.add_child(isolated)
	isolated.set_process(false)
	var interface_finished := [0]
	isolated.dialogue_finished.connect(func(_data: Dictionary): interface_finished[0] += 1)
	check(not isolated.complete_current_reading("tutorial_token", 7), "空闲接口拒绝")
	isolated.enqueue_dialogue({"text": "第一目标", "duration": 60, "requires_confirmation": true, "tutorial_token": 7})
	isolated.enqueue_dialogue({"text": "下一条纯说明", "duration": 60, "requires_confirmation": true, "tutorial_token": 7})
	check(not isolated.complete_current_reading("tutorial_token", 8) and not isolated.complete_current_reading("orbit_tutorial_token", 7) and not isolated.complete_current_reading("other", 7), "拒绝旧token、另一教程和非教程字段")
	check(isolated.progress.value == 0.0 and isolated.confirm_button.disabled, "拒绝匹配不改变读条")
	check(isolated.complete_current_reading("tutorial_token", 7), "滑入阶段可提前完成读条")
	check(isolated.complete_current_reading("tutorial_token", 7) and isolated.phase == isolated.Phase.WAITING_CONFIRM and isolated.progress.value == 1.0, "等待确认时重复调用幂等")
	check(interface_finished[0] == 0 and isolated.pending_count() == 2, "完成读条不发finished、不清后续队列")
	isolated.confirm_button.pressed.emit()
	check(not isolated.complete_current_reading("tutorial_token", 7) and isolated.phase == isolated.Phase.SLIDING_OUT, "已确认滑出时拒绝复活消息")
	isolated.slide_seconds = 0.0
	isolated._process(0.0)
	check(isolated.current_dialogue.text == "下一条纯说明" and isolated.progress.value == 0.0 and isolated.confirm_button.disabled and interface_finished[0] == 1, "下一条同token说明重新计时")
	isolated._process(0.0)
	check(isolated.phase == isolated.Phase.READING and isolated.complete_current_reading("tutorial_token", 7), "阅读阶段可提前完成读条")
	isolated.clear_queue()
	isolated.enqueue_dialogue({"text": "普通自动消息", "duration": 60, "tutorial_token": 7})
	check(not isolated.complete_current_reading("tutorial_token", 7) and isolated.confirm_button.disabled, "普通通知即使有token也不改变计时语义")
	isolated.free()

	# 连续消息分别计时、分别点击；禁用按钮不穿透清除选船或改写油门。
	game._select_target(game.ships[0])
	game._set_throttle(0.3)
	var throttle: float = game.ship.thrust_throttle
	dialogue.enqueue_dialogue({"text": "第一条", "duration": 0.18, "requires_confirmation": true})
	dialogue.enqueue_dialogue({"text": "第二条", "duration": 0.12, "requires_confirmation": true})
	await click(dialogue.confirm_button)
	check(dialogue.confirm_button.disabled and finished == ["普通消息"] and dialogue.current_dialogue.text == "第一条", "计时期间真实点击不能确认")
	check(game.selected and game.ship.thrust_throttle == throttle, "禁用确认按钮点击不穿透航行")
	await ready_to_confirm(dialogue)
	for index in range(8):
		await process_frame
	check(dialogue.current_dialogue.text == "第一条" and dialogue.pending_count() == 2 and finished.size() == 1, "计时结束不自动消失或推进下一条")
	await click(dialogue.confirm_button)
	check(dialogue.current_dialogue.text == "第二条" and dialogue.confirm_button.disabled and finished.back() == "第一条", "点击只推进一条，下一条重新计时禁用")
	check(game.selected and game.ship.thrust_throttle == throttle, "启用确认按钮点击不穿透航行")
	await confirm(dialogue)
	check(dialogue.pending_count() == 0 and finished.back() == "第二条", "第二条必须独立点击确认")

	# 目标操作保留长计时，以证明可确认来自达标，而不是等待计时结束。
	for controller: Node in [city, orbit]:
		for config_step: Dictionary in controller._steps:
			if config_step.kind not in ["message", "complete"]:
				config_step.duration = 600.0
	# 行星教程（第一课）：速度、稳定资格、实际入轨均可先达成，待确认后才能继续。
	progression.start_new_game()
	check(dialogue.phase == dialogue.Phase.SLIDING_IN and dialogue.confirm_button.disabled, "行星观察前仍在滑入且不可确认")
	check(orbit.current_step_id() == "observe", "新游戏先进入行星观察步骤")
	await confirm(dialogue)
	check(orbit.current_step_id() == "orbit_physics", "观察确认后进入轨道物理科普")
	await confirm(dialogue)
	check(orbit.current_step_id() == "thrust", "科普确认后进入切向加速")
	game.ship.flight_velocity = game.ship.flight_velocity.normalized() * orbit._target_speed
	orbit._on_simulation_step(game.ship)
	check(orbit.current_step_id() == "thrust" and orbit._objective_done, "行星速度先达成不越过消息")
	check_goal_ready(dialogue, "行星加速")
	await confirm(dialogue)
	check(orbit.current_step_id() == "coast", "行星速度确认后继续")
	var stable_steps := 0
	while not game.ship.stay_available and stable_steps < 4000:
		game.accumulator = 0.0
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)
		stable_steps += 1
	check(game.ship.stay_available and stable_steps < 4000, "真实积分取得有效稳定轨道资格")
	orbit._on_simulation_step(game.ship)
	check(orbit.current_step_id() == "coast" and orbit._objective_done, "稳定资格先达成不越过消息")
	check_goal_ready(dialogue, "行星稳定")
	await confirm(dialogue)
	check(orbit.current_step_id() == "confirm", "稳定资格确认后继续")
	game._confirm_arrival(orbit.target_planet)
	orbit._process(0.0)
	check(orbit.current_step_id() == "confirm" and game.ship.voyage_finished, "实际入轨先达成不越过消息")
	check_goal_ready(dialogue, "实际入轨")
	await confirm(dialogue)
	check(orbit.current_step_id() == "completed" and progression.stage == progression.Stage.ORBIT, "入轨消息确认后显示完成消息")
	await ready_to_confirm(dialogue)
	check(progression.stage == progression.Stage.ORBIT, "行星完成消息计时结束仍不切城市")
	await click(dialogue.confirm_button)
	check(progression.stage == progression.Stage.CITY and city.current_step_id() == "select_ship", "行星完成确认才切城市")

	# 城市选船、加速和减速先达成时保留结果，不清掉当前消息。
	game._select_target(game.ships[0])
	check(city.current_step_id() == "select_ship" and city._objective_done, "选船先达成不越过消息")
	check_goal_ready(dialogue, "真实选船")
	await confirm(dialogue)
	check(city.current_step_id() == "accelerate", "选船确认后使用已达成结果")
	check(dialogue.phase == dialogue.Phase.READING and dialogue.progress.value < 1.0 and dialogue.confirm_button.disabled, "下一操作消息不会继承选船达标")
	game.ship.flight_velocity = game.ship.heading * 19.0
	game._start_thrust(1.0)
	game.accumulator = 0.0
	game._physics_process(0.5)
	check(city.current_step_id() == "accelerate" and city._objective_done and game.ship.manual_thrust == 0.0, "真实加速先达标收油但不推进消息")
	check_goal_ready(dialogue, "真实加速20m/s")
	await confirm(dialogue)
	check(city.current_step_id() == "coast", "加速消息确认后保留达标结果")
	check(dialogue.progress.value < 1.0 and dialogue.confirm_button.disabled, "纯惯性说明仍重新计时，不继承加速达标")
	await confirm(dialogue)
	game.ship.flight_velocity = Vector2.ZERO
	city._on_simulation_step(game.ship)
	check(city.current_step_id() == "brake" and city._objective_done, "停稳先达成不越过消息")
	check_goal_ready(dialogue, "减速停稳")
	await confirm(dialogue)
	check(city.current_step_id() == "fuel", "停稳消息确认后保留达标结果")

	# 泊船资格早于正文确认时，补充消息排队而不是覆盖当前消息。
	enter_step(city, "dock")
	game.ship.flight_position = city.target_city.get_dock_position()
	game.ship.flight_velocity = Vector2.ZERO
	city._on_simulation_step(game.ship)
	check(dialogue.current_dialogue.get("id") == "dock" and dialogue.pending_count() == 2, "泊船资格补充提示不覆盖待确认正文")
	check_goal_ready(dialogue, "取得泊船资格正文")
	await confirm(dialogue)
	check(city.current_step_id() == "dock" and dialogue.current_dialogue.text == city._config.dock_ready.text and not city._message_done, "首条确认后补充提示仍独立等待")
	check(dialogue.progress.value < 1.0 and dialogue.confirm_button.disabled, "只有资格不能提前完成实际泊船补充说明")
	await confirm(dialogue)
	check(city.current_step_id() == "dock" and city._message_done, "两条全部确认后仍等待实际泊船")

	# 实际泊船可完成队列中的对应补充目标，但仍逐条确认。
	var before_dock: Dictionary = root.get_node("SaveManager").make_snapshot(game)
	city._dock_prompted = false
	enter_step(city, "dock")
	city._config.dock_ready.duration = 600.0
	city._on_simulation_step(game.ship)
	game._dock_city(city.target_city)
	city._process(0.0)
	check_goal_ready(dialogue, "实际泊船正文")
	await confirm(dialogue)
	check(city.current_step_id() == "dock" and dialogue.current_dialogue.get("id") == "dock_ready", "泊船后仍保留队列补充说明，不自动跨步")
	check_goal_ready(dialogue, "实际泊船后的队列补充说明")
	check(root.get_node("SaveManager").restore_snapshot(game, before_dock), "队列泊船专项后恢复未泊船状态")

	# 返港期间先泊船，也必须等当前消息确认后再进入港口界面介绍。
	city._steps[11].duration = 600.0
	enter_step(city, "return_port")
	game.ship.flight_position = city.target_city.get_dock_position()
	game.ship.flight_velocity = Vector2.ZERO
	game._dock_city(city.target_city)
	city._process(0.0)
	check(city.current_step_id() == "return_port" and game.get_node("PortController").active, "提前泊船不越过当前消息")
	check_goal_ready(dialogue, "返港提前实际泊船")
	await confirm(dialogue)
	check(city.current_step_id() == "port_events" and progression.stage == progression.Stage.CITY, "确认返港消息后进入港口事件页介绍，不切图")
	await confirm(dialogue)
	check(city.current_step_id() == "port_people", "事件页介绍确认后进入人物页介绍")
	await confirm(dialogue)
	check(city.current_step_id() == "port_shipyard", "人物页介绍确认后进入船坞页介绍")
	await confirm(dialogue)
	check(city.current_step_id() == "port_depart", "船坞页介绍确认后进入起航说明")
	await confirm(dialogue)
	check(city.current_step_id() == "completed" and progression.stage == progression.Stage.CITY, "起航说明确认后显示完成消息，不切图")
	await ready_to_confirm(dialogue)
	check(progression.stage == progression.Stage.CITY, "城市完成消息计时结束仍不切世界")
	await click(dialogue.confirm_button)
	check(progression.stage == progression.Stage.WORLD, "城市完成确认才切世界")

	# 同一个共享按钮仅一个订阅，一次真实点击只能跳当前活动阶段。
	progression.start_new_game()
	check(skip.pressed.get_connections().size() == 1 and skip.text == "跳过行星教学", "共享Skip只有编排器一个订阅并明确阶段")
	await click(skip)
	check(progression.stage == progression.Stage.CITY and orbit.skipped and city.active and not city.skipped, "一次行星Skip只进入城市，不连跳世界")
	check(skip.text == "跳过城市教学", "城市阶段更新跳过文案")
	await click(skip)
	check(progression.stage == progression.Stage.WORLD and city.skipped and not city.active and not orbit.active, "第二次城市Skip才进入世界")
	root.get_node("UIClickSound").stop()
	game.queue_free()
	await process_frame
	print("TUTORIAL_CONFIRMATION_TEST: %s (%d checks, %d failures); isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", checks, failures, OS.get_user_data_dir()])
	quit(0 if failures == 0 else 1)
