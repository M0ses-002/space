extends SceneTree
## 隔离用户目录，使用真实推进提交、鼠标/键盘事件与存档恢复验证教学暂停。
var checks := 0
var failures := 0
var propulsion_count := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func pointer(control: Control, pressed: bool) -> void:
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	Input.flush_buffered_events()
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.pressed = pressed
	root.push_input(event, true)
	Input.flush_buffered_events()
	await process_frame

func click(control: Control) -> void:
	await pointer(control, true)
	await pointer(control, false)

func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	root.push_input(event, true)
	Input.flush_buffered_events()
	await process_frame

func confirm(dialogue: Node, behind_menu: bool = false) -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while dialogue.phase != dialogue.Phase.WAITING_CONFIRM and Time.get_ticks_msec() < deadline:
		await process_frame
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM, "消息倒计时后仍需手动确认")
	if behind_menu:
		# ESC遮罩本就不允许鼠标操作底层对话；直接触发确认信号验证状态持有顺序。
		dialogue.confirm_button.pressed.emit()
		await process_frame
	else:
		await click(dialogue.confirm_button)

func check_goal_ready(dialogue: Node, label: String) -> void:
	check(dialogue.phase == dialogue.Phase.WAITING_CONFIRM and dialogue.progress.value == 1.0 and not dialogue.confirm_button.disabled, label + "立即填满读条且可确认")
	check(float(Time.get_ticks_usec() - dialogue._phase_started_usec) / 1000000.0 < dialogue._reading_seconds, label + "未等原计时结束")

func step(game: Node, count: int = 1) -> void:
	for index in range(count):
		game._physics_process(game.SIM_STEP / game.TIME_SCALE)

func enter(controller: Node, id: String) -> void:
	for index in range(controller._steps.size()):
		if controller._steps[index].id == id:
			controller.step_index = index
			controller._enter_step()
			return
	check(false, "目标步骤存在：" + id)

func frozen_inputs(game: Node, label: String) -> void:
	var vessel: Node = game.ship
	var position: Vector2 = vessel.flight_position
	var velocity: Vector2 = vessel.flight_velocity
	var fuel: float = vessel.fuel
	var direction: Vector2 = vessel.thrust_direction
	var locked: bool = vessel.thrust_lock_enabled
	var lock_angle: float = vessel.thrust_lock_angle
	var committed := propulsion_count
	var dial: Node = game.get_node("HUD/Root/ThrustDial")
	game._update_ui()
	dial.sync_state()
	check(game.tutorial_pause and game.simulation_paused and game.accumulator == 0.0, label + "教学暂停并丢弃积算余量")
	check(game.accelerate_button.disabled and game.brake_button.disabled and not dial.slider.editable and not dial.angle_input.editable and dial.angle_lock.disabled, label + "飞行按钮和仪表只读")
	await click(game.accelerate_button)
	await key(KEY_SPACE, true)
	step(game, 8)
	await key(KEY_SPACE, false)
	await click(dial.slider)
	dial.slider.value = dial.slider.max_value
	dial.angle_input.value = 90.0
	dial.angle_lock.toggled.emit(not locked)
	dial.acceleration_input.value = dial.acceleration_input.max_value
	game._start_thrust(1.0)
	game._start_thrust(-1.0)
	game._set_throttle(1.0)
	game._set_thrust_direction(direction.rotated(0.8))
	game._set_thrust_lock(not locked)
	game._toggle_pause()
	game._physics_process(10.0)
	check(vessel.flight_position == position and vessel.flight_velocity == velocity and vessel.fuel == fuel and propulsion_count == committed, label + "再次点击/键盘/滑条不移动、不耗油、不提交推进")
	check(vessel.manual_thrust == 0.0 and not vessel.steering and vessel.thrust_throttle == 0.0 and vessel.thrust_direction == direction and vessel.thrust_lock_enabled == locked and vessel.thrust_lock_angle == lock_angle, label + "不积累隐藏油门方向或锁定")
	game.get_viewport().gui_release_focus()
	await key(KEY_ESCAPE, true)
	await key(KEY_ESCAPE, false)
	var menu: Node = game.get_node("PauseMenu")
	check(menu.is_open() and game.tutorial_pause, label + "ESC菜单可打开")
	await click(menu.continue_button)
	check(not menu.is_open() and game.simulation_paused and game.tutorial_pause, label + "继续游戏不绕过教学暂停")

