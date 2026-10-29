extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1200, 720)
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	game._select_ship()
	var vessel = game.ship
	check(is_equal_approx(vessel.cargo_mass, 10.0), "初始货舱10kg已在首次航行前同步")
	check(is_equal_approx(vessel.get_total_mass(), 8010.0), "总质量仅为8000kg干质量加10kg货物")
	var initial_acceleration: float = vessel.get_effective_acceleration()
	vessel.fuel = 0.0
	check(is_equal_approx(vessel.get_total_mass(), 8010.0) and is_equal_approx(vessel.get_effective_acceleration(), initial_acceleration), "燃料库存不改变质量和额定推进能力")
	vessel.fuel = vessel.initial_fuel
	check(vessel.fuel_capacity == 6000.0 and vessel.initial_fuel == 3200.0, "油箱容量6000kg且保留旧初始油量3200kg")
	var fixture = load("res://scenes/ship.gd").new()
	fixture.fuel_capacity = 10.0
	fixture.initial_fuel = 20.0
	fixture.reset_flight()
	check(fixture.fuel == 10.0 and fixture.initial_fuel == 20.0, "超容量初始燃料按容量截断且不改写配置")
	fixture.initial_fuel = -1.0
	fixture.reset_flight()
	check(fixture.fuel == 0.0, "负初始燃料按零处理")
	fixture.initial_fuel = INF
	fixture.reset_flight()
	check(fixture.fuel == 0.0, "非有限初始燃料按零处理")
	fixture.fuel_capacity = NAN
	fixture.initial_fuel = 10.0
	fixture.reset_flight()
	check(fixture.fuel_capacity == 0.0 and fixture.fuel == 0.0, "非有限油箱容量不能产生燃料")
	for invalid_mass in [0.0, -1.0, INF, NAN]:
		fixture.dry_mass = invalid_mass
		check(fixture.dry_mass == 8000.0 and fixture.get_mass_ratio() == 1.0, "非法干质量恢复既有基准避免除零或非有限结果")
	fixture.free()

	var gravities: Dictionary = {}
	for source in game.planets:
		gravities[source] = source.surface_gravity
		source.surface_gravity = 0.0
	vessel.cargo_mass = 0.0
	check(vessel.get_total_mass() == vessel.dry_mass, "空载仅有干质量")
	check(vessel.get_effective_acceleration() == vessel.max_acceleration and vessel.get_effective_deceleration() == vessel.max_deceleration and vessel.get_effective_steering_acceleration() == vessel.max_steering_acceleration, "空载保持所有原推进加速度")
	check(vessel.get_effective_propulsion_fuel_per_delta_v() == vessel.propulsion_fuel_per_delta_v and vessel.get_effective_hover_fuel_per_delta_v() == vessel.hover_fuel_per_delta_v, "空载保持原推进及悬停耗油系数")
	var empty_acceleration: float = vessel.get_effective_acceleration()
	var empty_coefficient: float = vessel.get_effective_propulsion_fuel_per_delta_v()
	var empty_delta_v: float = vessel.fuel_to_delta_v(6000.0)
	check(is_equal_approx(empty_delta_v, 6000.0 / empty_coefficient), "空载Δv以当前推进耗油系数换算")
	var empty_hover: float = vessel.get_effective_hover_fuel_per_delta_v()
	var start := Vector2(0, -62000)
	var speed := Vector2(655, 0)
	var empty: Dictionary = game._propulsion_step(start, speed, 6000.0, 1.0, empty_acceleration, Vector2.RIGHT, empty_coefficient)
	vessel.cargo_mass = vessel.dry_mass
	check(vessel.get_mass_ratio() == 2.0 and vessel.get_effective_acceleration() == empty_acceleration / 2.0, "载货等于干质量时有效推力加速度减半")
	check(vessel.get_effective_deceleration() == vessel.max_deceleration / 2.0 and vessel.get_effective_steering_acceleration() == vessel.max_steering_acceleration / 2.0, "逆推与方向推进使用同一质量倍率")
	check(vessel.get_effective_propulsion_fuel_per_delta_v() == empty_coefficient * 2.0 and vessel.get_effective_hover_fuel_per_delta_v() == empty_hover * 2.0, "载重推进及悬停单位Δv耗油翻倍")
	check(is_equal_approx(vessel.fuel_to_delta_v(6000.0), empty_delta_v / 2.0) and vessel.fuel_to_delta_v(0.0) == 0.0, "相同油量质量翻倍则Δv减半，零油为零")
	var loaded: Dictionary = game._propulsion_step(start, speed, 6000.0, 1.0, vessel.get_effective_acceleration(), Vector2.RIGHT, vessel.get_effective_propulsion_fuel_per_delta_v())
	check(absf(empty.fuel - loaded.fuel) < 0.00001, "同油门同时间推进流量不变，不重复惩罚载重")
	check(absf((empty.velocity.x - speed.x) / 2.0 - (loaded.velocity.x - speed.x)) < 0.001, "相同推进时间载重速度增量减半")
	var same_delta_v: Dictionary = game._propulsion_step(start, speed, 6000.0, 2.0, vessel.get_effective_acceleration(), Vector2.RIGHT, vessel.get_effective_propulsion_fuel_per_delta_v())
	check(same_delta_v.velocity == empty.velocity and absf((6000.0 - same_delta_v.fuel) - (6000.0 - empty.fuel) * 2.0) < 0.00001, "获得相同Δv时载重耗油更多")
	vessel.flight_position = start
	vessel.flight_velocity = speed
	vessel.fuel = 6000.0
	game._start_thrust(1.0)
	game._physics_process(1.0 / game.TIME_SCALE)
	check(vessel.flight_velocity.distance_to(loaded.velocity) < 0.001 and absf(vessel.fuel - loaded.fuel) < 0.00001, "实飞顺推使用一次有效加速度和耗油倍率")
	game._stop_thrust()
	game._start_thrust(-1.0)
	game._physics_process(1.0 / game.TIME_SCALE)
	check(vessel.flight_velocity.distance_to(speed) < 0.001, "载重逆推使用相同有效加速度")
	game._stop_thrust()
	var steering_states: Array[Dictionary] = []
	for cargo in [0.0, vessel.dry_mass]:
		vessel.cargo_mass = cargo
		vessel.flight_position = start
		vessel.flight_velocity = speed
		vessel.fuel = 6000.0
		game._set_thrust_direction(Vector2.UP)
		game._set_throttle(0.5)
		game._physics_process(1.0 / game.TIME_SCALE)
		steering_states.append({"velocity": vessel.flight_velocity, "fuel": vessel.fuel})
		game._stop_thrust()
	check(absf(steering_states[0].fuel - steering_states[1].fuel) < 0.00001, "方向推进同油门同时间流量不变")
	check(absf(steering_states[0].velocity.y / 2.0 - steering_states[1].velocity.y) < 0.001, "方向推进载重速度增量减半")
	game._set_throttle(0.5)
	var dial = game.get_node("HUD/Root/ThrustDial")
	dial.sync_state()
	check(dial.output.text.contains("2.5 / 5.0"), "仪表显示载重实际出力与有效上限")
	game._stop_thrust()
	for source in game.planets:
		source.surface_gravity = gravities[source]

	var coasts: Array[Dictionary] = []
	for cargo in [0.0, vessel.dry_mass]:
		vessel.cargo_mass = cargo
		vessel.flight_position = start
		vessel.flight_velocity = speed
		vessel.fuel = 1000.0
		game._physics_process(1.0 / game.TIME_SCALE)
		coasts.append({"position": vessel.flight_position, "velocity": vessel.flight_velocity, "fuel": vessel.fuel})
	check(coasts[0] == coasts[1], "同初始状态不同货重的无动力引力滑行完全一致")
	var rate: float = game._hover_rate(start, vessel.get_effective_hover_fuel_per_delta_v())
	check(is_equal_approx(rate, game._hover_rate(start, empty_hover) * 2.0), "同地点载重悬停流量按总质量增长")
	vessel.flight_position = start
	vessel.flight_velocity = speed
	vessel.fuel = 6000.0
	game._toggle_hover()
	game._physics_process(1.0 / game.TIME_SCALE)
	check(vessel.flight_position == start and absf(6000.0 - vessel.fuel - rate) < 0.00001, "实际悬停保持位置并按载重扣油")
	var before_release: float = vessel.fuel
	var reference = vessel.hover_source
	var circular_speed: float = sqrt(reference.acceleration_at(start).length() * start.distance_to(reference.flight_position))
	game._toggle_hover()
	check(not vessel.hovering and absf(before_release - vessel.fuel - circular_speed * vessel.get_effective_propulsion_fuel_per_delta_v()) < 0.001, "解除悬停按载重圆轨道Δv扣油")
	game._toggle_hover()
	vessel.fuel = rate * 0.5
	game._refresh_preview()
	var prediction: PackedVector2Array = game.preview_points.duplicate()
	game._physics_process(1.0 / game.TIME_SCALE)
	check(not vessel.hovering and vessel.fuel == 0.0 and vessel.flight_position.distance_to(prediction[1]) < 0.01, "载重悬停油尽后的预览与实飞一致")

	game._reset()
	game._select_ship()
	check(vessel.cargo_mass == 10.0, "整局重置后重新同步初始货重")
	var planet = game.planets[0]
	for source in game.planets:
		if source != planet:
			source.surface_gravity = 0.0
	vessel.cargo_mass = vessel.dry_mass
	var plan: Dictionary = load("res://scripts/orbit_planner.gd").plan(game, vessel, planet)
	check(plan.get("ok", false), "载重近圆轨道可规划入轨：%s" % plan.get("reason", ""))
	if plan.get("ok", false):
		var expected_position: Vector2 = vessel.flight_position
		var expected_velocity: Vector2 = vessel.flight_velocity
		var expected_fuel: float = vessel.fuel
		for command in plan.commands:
			check(command <= vessel.get_effective_acceleration() and command >= -vessel.get_effective_deceleration(), "载重入轨指令不超过有效推进上限")
			var state: Dictionary = game._propulsion_step(expected_position, expected_velocity, expected_fuel, game.SIM_STEP, command, vessel.heading, vessel.get_effective_propulsion_fuel_per_delta_v())
			expected_position = state.position
			expected_velocity = state.velocity
			expected_fuel = state.fuel
		check(absf(vessel.fuel - expected_fuel - plan.fuel_cost) < 0.001, "载重规划预算与统一积分器耗油一致")
		vessel.maneuver_commands = plan.commands.duplicate()
		vessel.maneuver_index = 0
		vessel.maneuver_target = planet
		game._refresh_preview()
		prediction = game.preview_points.duplicate()
		for index in range(plan.commands.size()):
			game._physics_process(game.SIM_STEP / game.TIME_SCALE)
			if (index + 1) % game.PREVIEW_SAMPLE_STEPS == 0:
				check(vessel.flight_position.distance_to(prediction[(index + 1) / game.PREVIEW_SAMPLE_STEPS]) < 0.01, "载重机动预览与实飞采样一致")
		check(vessel.flight_position.distance_to(expected_position) < 0.01 and vessel.flight_velocity.distance_to(expected_velocity) < 0.001 and absf(vessel.fuel - expected_fuel) < 0.001, "载重入轨预算、位置、速度与执行一致")
		vessel.flight_position = vessel.initial_position
		vessel.flight_velocity = vessel.initial_velocity
		vessel.fuel = 0.0
		var insufficient: Dictionary = load("res://scripts/orbit_planner.gd").plan(game, vessel, planet)
		check(not insufficient.ok, "载重燃料不足时规划拒绝执行")
	vessel.voyage_finished = true
	vessel.arrival_source = planet
	vessel.departure_position = vessel.initial_position
	vessel.departure_velocity = vessel.initial_velocity
	vessel.fuel = 0.0
	game._depart()
	check(not vessel.voyage_finished and vessel.fuel == 0.0 and game.flight_message.contains("零燃料"), "零油离港允许但明确警告且不补油")
	print("CARGO_PHYSICS_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
