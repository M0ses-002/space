extends SceneTree
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func mouse(point: Vector2, down: bool) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	root.push_input(event, true)
func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	for source in game.planets.duplicate():
		if source != game.get_node("World/Planet"):
			source.queue_free()
	await process_frame
	game._select_ship()
	var vessel = game.ship
	var planet = game.get_node("World/Planet")
	vessel.gravity_threshold = 1000.0
	game._update_ui()
	await process_frame
	var speed: float = vessel.flight_velocity.length()
	var fuel: float = vessel.fuel
	mouse(game.accelerate_button.get_global_rect().get_center(), true)
	game._physics_process(0.1)
	check(absf(vessel.flight_velocity.length() - speed - vessel.max_acceleration * 2) < 0.01, "长按最大推力两模拟秒")
	check(absf(fuel - vessel.fuel - vessel.max_acceleration * 2 * vessel.propulsion_fuel_per_delta_v) < 0.01, "长按按实际delta_v扣油")
	mouse(Vector2(20, 300), false)
	speed = vessel.flight_velocity.length()
	game._physics_process(0.1)
	check(is_equal_approx(vessel.flight_velocity.length(), speed), "屏幕其他位置松手也停止")
	var stopped: Dictionary = game._propulsion_step(Vector2(0,-100000), Vector2(1,0), 100, .25, 1000, -10, Vector2.RIGHT, 2)
	check(stopped.velocity == Vector2.ZERO and stopped.fuel == 98, "减速不反转且只扣实际速度变化")
	var exhausted: Dictionary = game._propulsion_step(Vector2(0,-100000), Vector2(1,0), 1, .25, 1000, 10, Vector2.RIGHT, 2)
	check(exhausted.velocity == Vector2(1.5,0) and exhausted.fuel == 0, "燃料不足限制推进量")
	game._toggle_pause()
	var frozen: Vector2 = vessel.flight_position
	fuel = vessel.fuel
	game._physics_process(10)
	check(vessel.flight_position == frozen and vessel.fuel == fuel, "暂停冻结推进与耗油")
	game._toggle_pause()
	vessel.gravity_threshold = 0.0
	game._reset()
	game._select_ship()
	# 两个绕行方向均应保留。
	for direction in [-1.0, 1.0]:
		vessel.flight_position = Vector2(0,-62000)
		vessel.flight_velocity = Vector2(655 * direction,0)
		game._toggle_hover()
		check(vessel.hovering, "进入悬停")
		fuel = vessel.fuel
		game._toggle_hover()
		check(not vessel.hovering, "付费解除悬停")
		check(signf(vessel.flight_position.cross(vessel.flight_velocity)) == direction, "保留顺逆绕行方向")
		check(absf(vessel.flight_velocity.dot(vessel.flight_position.normalized())) < .01, "恢复切线速度")
		check(vessel.fuel < fuel, "瞬间解除悬停扣油")
		vessel.fuel = vessel.initial_fuel
	game._toggle_hover()
	vessel.fuel = 1
	game._toggle_hover()
	check(vessel.hovering and vessel.fuel == 1, "燃料不足不解除不扣油")
	game._reset()
	game._select_ship()
	game._begin_orbit_selection()
	check(game.simulation_paused and game.selecting_orbit, "入轨进入暂停选星")
	check(planet.get_node("OrbitHighlight").visible, "范围内行星高亮")
	await process_frame
	mouse(planet.get_global_transform_with_canvas().origin, true)
	mouse(planet.get_global_transform_with_canvas().origin, false)
	check(game.pending_target == planet, "真实鼠标点击高亮行星")
	check(game.pending_plan.get("ok", false), "初始近圆状态可规划入轨: %s" % game.pending_plan.get("reason", ""))
	if game.pending_plan.get("ok", false):
		var plan: Dictionary = game.pending_plan.duplicate(true)
		check(plan.duration > 0, "普通入轨非瞬时机动")
		var expected_position: Vector2 = vessel.flight_position
		var expected_velocity: Vector2 = vessel.flight_velocity
		var expected_fuel: float = vessel.fuel
		for command in plan.commands:
			check(command <= vessel.max_acceleration and command >= -vessel.max_deceleration, "入轨推力不超上限")
			var state: Dictionary = game._propulsion_step(expected_position,expected_velocity,expected_fuel,game.SIM_STEP,vessel.gravity_threshold,command,vessel.heading,vessel.propulsion_fuel_per_delta_v)
			expected_position = state.position
			expected_velocity = state.velocity
			expected_fuel = state.fuel
		fuel = vessel.fuel
		game._confirm_orbit()
		check(not game.simulation_paused and vessel.fuel == fuel, "确认后按步执行不提前扣油")
		for command in plan.commands:
			game._physics_process(game.SIM_STEP / game.TIME_SCALE)
		check(vessel.flight_position.distance_to(expected_position) < .1, "入轨规划和实飞位置一致")
		check(vessel.flight_velocity.distance_to(expected_velocity) < .01, "入轨规划和实飞速度一致")
		check(absf(vessel.fuel - expected_fuel) < .01, "入轨预算和实际耗油一致")
	game._reset()
	game._select_ship()
	vessel.flight_velocity = Vector2(0, 500)
	game._begin_orbit_selection()
	game._choose_orbit_target(planet)
	check(not game.pending_plan.ok, "径向直坠拒绝入轨")
	game._cancel_orbit_selection()
	check(not game.simulation_paused, "取消恢复原暂停状态")
	game._reset()
	game._select_ship()
	vessel.fuel = 0
	game._begin_orbit_selection()
	game._choose_orbit_target(planet)
	check(not game.pending_plan.ok, "燃料不足拒绝入轨")
	game._cancel_orbit_selection()
	vessel.orbit_search_radius = 1
	game._toggle_pause()
	game._begin_orbit_selection()
	check(game.orbit_candidates.is_empty(), "搜索半径生效")
	game._cancel_orbit_selection()
	check(game.simulation_paused, "原本暂停则取消后仍暂停")
	game._reset()
	game._select_ship()
	game._begin_orbit_selection()
	game._choose_orbit_target(planet)
	for size in [Vector2i(900,640),Vector2i(1200,720)]:
		root.size = size
		for i in range(5):
			await process_frame
		for button in [game.pause_button, game.orbit_button, game.orbit_actions.get_node("Confirm"),game.panel.get_node("Margin/Content/ResetButton")]:
			check(Rect2(Vector2.ZERO,Vector2(size)).encloses(button.get_global_rect()), "选星状态按钮完整可见")
	print("ORBIT_CONTROL_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