func _run() -> void:
	check(OS.get_user_data_dir().contains("space-tutorial-pause-test"), "测试必须隔离APPDATA")
	if failures:
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
	var city: Node = game.get_node("TutorialController")
	var orbit: Node = game.get_node("OrbitTutorialController")
	var progression: Node = game.get_node("ProgressionManager")
	var dialogue: Node = game.get_node("DialogueWindow")
	var menu: Node = game.get_node("PauseMenu")
	var dial: Node = game.get_node("HUD/Root/ThrustDial")
	city.duration_scale = 0.003
	orbit.duration_scale = 0.003
	for controller: Node in [city, orbit]:
		for config_step: Dictionary in controller._steps:
			if config_step.kind not in ["message", "complete"]:
				config_step.duration = 60000.0
	dialogue.slide_seconds = 0.0
	game.propulsion_committed.connect(func(_ship: Node2D, delta_v: float, source: StringName):
		if delta_v > 0.0 and source in [&"manual_button", &"directional_thrust"]:
			propulsion_count += 1
	)
	progression.start_new_game()
	await process_frame
	check(orbit.active and orbit.current_step_id() == "observe", "新游戏先进入行星观察")
	await confirm(dialogue)
	check(orbit.current_step_id() == "orbit_physics", "观察确认后进入轨道物理科普")
	await confirm(dialogue)
	check(orbit.current_step_id() == "thrust" and not game.tutorial_pause and not game.simulation_paused, "行星未完成加速步骤可正常运行")
	game.ship.flight_velocity = game.ship.flight_velocity.normalized() * (orbit._target_speed * orbit.THRUST_TARGET_SPEED_FACTOR - 0.5)
	var committed := propulsion_count
	await pointer(game.accelerate_button, true)
	game._physics_process(0.5)
	await pointer(game.accelerate_button, false)
	check(propulsion_count > committed and orbit.current_step_id() == "thrust" and orbit._objective_done, "行星真实推进达标仍等本步手动确认")
	check_goal_ready(dialogue, "行星真实加速：")
	await frozen_inputs(game, "行星加速：")
	var snapshot: Dictionary = save.make_snapshot(game)
	check(save.restore_snapshot(game, snapshot) and orbit._objective_done and game.tutorial_pause, "行星达标读档保留等待暂停")
	check_goal_ready(dialogue, "行星达标读档：")
	await confirm(dialogue)
	check(orbit.current_step_id() == "coast" and not game.tutorial_pause and not game.simulation_paused, "行星确认加速后按coast配置恢复模拟")
	snapshot = save.make_snapshot(game)
	check(save.restore_snapshot(game, snapshot) and not game.simulation_paused and not game.tutorial_pause, "行星未达标运行步骤读档不会误固化暂停")
	var stable_steps := 0
	while not orbit._objective_done and stable_steps < 4000:
		step(game)
		stable_steps += 1
	check(orbit._objective_done and game.ship.stay_available and stable_steps < 4000, "真实轨道积分达成稳定资格")
	check_goal_ready(dialogue, "行星真实稳定：")
	await frozen_inputs(game, "行星稳定：")
	await confirm(dialogue)
	check(orbit.current_step_id() == "confirm" and not game.tutorial_pause and game._can_confirm_arrival(orbit.target_planet), "确认稳定消息后恢复实际入轨操作")
	game._confirm_arrival(orbit.target_planet)
	orbit._process(0.0)
	check(orbit._objective_done and orbit.current_step_id() == "confirm" and game.ship.voyage_finished and game.tutorial_pause, "真实入轨后暂停等待本步确认")
	check_goal_ready(dialogue, "行星实际入轨：")
	game.get_node("PortController")._request_departure()
	check(game.ship.voyage_finished and game.get_node("PortController").active and game.tutorial_pause, "入轨待确认期间不能从港口起航撤销成功结果")
	await confirm(dialogue)
	check(orbit.current_step_id() == "completed" and game.tutorial_pause, "入轨确认后完成消息继续暂停")
	await confirm(dialogue)
	check(progression.stage == progression.Stage.CITY and city.active and city.current_step_id() == "select_ship", "行星完成确认进入城市选船")

	# 城市教程（第二课）：真实选船、加速与减速达标暂停。
	game._select_target(game.ships[0])
	check_goal_ready(dialogue, "真实选船：")
	await confirm(dialogue)
	check(city.current_step_id() == "accelerate" and not game.tutorial_pause, "未完成加速步骤正常恢复，不全局阻断操作")
	game.ship.flight_velocity = game.ship.heading * 15.0
	var city_committed := propulsion_count
	await pointer(game.accelerate_button, true)
	step(game)
	check(propulsion_count == city_committed + 1 and game.ship.flight_velocity.length() < 20.0 and not city._objective_done and not game.simulation_paused, "20m/s前真实鼠标长按可推进")
	game._physics_process(0.5)
	await pointer(game.accelerate_button, false)
	check(city.current_step_id() == "accelerate" and city._objective_done and game.ship.flight_velocity.length() >= 20.0 and game.ship.flight_velocity.length() < 21.0, "真实推进达标瞬间中止大帧后续物理步，仍等待本步消息确认")
	check_goal_ready(dialogue, "城市真实20m/s：")
	await frozen_inputs(game, "城市20m/s：")
	snapshot = save.make_snapshot(game)
	check(snapshot.tutorial_state.objective_done and not snapshot.tutorial_state.previous_pause, "达标待确认存档保存结果与进入前暂停状态")
	check(save.restore_snapshot(game, snapshot) and city._objective_done and game.tutorial_pause and dialogue.pending_count() == 1, "达标读档保持暂停并重播当前手动确认消息")
	check_goal_ready(dialogue, "城市达标读档：")
	await confirm(dialogue)
	check(city.current_step_id() == "coast" and game.tutorial_pause, "确认加速后下一条说明仍按配置暂停")
	await confirm(dialogue)
	check(city.current_step_id() == "brake" and not game.tutorial_pause and not game.simulation_paused and game.ship.thrust_throttle == 0.0, "确认说明后减速操作步恢复且无隐藏启动")
	await pointer(game.brake_button, true)
	step(game, 30)
	await pointer(game.brake_button, false)
	check(city.current_step_id() == "brake" and city._objective_done and game.ship.flight_velocity.length() <= 0.1, "真实减速达标停稳且等本步确认")
	check_goal_ready(dialogue, "城市真实减速：")
	await frozen_inputs(game, "城市停稳：")
	await confirm(dialogue)
	check(city.current_step_id() == "fuel" and game.tutorial_pause, "停稳确认后燃料说明仍暂停")
	await click(game.get_node("TutorialHUD/Root/Panel/Margin/Content/Skip"))
	check(progression.stage == progression.Stage.WORLD and not game.tutorial_pause and not game.simulation_paused, "城市待确认时跳过进入世界并释放教学暂停")

	# 普通暂停预设保持原功能；教学开始会清掉预设，退出恢复原暂停。
	game.simulation_paused = true
	game._set_thrust_direction(Vector2.UP)
	game._set_throttle(0.4)
	check(game.ship.steering and is_equal_approx(game.ship.thrust_throttle, 0.4), "普通暂停仍允许油门与方向预设")
	city.start_new_game()
	check(not game.ship.steering and game.ship.thrust_throttle == 0.0 and game.tutorial_previous_pause, "进入教程即清普通暂停预设并保留原暂停")
	menu.open()
	city._cancel(false)
	check(not game.tutorial_pause and game.simulation_paused and menu.was_paused, "菜单内取消恢复进入前普通暂停")
	menu.close()
	check(game.simulation_paused, "菜单关闭不吞原本暂停")
	game.simulation_paused = false
	city.start_new_game()
	game._select_target(game.ships[0])
	enter(city, "accelerate")
	game.ship.flight_velocity = game.ship.heading * 19.0
	game._start_thrust(1.0)
	step(game)
	menu.open()
	snapshot = save.make_snapshot(game)
	check(save.restore_snapshot(game, snapshot) and city._objective_done and game.tutorial_pause, "菜单内达标读档保持教学暂停")
	await confirm(dialogue, true)
	await confirm(dialogue, true)
	check(city.current_step_id() == "brake" and not game.tutorial_pause and game.simulation_paused and not menu.was_paused, "菜单内确认切操作步只释放教学暂停")
	menu.close()
	check(not game.simulation_paused, "关闭ESC后恢复该操作步")
	city._complete_objective()
	game._reset()
	check(city.active and not orbit.active and city.step_index == 0 and city.current_step_id() == "select_ship" and not game.ship.steering and game.ship.thrust_throttle == 0.0, "达标等待时重置改为重做当前课并清除暗存推力")
	city.cancel_for_reset()
	progression.start_new_game()
	await click(game.get_node("TutorialHUD/Root/Panel/Margin/Content/Skip"))
	await click(game.get_node("TutorialHUD/Root/Panel/Margin/Content/Skip"))
	check(progression.stage == progression.Stage.WORLD and not game.tutorial_pause and not game.simulation_paused, "两次分阶段skip最终释放教学暂停")
	progression.stage = progression.Stage.NONE
	city.start_new_game()
	var invalid_city: Dictionary = city.make_state()
	invalid_city.city = "World/MissingCity"
	game.simulation_paused = true
	city.restore_state(invalid_city)
	check(not city.active and not game.tutorial_pause and not game.simulation_paused, "城市读档目标失效时跳过并释放临时教学暂停")
	game.load_map_file("res://maps/plante_teach.json")
	game.simulation_paused = true
	orbit.start()
	var prior_orbit: Dictionary = orbit.make_state()
	check(prior_orbit.previous_pause, "行星状态记录进入前普通暂停")
	orbit._cancel(false)
	game.simulation_paused = false
	orbit.restore_state(prior_orbit)
	orbit._cancel(false)
	check(game.simulation_paused and not game.tutorial_pause, "行星读档后取消仍恢复进入前普通暂停")
	game.simulation_paused = false
	orbit.start()
	var invalid_orbit: Dictionary = orbit.make_state()
	invalid_orbit.planet = "World/MissingPlanet"
	game.simulation_paused = true
	orbit.restore_state(invalid_orbit)
	check(not orbit.active and not game.tutorial_pause and not game.simulation_paused, "行星读档目标失效时跳过并释放临时教学暂停")
	root.get_node("UIClickSound").stop()
	game.queue_free()
	await process_frame
	print("TUTORIAL_PAUSE_TEST: %s (%d checks, %d failures); propulsion_commits=%d; isolated_user=%s" % ["PASS" if failures == 0 else "FAIL", checks, failures, propulsion_count, OS.get_user_data_dir()])
	quit(0 if failures == 0 else 1)
