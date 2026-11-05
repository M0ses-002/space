extends SceneTree
## 固定干质量推进、燃料边界、预览与实际入轨一致性回归。
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)
func _run() -> void:
	root.size = Vector2i(1200, 720)
	var game = load("res://scenes/game/main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	await process_frame
	game._select_ship()
	var vessel = game.ship
	check(vessel.get_total_mass() == 8000.0 and not vessel.has_method("get_mass_ratio"), "移除货舱后质量恒为8000kg干质量")
	for property in vessel.get_property_list():
		check(property.name != "cargo_mass", "飞船彻底移除货舱质量属性")
	var initial_acceleration: float = vessel.get_effective_acceleration()
	vessel.fuel = 0.0
	check(vessel.get_total_mass() == 8000.0 and vessel.get_effective_acceleration() == initial_acceleration, "燃料库存不改变质量和额定推进能力")
	vessel.fuel = vessel.initial_fuel
	check(vessel.fuel_capacity == 6000.0 and vessel.initial_fuel == 3200.0, "油箱容量6000kg且保留初始油量3200kg")
	var fixture = load("res://scripts/ships/ship.gd").new()
	fixture.fuel_capacity = 10.0
	fixture.initial_fuel = 20.0
	fixture.reset_flight()
	check(fixture.fuel == 10.0 and fixture.initial_fuel == 20.0, "超容量初始燃料截断且不改配置")
	for invalid_fuel in [-1.0, INF, NAN]:
		fixture.initial_fuel = invalid_fuel
		fixture.reset_flight()
		check(fixture.fuel == 0.0, "非法初始燃料按零处理")
	fixture.fuel_capacity = NAN
	fixture.initial_fuel = 10.0
	fixture.reset_flight()
	check(fixture.fuel_capacity == 0.0 and fixture.fuel == 0.0, "非有限油箱容量不能产生燃料")
	for invalid_mass in [0.0, -1.0, INF, NAN]:
		fixture.dry_mass = invalid_mass
		check(fixture.dry_mass == 8000.0 and fixture.get_total_mass() == 8000.0, "非法干质量恢复基准")
	fixture.free()
	var gravities: Dictionary = {}
	for source in game.planets:
		gravities[source] = source.surface_gravity
		source.surface_gravity = 0.0
	check(vessel.get_effective_acceleration() == vessel.max_acceleration and vessel.get_effective_deceleration() == vessel.max_deceleration and vessel.get_effective_steering_acceleration() == vessel.max_steering_acceleration, "固定质量保留额定三种推进加速度")
	var coefficient: float = vessel.get_effective_propulsion_fuel_per_delta_v()
	check(coefficient == vessel.propulsion_fuel_per_delta_v and is_equal_approx(vessel.fuel_to_delta_v(6000.0), 6000.0 / coefficient) and vessel.fuel_to_delta_v(0.0) == 0.0, "Δv按实际耗油系数换算且零油为零")
	var start := Vector2(0, -62000)
	var speed := Vector2(655, 0)
	var expected: Dictionary = game._propulsion_step(start, speed, 6000.0, 1.0, 5.0, Vector2.RIGHT, coefficient)
	vessel.flight_position = start
	vessel.flight_velocity = speed
	vessel.fuel = 6000.0
	game._start_thrust(1.0)
	game._physics_process(1.0 / game.TIME_SCALE)
	check(vessel.flight_velocity.distance_to(expected.velocity) < 0.001 and absf(vessel.fuel - expected.fuel) < 0.00001, "实飞顺推与统一积分器速度耗油一致")
	game._stop_thrust()
	game._start_thrust(-1.0)
	game._physics_process(1.0 / game.TIME_SCALE)
	check(vessel.flight_velocity.distance_to(speed) < 0.001, "逆推抵消等时间顺推速度增量")
	game._stop_thrust()
	vessel.flight_position = start
	vessel.flight_velocity = speed
	vessel.fuel = 6000.0
	game._set_thrust_direction(Vector2.UP)
	game._set_throttle(0.5)
	game._physics_process(1.0 / game.TIME_SCALE)
	check(absf(vessel.flight_velocity.y + vessel.get_effective_steering_acceleration() * 0.5) < 0.001, "方向推进按半油门真实积分")
	check(absf(6000.0 - vessel.fuel - vessel.get_effective_steering_acceleration() * 0.5 * coefficient) < 0.00001, "方向推进按真实Δv耗油")
	var dial = game.get_node("HUD/Root/ThrustDial")
	dial.sync_state()
	check(dial.output.text.contains("5.0 / 10.0"), "仪表显示固定质量的实际出力与有效上限")
	game._stop_thrust()
	for source in game.planets:
		source.surface_gravity = gravities[source]
	game._reset()
	game._select_ship()
	check(vessel.get_total_mass() == vessel.dry_mass, "整局重置不产生隐藏货重")
	var planet = game.planets[0]
	for source in game.planets:
		if source != planet:
			source.surface_gravity = 0.0
	var plan: Dictionary = load("res://scripts/navigation/orbit_planner.gd").plan(game, vessel, planet)
	check(plan.get("ok", false), "近圆轨道可规划入轨：%s" % plan.get("reason", ""))
	if plan.get("ok", false):
		var expected_position: Vector2 = vessel.flight_position
		var expected_velocity: Vector2 = vessel.flight_velocity
		var expected_fuel: float = vessel.fuel
		for command in plan.commands:
			check(command <= vessel.get_effective_acceleration() and command >= -vessel.get_effective_deceleration(), "入轨指令不超过有效推进上限")
			var state: Dictionary = game._propulsion_step(expected_position, expected_velocity, expected_fuel, game.SIM_STEP, command, vessel.heading, coefficient)
			expected_position = state.position
			expected_velocity = state.velocity
			expected_fuel = state.fuel
		check(absf(vessel.fuel - expected_fuel - plan.fuel_cost) < 0.001, "规划预算与统一积分器耗油一致")
		vessel.maneuver_commands = plan.commands.duplicate()
		vessel.maneuver_index = 0
		vessel.maneuver_target = planet
		game._refresh_preview()
		var prediction: PackedVector2Array = game.preview_points.duplicate()
		for index in range(plan.commands.size()):
			game._physics_process(game.SIM_STEP / game.TIME_SCALE)
			if (index + 1) % game.PREVIEW_SAMPLE_STEPS == 0:
				check(vessel.flight_position.distance_to(prediction[(index + 1) / game.PREVIEW_SAMPLE_STEPS]) < 0.01, "机动预览与实飞采样一致")
		check(vessel.flight_position.distance_to(expected_position) < 0.01 and vessel.flight_velocity.distance_to(expected_velocity) < 0.001 and absf(vessel.fuel - expected_fuel) < 0.001, "入轨预算位置速度与执行一致")
		vessel.flight_position = vessel.initial_position
		vessel.flight_velocity = vessel.initial_velocity
		vessel.fuel = 0.0
		var insufficient: Dictionary = load("res://scripts/navigation/orbit_planner.gd").plan(game, vessel, planet)
		check(not insufficient.ok, "燃料不足时规划拒绝执行")
	vessel.voyage_finished = true
	vessel.arrival_source = planet
	vessel.departure_position = vessel.initial_position
	vessel.departure_velocity = vessel.initial_velocity
	vessel.fuel = 0.0
	game._depart()
	check(not vessel.voyage_finished and vessel.fuel == vessel.get_fuel_capacity(), "零油成功离港自动补满")
	print("CARGO_PHYSICS_TEST: %s" % ("PASS" if failures == 0 else "FAIL"))
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
