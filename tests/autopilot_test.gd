extends SceneTree
## 场景输入与独立物理边界回归；每段推进均有预算，循环内不重复输出失败。
var failures := 0
var checks := 0
var game: Node2D
var vessel: Node2D
var dial: Control
var view: Node2D
const START := Vector2(0, -2000000)

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func step() -> void:
	game._physics_process(game.SIM_STEP / game.TIME_SCALE)

func click(pos: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.position = pos
		event.pressed = pressed
		root.push_input(event, true)

func world_to_screen(meters: Vector2) -> Vector2:
	return game.get_canvas_transform() * game.get_node("World").to_global(game._to_screen(meters))

func screen_to_world(pixel: Vector2) -> Vector2:
	var point: Vector2 = game.get_node("World").to_local(game.get_canvas_transform().affine_inverse() * pixel)
	return (point - game._screen_center()) / game._view_scale()

func safe_world_click(pixel: Vector2) -> bool:
	var safe: bool = root.get_visible_rect().has_point(pixel)
	for path in ["HUD/Root/ThrustDial", "HUD/Root/FlightPanel", "HUD/Root/BottomActions", "HUD/Root/FleetBar", "StarMapView/HUD/Root/NavigationButtons"]:
		var control := game.get_node(path) as Control
		if control.is_visible_in_tree() and control.get_global_rect().has_point(pixel):
			safe = false
	check(safe, "右键必须处于可见视口且不被HUD覆盖：%s" % pixel)
	return safe

func focus_ship(map_mode: bool = false, zoom_value: float = 0.8) -> void:
	view.set_map_mode(map_mode)
	var camera := game.get_node("NavigationCamera")
	camera.zoom_level = zoom_value
	camera.zoom = Vector2.ONE * zoom_value
	view._return_to_ship()
	camera.following = false
	camera.force_update_scroll()
	game._sync_visuals()

func prepare(velocity: Vector2 = Vector2.ZERO, map_mode: bool = false) -> void:
	game._stop_autopilot()
	game._stop_thrust()
	game.simulation_paused = false
	game.tutorial_pause = false
	game.simulation_speed = 1.0
	game.accumulator = 0.0
	# 长预算动力回归不重复计算完整预览；预览另用单步一致性断言。
	game.preview_refresh_elapsed = -1000000.0
	vessel.flight_position = START
	vessel.flight_velocity = velocity
	vessel.heading = velocity.normalized() if velocity.length() > 0.01 else Vector2.RIGHT
	vessel.fuel = vessel.get_fuel_capacity()
	vessel.crashed = false
	vessel.voyage_finished = false
	vessel.autopilot_max_speed = 500.0
	game._select_target(vessel, false)
	focus_ship(map_mode)
	game._update_ui()
	dial.sync_state()

func arm() -> void:
	game._update_ui()
	dial.sync_state()
	var button := dial.get_node("Layout/AutoPilot") as Button
	check(button.is_visible_in_tree() and not button.disabled, "无重力区自动驾驶按钮可操作")
	var pixel := button.get_global_rect().get_center()
	check(root.get_visible_rect().has_point(pixel), "自动驾驶按钮位于可见视口")
	click(pixel)
	check(vessel.autopilot_enabled and not vessel.autopilot_active, "真实点击按钮进入待命而非立即执行")

func set_target(target: Vector2) -> void:
	var pixel := world_to_screen(target)
	if not safe_world_click(pixel):
		return
	var before_position: Vector2 = vessel.flight_position
	var before_velocity: Vector2 = vessel.flight_velocity
	click(pixel, MOUSE_BUTTON_RIGHT)
	check(vessel.autopilot_active, "待命或执行中真实右键开始导航")
	check(vessel.autopilot_target.distance_to(target) <= 1.0, "完整画布变换后的目标正确：%s / %s" % [vessel.autopilot_target, target])
	check(vessel.flight_position == before_position and vessel.flight_velocity == before_velocity, "设点不瞬移、不重置速度")
	check(game.get_node("World/AutopilotMarker").visible, "执行时显示导航标记")

func navigate(label: String, target: Vector2, budget: int = 6000) -> void:
	var count := 0
	var bounded := true
	var finite := true
	while vessel.autopilot_active and count < budget:
		var before_velocity: Vector2 = vessel.flight_velocity
		var before_position: Vector2 = vessel.flight_position
		var before_fuel: float = vessel.fuel
		step()
		count += 1
		finite = finite and vessel.flight_position.is_finite() and vessel.flight_velocity.is_finite() and is_finite(vessel.fuel)
		var acceleration: float = maxf(vessel.get_effective_acceleration(), vessel.get_effective_deceleration())
		bounded = bounded and before_velocity.distance_to(vessel.flight_velocity) <= acceleration * game.SIM_STEP + 0.15
		bounded = bounded and before_position.distance_to(vessel.flight_position) <= maxf(before_velocity.length(), vessel.flight_velocity.length()) * game.SIM_STEP + 1.0
		bounded = bounded and vessel.fuel >= 0.0 and vessel.fuel <= before_fuel + 0.001
	check(finite and bounded, "%s：每步有限、推力有界、无瞬移、耗油单调" % label)
	check(not vessel.autopilot_active and count < budget, "%s：预算内结束，步数%d，剩余%.3fm，速度%.3f" % [label, count, vessel.flight_position.distance_to(target), vessel.flight_velocity.length()])
	check(vessel.flight_position.distance_to(target) <= 2.0 and vessel.flight_velocity.length() <= 0.1, "%s：同时满足位置和速度容差" % label)
	check(vessel.fuel > 0.0 and not vessel.crashed, "%s：不得用燃尽或损毁冒充到达" % label)
	check(vessel.autopilot_enabled and not vessel.autopilot_active, "%s：到达后返回自动待命" % label)
	var stopped_position: Vector2 = vessel.flight_position
	step()
	step()
	check(vessel.flight_velocity == Vector2.ZERO and vessel.flight_position == stopped_position and not vessel.autopilot_active, "%s：到达后额外两步保持停船" % label)
	print("AUTOPILOT_SCENARIO: %s steps=%d distance=%.3f speed=%.3f" % [label, count, vessel.flight_position.distance_to(target), vessel.flight_velocity.length()])

func wait_phase(phase: int, budget: int = 2500) -> void:
	var count := 0
	while vessel.autopilot_active and vessel.autopilot_phase != phase and count < budget:
		step()
		count += 1
	check(vessel.autopilot_active and vessel.autopilot_phase == phase, "预算内进入相位%d（%d步）" % [phase, count])

func submit_speed(text: String, enter: bool = true) -> void:
	var input := dial.get_node("Layout/MaxSpeed") as SpinBox
	var edit := input.get_line_edit()
	click(edit.get_global_rect().get_center())
	check(edit.has_focus(), "真实点击限速输入获得焦点")
	edit.select_all()
	var value := InputEventKey.new()
	value.pressed = true
	value.ctrl_pressed = true
	value.keycode = KEY_A
	root.push_input(value, true)
	for character in text:
		var event := InputEventKey.new()
		event.pressed = true
		event.unicode = character.unicode_at(0)
		root.push_input(event, true)
	check(edit.text == text, "通过真实键盘事件编辑限速：%s / %s" % [edit.text, text])
	if enter:
		var event := InputEventKey.new()
		event.pressed = true
		event.keycode = KEY_ENTER
		root.push_input(event, true)
	else:
		click(dial.get_node("Layout/Title").get_global_rect().get_center())
	await process_frame
	await process_frame

func _run() -> void:
	check(OS.get_user_data_dir().contains("space-autopilot"), "必须使用专用隔离APPDATA，禁止访问玩家存档")
	if failures > 0:
		quit(1)
		return
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	root.get_node("BackgroundMusic").stop_music()
	root.get_node("UIClickSound").stream = null
	game = load("res://scenes/game/main.tscn").instantiate()
	game.allow_builtin_map = false
	root.add_child(game)
	game.set_physics_process(false)
	for unused in range(3):
		await process_frame
	dial = game.get_node("HUD/Root/ThrustDial")
	view = game.get_node("StarMapView")
	vessel = game.ship
	if dial.get_node_or_null("Layout/AutoPilot") == null:
		check(false, "产品接口未就绪：Layout/AutoPilot不存在")
		print("AUTOPILOT_TEST: FAIL checks=%d failures=%d" % [checks, failures])
		quit(1)
		return

	# A：真实按钮进入待命，未待命右键不能偷偷启动。
	prepare()
	await process_frame
	set_target_without_mode()
	arm()
	var position_before: Vector2 = vessel.flight_position
	var fuel_before: float = vessel.fuel
	for unused in range(20):
		step()
	check(vessel.flight_position == position_before and vessel.flight_velocity == Vector2.ZERO and vessel.fuel == fuel_before, "零速待命不移动不耗油")
	check(dial.get_node("Layout/MaxSpeed").visible and not dial.get_node("Layout/Throttle").visible, "待命显示限速并隐藏手动油门")
	set_target(START + Vector2(0, -50000))
	navigate("真实近域零速起航", START + Vector2(0, -50000))

	# B：实际主循环的横向、反向和超限初速；不直接写active/phase。
	for velocity in [Vector2(500, 0), Vector2(0, 500), Vector2(0, -900)]:
		prepare(velocity)
		await process_frame
		arm()
		set_target(START + Vector2(0, -50000))
		navigate("初速%s" % velocity, START + Vector2(0, -50000))
	prepare(Vector2.ZERO, true)
	await process_frame
	arm()
	set_target(START + Vector2(0, -50000))
	navigate("真实星图零速起航", START + Vector2(0, -50000))

	# C：加速、巡航、减速时分别转向与反向改目标。
	for phase in [0, 1, 2]:
		for direction in [Vector2.RIGHT, Vector2.DOWN]:
			prepare()
			await process_frame
			arm()
			set_target(START + Vector2(0, -50000))
			if phase == 0:
				for unused in range(30):
					step()
			else:
				wait_phase(phase)
			focus_ship(false, 0.6)
			var target: Vector2 = vessel.flight_position + direction * 50000.0
			set_target(target)
			navigate("相位%d换点%s" % [phase, direction], target)

	# D：真实焦点输入提交，降低巡航限速必须改变实飞速度。
	prepare()
	await process_frame
	arm()
	set_target(START + Vector2(0, -70000))
	wait_phase(1)
	await submit_speed("100", false)
	check(absf(vessel.autopilot_max_speed - 100.0) < 0.01, "点外提交限速100")
	var velocity_before: Vector2 = vessel.flight_velocity
	step()
	check(vessel.flight_velocity.length() < velocity_before.length() and vessel.flight_velocity.distance_to(velocity_before) <= vessel.get_effective_deceleration() * game.SIM_STEP + 0.01, "降低限速立即渐进减速而非瞬间钳速")
	for unused in range(220):
		step()
	check(vessel.flight_velocity.length() <= 100.1, "降速后实际速度满足新限速")
	await submit_speed("0")
	check(is_finite(vessel.autopilot_max_speed) and vessel.autopilot_max_speed > 0.0, "零限速被拒绝或修正为正值")
	await submit_speed("-20")
	check(is_finite(vessel.autopilot_max_speed) and vessel.autopilot_max_speed > 0.0, "负限速被拒绝或修正为正值")
	await submit_speed("800")
	check(absf(vessel.autopilot_max_speed - 800.0) < 0.01, "回车提交合法限速800")

	# E：精确数值用例仍经过主循环，但小于船按钮的目标使用产品设点API。
	for distance in [3.0, 53.0, 65.0, 78.0, 127.0]:
		prepare()
		await process_frame
		arm()
		var target := START + Vector2(distance, 0)
		game._set_autopilot_target(target)
		navigate("短程%.0fm零速" % distance, target, 2000)
	for offset in [Vector2(53, -53), Vector2(65, -65), Vector2(78, -78)]:
		prepare()
		await process_frame
		arm()
		var target: Vector2 = START + offset
		game._set_autopilot_target(target)
		navigate("远坐标斜向%s" % offset, target, 2000)
	prepare(Vector2(500, 0))
	await process_frame
	arm()
	game._set_autopilot_target(START + Vector2(1, 0))
	step()
	check(vessel.flight_velocity.length() >= 500.0 - vessel.get_effective_deceleration() * game.SIM_STEP - 0.1, "目标1m但速度500不能吸附抹速")
	check(vessel.flight_position.distance_to(START + Vector2(1, 0)) > 2.0, "高速近点先越过制动，不瞬移到目标")
	navigate("高速近点制动后重返", START + Vector2(1, 0))
	prepare(Vector2(200, 0))
	await process_frame
	arm()
	set_target(START + Vector2(50000, 0))
	vessel.fuel = 0.01
	velocity_before = vessel.flight_velocity
	step()
	check(not vessel.autopilot_active and not vessel.autopilot_enabled, "燃尽退出自动模式")
	check(vessel.flight_velocity.length() > 199.0 and vessel.flight_velocity.distance_to(velocity_before) < 1.0, "燃尽保留惯性动量而非清零")
	position_before = vessel.flight_position
	velocity_before = vessel.flight_velocity
	step()
	check(vessel.flight_velocity.distance_to(velocity_before) < 0.001 and vessel.flight_position.distance_to(position_before) > 40.0, "燃尽后一物理步持续惯性漂移")

	# F：可见鼠标完整坐标链，包括World非恒等变换。
	for map_mode in [false, true]:
		for zoom_value in [0.025, 1.0, 4.0]:
			prepare(Vector2.ZERO, map_mode)
			game.get_node("World").position = Vector2(37, -19)
			focus_ship(map_mode, zoom_value)
			await process_frame
			arm()
			var pixel := Vector2(420, 240)
			var target := screen_to_world(pixel)
			check(world_to_screen(target).distance_to(pixel) < 0.05, "完整坐标正逆变换可逆")
			set_target(target)
		game.get_node("World").position = Vector2.ZERO

	root.size = Vector2i(960, 540)
	await process_frame
	prepare()
	await process_frame
	arm()
	var narrow_pixel := Vector2(350, 180)
	set_target(screen_to_world(narrow_pixel))
	root.size = Vector2i(1200, 720)
	await process_frame

	# 预览与真实物理步必须一致，但不能替代上述独立动力约束。
	prepare(Vector2(300, 100), true)
	await process_frame
	arm()
	set_target(START + Vector2(0, -50000))
	game._refresh_preview()
	game._advance_preview_job(1)
	var predicted_position: Vector2 = game.preview_job.position
	var predicted_velocity: Vector2 = game.preview_job.velocity
	var predicted_fuel: float = game.preview_job.fuel
	step()
	check(vessel.flight_position.distance_to(predicted_position) <= 0.25 and vessel.flight_velocity.distance_to(predicted_velocity) < 0.001 and absf(vessel.fuel - predicted_fuel) < 0.001, "矢量自动驾驶预览单步与实飞一致")

	# G/H：逐source判定不允许相反引力抵消伪装真空，存档恢复不残留旧执行态。
	prepare()
	await process_frame
	arm()
	set_target(START + Vector2(0, -50000))
	var original_planets: Array = game.planets.duplicate()
	var original_cities: Array = game.cities.duplicate()
	game.planets.clear()
	game.cities.clear()
	var sources: Array[Node2D] = []
	for direction in [Vector2.LEFT, Vector2.RIGHT]:
		var source = load("res://scenes/world/planet.tscn").instantiate()
		game.get_node("World").add_child(source)
		source.radius_m = 1000.0
		source.field_height_m = 0.0
		source.surface_gravity = 10.0
		source.max_gravity_radius_m = 200000.0
		source.flight_position = START + direction * 100000.0
		if not game.planets.has(source):
			game.planets.append(source)
		sources.append(source)
	check(game._gravity_at(START).length() < 0.000001 and sources[0].acceleration_at(START).length() > 0.0, "对称双源构造净引力抵消但各源有效")
	step()
	check(not vessel.autopilot_enabled and not vessel.autopilot_active, "逐source重力禁用自动模式，不按净合力抵消判断")
	dial.sync_state()
	check(not dial.get_node("Layout/AutoPilot").visible, "引力互相抵消时仍隐藏自动驾驶入口")
	game._toggle_autopilot_mode()
	check(not vessel.autopilot_enabled, "逐source重力区内不能通过API开启待命")
	game.planets.clear()
	game.cities.assign(original_cities)
	for source in original_planets:
		game.planets.append(source)
	for source in sources:
		source.queue_free()
	await process_frame
	prepare()
	await process_frame
	arm()
	set_target(START + Vector2(0, -50000))
	var manager := root.get_node("SaveManager")
	var snapshot: Dictionary = manager.make_snapshot(game)
	game._set_autopilot_target(START + Vector2(50000, 0))
	check(manager.restore_snapshot(game, snapshot), "合法容量燃料的快照恢复成功")
	await process_frame
	check(not vessel.autopilot_active and not vessel.autopilot_enabled, "恢复采用安全取消策略，不残留旧执行目标")
	check(not game.get_node("World/AutopilotMarker").visible and not dial.get_node("Layout/MaxSpeed").visible, "恢复后仪表与标记和手动模式一致")
	var cold = load("res://scenes/game/main.tscn").instantiate()
	cold.allow_builtin_map = false
	root.add_child(cold)
	cold.set_physics_process(false)
	for unused in range(3):
		await process_frame
	check(manager.restore_snapshot(cold, snapshot), "新场景冷恢复同一合法快照")
	check(not cold.ship.autopilot_enabled and not cold.ship.autopilot_active, "冷恢复和热恢复均安全取消自动模式")
	cold.queue_free()
	await process_frame
	game.get_node("NavigationCamera").make_current()

	prepare()
	await process_frame
	arm()
	set_target(START + Vector2(0, -50000))
	var cancel := dial.get_node("Layout/CancelAutopilot") as Button
	click(cancel.get_global_rect().get_center())
	check(not vessel.autopilot_enabled and not vessel.autopilot_active, "真实取消按钮退出两态")
	prepare(Vector2(50, 0))
	await process_frame
	arm()
	set_target(START + Vector2(0, -50000))
	velocity_before = vessel.flight_velocity
	position_before = vessel.flight_position
	fuel_before = vessel.fuel
	game._toggle_pause()
	step()
	check(game.simulation_paused and vessel.autopilot_enabled and vessel.autopilot_active and vessel.flight_velocity == velocity_before and vessel.flight_position == position_before and vessel.fuel == fuel_before, "普通暂停保留模式和执行任务，冻结位置、动量和燃料")
	game._toggle_pause()
	step()
	check(not game.simulation_paused and vessel.autopilot_enabled and vessel.autopilot_active and vessel.flight_position.distance_to(position_before) > 0.1 and vessel.fuel < fuel_before, "解除普通暂停后继续原自动导航并正常耗油")
	prepare(Vector2(50, 0))
	await process_frame
	arm()
	set_target(START + Vector2(0, -50000))
	velocity_before = vessel.flight_velocity
	game.set_tutorial_pause(true)
	step()
	check(not vessel.autopilot_enabled and vessel.flight_velocity == velocity_before, "教学暂停退出模式且不改变动量")
	game.set_tutorial_pause(false)
	prepare()
	await process_frame
	arm()
	game._reset()
	check(not vessel.autopilot_enabled and not vessel.autopilot_active and not game.get_node("World/AutopilotMarker").visible, "重置清理两态与导航标记")
	game.queue_free()
	await process_frame
	print("AUTOPILOT_TEST: %s checks=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)

func set_target_without_mode() -> void:
	var pixel := world_to_screen(START + Vector2(0, -50000))
	if safe_world_click(pixel):
		click(pixel, MOUSE_BUTTON_RIGHT)
	check(not vessel.autopilot_active and not vessel.autopilot_enabled, "手动模式右键不启动自动驾驶")
